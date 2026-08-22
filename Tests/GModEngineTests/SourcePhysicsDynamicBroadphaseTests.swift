import Testing
@testable import GModEngine

@Suite("Deterministic Source dynamic-body broadphase")
struct SourcePhysicsDynamicBroadphaseTests {
    @Test("sweep candidates exactly match exhaustive policy and Source order")
    func sweepMatchesExhaustiveReference() {
        let entries = (0 ..< 192).map { index in
            // Deliberately unrelated spatial and Source orders exercise both
            // sweep sorting and the final legacy pair-order restoration.
            let lane = (index * 73) % 211
            let x = Float(lane * 3)
            let y = Float((index * 29) % 17) * 4
            let halfX = Float((index % 5) + 1)
            return SourcePhysicsDynamicBroadphaseEntry(
                sourceOrder: index,
                minimums: SourceVector3(x - halfX, y - 1, -1),
                maximums: SourceVector3(x + halfX, y + 1, 1),
                isMovable: index % 7 != 0,
                isDynamic: index % 3 == 0
            )
        }

        let result = SourcePhysicsDynamicSweepAndPrune.candidates(from: entries)
        #expect(result.candidatePairs == exhaustiveCandidates(entries))
        #expect(result.fullPairCount == 18_336)
        #expect(result.sweepCandidatePairCount < result.fullPairCount)
        #expect(result.candidatePairs.count <= result.sweepCandidatePairCount)
    }

    @Test("spatial sweep restores pair ties and static-only policy")
    func sourceOrderAndMotionPolicy() {
        let entries = [
            entry(order: 0, x: -4 ... 4, y: -1 ... 1,
                  isMovable: true, isDynamic: true),
            entry(order: 1, x: -1 ... 1, y: -1 ... 1,
                  isMovable: false, isDynamic: false),
            entry(order: 2, x: -3 ... 3, y: -1 ... 1,
                  isMovable: true, isDynamic: false),
            // Motion-disabled dynamic bodies have the same broadphase policy
            // as a static body until another live dynamic body is present.
            entry(order: 3, x: -2 ... 2, y: -1 ... 1,
                  isMovable: false, isDynamic: false),
            entry(order: 4, x: -5 ... 5, y: -1 ... 1,
                  isMovable: true, isDynamic: true),
            // X overlaps every body, but Y rejects this body before SAT.
            entry(order: 5, x: -6 ... 6, y: 20 ... 22,
                  isMovable: true, isDynamic: true),
        ]

        let result = SourcePhysicsDynamicSweepAndPrune.candidates(from: entries)
        #expect(result.fullPairCount == 15)
        #expect(result.sweepCandidatePairCount == 12)
        #expect(result.candidatePairs == [
            pair(0, 1), pair(0, 2), pair(0, 3), pair(0, 4),
            pair(1, 4), pair(2, 4), pair(3, 4),
        ])
    }

    @Test("large sparse body world avoids the legacy quadratic pair scan")
    func sparseEnvironmentDiagnostics() throws {
        let bodyCount = 512
        let disabledCount = bodyCount / 16
        let enabledCount = bodyCount - disabledCount
        let shape = try makeCubeShape()
        let environment = SourceDeterministicPhysicsEnvironment(
            configuration: try .init(gravity: .zero)
        )
        var commands: [SourcePhysicsCommand] = []
        commands.reserveCapacity(bodyCount + 1)
        for index in 0 ..< bodyCount {
            commands.append(SourcePhysicsCommand(
                sequence: UInt64(index + 1),
                payload: .createBody(try SourcePhysicsBodyCreationCommand(
                    bodyID: makeBodyID(entry: index + 100),
                    shape: shape,
                    massProperties: SourcePhysicsMassProperties(
                        massKilograms: 10,
                        principalInertia: SourceVector3(2, 2, 2)
                    ),
                    transform: SourceEntityTransform(
                        origin: SourceVector3(Float(index) * 8, 0, 0)
                    ),
                    linearVelocity: .zero,
                    angularVelocity: .zero,
                    damping: .zero,
                    motionType: .dynamicBody,
                    materialIndex: 1,
                    isGravityEnabled: false,
                    isCollisionEnabled: !index.isMultiple(of: 16),
                    startsAwake: true
                ))
            ))
        }
        commands.append(SourcePhysicsCommand(
            sequence: UInt64(bodyCount + 1),
            payload: .simulate(SourcePhysicsSimulateCommand(simulationTick: 1))
        ))

        let snapshot = try environment.execute(
            SourcePhysicsCommandBatch(commands: commands)
        )
        #expect(snapshot.bodies.count == bodyCount)
        #expect(environment.latestContacts.isEmpty)
        let diagnostics = environment.latestDynamicBroadphaseDiagnostics
        #expect(diagnostics.totalBodyCount == bodyCount)
        #expect(diagnostics.collisionEnabledBodyCount == enabledCount)
        #expect(diagnostics.fullPairCount == enabledCount * (enabledCount - 1) / 2)
        #expect(diagnostics.sweepCandidatePairCount == 0)
        #expect(diagnostics.narrowphaseCandidatePairCount == 0)
    }

    private func exhaustiveCandidates(
        _ entries: [SourcePhysicsDynamicBroadphaseEntry]
    ) -> [SourcePhysicsDynamicBroadphasePair] {
        let ordered = entries.sorted { $0.sourceOrder < $1.sourceOrder }
        var result: [SourcePhysicsDynamicBroadphasePair] = []
        for firstIndex in ordered.indices {
            let first = ordered[firstIndex]
            for secondIndex in ordered.index(after: firstIndex) ..< ordered.endIndex {
                let second = ordered[secondIndex]
                guard first.isMovable || second.isMovable,
                      first.isDynamic || second.isDynamic,
                      intersects(first, second) else { continue }
                result.append(pair(first.sourceOrder, second.sourceOrder))
            }
        }
        return result
    }

    private func intersects(
        _ first: SourcePhysicsDynamicBroadphaseEntry,
        _ second: SourcePhysicsDynamicBroadphaseEntry
    ) -> Bool {
        first.minimums.x <= second.maximums.x &&
            first.maximums.x >= second.minimums.x &&
            first.minimums.y <= second.maximums.y &&
            first.maximums.y >= second.minimums.y &&
            first.minimums.z <= second.maximums.z &&
            first.maximums.z >= second.minimums.z
    }

    private func entry(
        order: Int,
        x: ClosedRange<Float>,
        y: ClosedRange<Float>,
        isMovable: Bool,
        isDynamic: Bool
    ) -> SourcePhysicsDynamicBroadphaseEntry {
        SourcePhysicsDynamicBroadphaseEntry(
            sourceOrder: order,
            minimums: SourceVector3(x.lowerBound, y.lowerBound, -1),
            maximums: SourceVector3(x.upperBound, y.upperBound, 1),
            isMovable: isMovable,
            isDynamic: isDynamic
        )
    }

    private func pair(
        _ first: Int,
        _ second: Int
    ) -> SourcePhysicsDynamicBroadphasePair {
        SourcePhysicsDynamicBroadphasePair(
            firstSourceOrder: first,
            secondSourceOrder: second
        )
    }

    private func makeBodyID(entry: Int) throws -> SourcePhysicsBodyID {
        try SourcePhysicsBodyID(
            entityIdentity: SourceCanonicalEntityIdentity(
                handle: SourceBaseHandle(entryIndex: entry, serialNumber: 17)
            ),
            solidIndex: 0
        )
    }

    private func makeCubeShape() throws -> SourcePhysicsShapeSnapshot {
        let vertices = [
            SourceVector3(-1, -1, -1), SourceVector3(1, -1, -1),
            SourceVector3(1, 1, -1), SourceVector3(-1, 1, -1),
            SourceVector3(-1, -1, 1), SourceVector3(1, -1, 1),
            SourceVector3(1, 1, 1), SourceVector3(-1, 1, 1),
        ]
        let indices = [
            (0, 2, 1), (0, 3, 2), (4, 5, 6), (4, 6, 7),
            (0, 1, 5), (0, 5, 4), (1, 2, 6), (1, 6, 5),
            (2, 3, 7), (2, 7, 6), (3, 0, 4), (3, 4, 7),
        ]
        return try SourcePhysicsShapeSnapshot(
            topology: .convexParts,
            parts: [SourcePhysicsMeshPartSnapshot(
                vertices: vertices,
                triangles: try indices.map {
                    try SourcePhysicsIndexedTriangle(
                        first: $0.0,
                        second: $0.1,
                        third: $0.2,
                        materialIndex: 1
                    )
                }
            )]
        )
    }
}
