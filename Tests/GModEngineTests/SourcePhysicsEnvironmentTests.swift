import Testing
@testable import GModEngine

@Suite("Backend-neutral Source physics contract")
struct SourcePhysicsEnvironmentTests {
    @Test("simulation has exactly one fixed 0.015-second step")
    func fixedStepCannotBeOverriddenByCommands() {
        let command = SourcePhysicsSimulateCommand(simulationTick: 42)

        #expect(command.simulationTick == 42)
        #expect(SourcePhysicsContract.fixedTimeStepSeconds == 0.015)
        #expect(
            SourcePhysicsContract.fixedTimeStepSeconds ==
                SourceGlobalVars.intervalPerTick
        )
    }

    @Test("body creation retains full EHANDLE and all mandatory physical data")
    func creationRetainsCanonicalInputs() throws {
        let identity = makeIdentity(entryIndex: 321, serialNumber: 77)
        let bodyID = try SourcePhysicsBodyID(
            entityIdentity: identity,
            solidIndex: 2
        )
        let shape = try makeTetrahedronShape()
        let mass = try SourcePhysicsMassProperties(
            massKilograms: 12.5,
            principalInertia: SourceVector3(3, 4, 5)
        )
        let creation = try SourcePhysicsBodyCreationCommand(
            bodyID: bodyID,
            shape: shape,
            massProperties: mass,
            transform: SourceEntityTransform(
                origin: SourceVector3(10, 20, 30),
                angles: SourceQAngle(pitch: 1, yaw: 2, roll: 3)
            ),
            linearVelocity: SourceVector3(4, 5, 6),
            angularVelocity: SourceVector3(7, 8, 9),
            damping: try SourcePhysicsDamping(linear: 0.25, angular: 0.5),
            motionType: .dynamicBody,
            materialIndex: 11,
            isGravityEnabled: true,
            isCollisionEnabled: true,
            startsAwake: false
        )

        #expect(creation.bodyID.entityIdentity.handle == identity.handle)
        #expect(creation.bodyID.entityIdentity.entryIndex == 321)
        #expect(creation.bodyID.entityIdentity.serialNumber == 77)
        #expect(creation.bodyID.solidIndex == 2)
        #expect(creation.shape == shape)
        #expect(creation.massProperties == mass)
        #expect(creation.massProperties.massKilograms == 12.5)
        #expect(creation.massProperties.principalInertia == SourceVector3(3, 4, 5))
        let expectedDamping = try SourcePhysicsDamping(
            linear: 0.25,
            angular: 0.5
        )
        #expect(creation.damping == expectedDamping)
        #expect(creation.materialIndex == 11)
        #expect(creation.startsAwake == false)
    }

    @Test("damping coefficients are finite, nonnegative, and FIFO-valid")
    func dampingContractFailsClosed() throws {
        #expect(SourcePhysicsDamping.sourceDefault.linear == 0.1)
        #expect(SourcePhysicsDamping.sourceDefault.angular == 0.1)
        #expect(SourcePhysicsDamping.zero.linear == 0)
        #expect(SourcePhysicsDamping.zero.angular == 0)

        #expect(throws: SourcePhysicsContractError.nonFinite(
            field: "linearDamping"
        )) {
            _ = try SourcePhysicsDamping(linear: .nan, angular: 0)
        }
        #expect(throws: SourcePhysicsContractError.negative(
            field: "angularDamping"
        )) {
            _ = try SourcePhysicsDamping(linear: 0, angular: -0.001)
        }

        let bodyID = try SourcePhysicsBodyID(
            entityIdentity: makeIdentity(entryIndex: 812, serialNumber: 27),
            solidIndex: 3
        )
        #expect(throws: SourcePhysicsContractError.nonFinite(
            field: "bodyMutation.angularDamping"
        )) {
            _ = try SourcePhysicsBodyMutationCommand(
                bodyID: bodyID,
                mutation: .setDamping(linear: 1, angular: .infinity)
            )
        }
        #expect(throws: SourcePhysicsContractError.negative(
            field: "bodyMutation.linearDamping"
        )) {
            _ = try SourcePhysicsBodyMutationCommand(
                bodyID: bodyID,
                mutation: .setDamping(linear: -1, angular: 2)
            )
        }

        let valid = try SourcePhysicsBodyMutationCommand(
            bodyID: bodyID,
            mutation: .setDamping(linear: 1.25, angular: 2.5)
        )
        #expect(valid.bodyID.entityIdentity.handle == bodyID.entityIdentity.handle)
        #expect(valid.mutation == .setDamping(linear: 1.25, angular: 2.5))
    }

    @Test("shape, mass, inertia, and transforms reject missing or invented values")
    func invalidPhysicalInputsFailClosed() throws {
        #expect(throws: SourcePhysicsContractError.emptyShape) {
            _ = try SourcePhysicsShapeSnapshot(
                topology: .convexParts,
                parts: []
            )
        }

        #expect(
            throws: SourcePhysicsContractError.massOutsideVPhysicsRange(0)
        ) {
            _ = try SourcePhysicsMassProperties(
                massKilograms: 0,
                principalInertia: SourceVector3(1, 1, 1)
            )
        }

        #expect(
            throws: SourcePhysicsContractError.nonPositive(
                field: "principalInertia"
            )
        ) {
            _ = try SourcePhysicsMassProperties(
                massKilograms: 1,
                principalInertia: SourceVector3(1, 0, 1)
            )
        }

        let identity = makeIdentity(entryIndex: 12, serialNumber: 9)
        let bodyID = try SourcePhysicsBodyID(
            entityIdentity: identity,
            solidIndex: 0
        )
        #expect(
            throws: SourcePhysicsContractError.nonFinite(
                field: "transform.origin"
            )
        ) {
            _ = try SourcePhysicsBodyCreationCommand(
                bodyID: bodyID,
                shape: try makeTetrahedronShape(),
                massProperties: try SourcePhysicsMassProperties(
                    massKilograms: 1,
                    principalInertia: SourceVector3(1, 1, 1)
                ),
                transform: SourceEntityTransform(
                    origin: SourceVector3(.nan, 0, 0),
                    angles: .zero
                ),
                linearVelocity: .zero,
                angularVelocity: .zero,
                damping: .sourceDefault,
                motionType: .dynamicBody,
                materialIndex: 0,
                isGravityEnabled: true,
                isCollisionEnabled: true,
                startsAwake: true
            )
        }

        #expect(
            throws: SourcePhysicsContractError.nonFinite(
                field: "bodyMutation.offsetForce"
            )
        ) {
            _ = try SourcePhysicsBodyMutationCommand(
                bodyID: bodyID,
                mutation: .applyForceOffset(
                    force: SourceVector3(.nan, 0, 0),
                    worldPosition: .zero
                )
            )
        }
        #expect(
            throws: SourcePhysicsContractError.nonFinite(
                field: "bodyMutation.offsetWorldPosition"
            )
        ) {
            _ = try SourcePhysicsBodyMutationCommand(
                bodyID: bodyID,
                mutation: .applyForceOffset(
                    force: SourceVector3(1, 2, 3),
                    worldPosition: SourceVector3(0, .infinity, 0)
                )
            )
        }
        #expect(
            throws: SourcePhysicsContractError.nonFinite(
                field: "bodyMutation.centerTorqueImpulse"
            )
        ) {
            _ = try SourcePhysicsBodyMutationCommand(
                bodyID: bodyID,
                mutation: .applyTorqueCenter(
                    SourceVector3(0, 0, -.infinity)
                )
            )
        }
    }

    @Test("indexed geometry is bounded before reaching a backend")
    func indexedGeometryFailsClosed() throws {
        #expect(
            throws: SourcePhysicsContractError
                .triangleMaterialIndexOutsideSevenBits(128)
        ) {
            _ = try SourcePhysicsIndexedTriangle(
                first: 0,
                second: 1,
                third: 2,
                materialIndex: 128
            )
        }

        let outOfBounds = try SourcePhysicsIndexedTriangle(
            first: 0,
            second: 1,
            third: 3,
            materialIndex: 0
        )
        #expect(
            throws: SourcePhysicsContractError.triangleIndexOutOfBounds(
                triangle: 0,
                vertexIndex: 3,
                vertexCount: 3
            )
        ) {
            _ = try SourcePhysicsMeshPartSnapshot(
                vertices: [
                    SourceVector3(0, 0, 0),
                    SourceVector3(1, 0, 0),
                    SourceVector3(0, 1, 0)
                ],
                triangles: [outOfBounds]
            )
        }

        let degenerate = try SourcePhysicsIndexedTriangle(
            first: 0,
            second: 1,
            third: 2,
            materialIndex: 0
        )
        #expect(throws: SourcePhysicsContractError.degenerateTriangle(0)) {
            _ = try SourcePhysicsMeshPartSnapshot(
                vertices: [
                    SourceVector3(0, 0, 0),
                    SourceVector3(1, 0, 0),
                    SourceVector3(2, 0, 0)
                ],
                triangles: [degenerate]
            )
        }
    }

    @Test("FIFO validation preserves gaps but rejects reordering and tick reuse")
    func commandBatchIsStrictlyOrdered() throws {
        let deletion = SourcePhysicsBodyDeletionCommand(
            bodyID: try SourcePhysicsBodyID(
                entityIdentity: makeIdentity(entryIndex: 4, serialNumber: 13),
                solidIndex: 0
            )
        )
        let valid = try SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(sequence: 10, payload: .deleteBody(deletion)),
            SourcePhysicsCommand(
                sequence: 40,
                payload: .simulate(SourcePhysicsSimulateCommand(simulationTick: 8))
            )
        ])
        #expect(valid.commands.map(\.sequence) == [10, 40])

        #expect(
            throws: SourcePhysicsContractError.commandSequenceNotIncreasing(
                previous: 10,
                current: 9
            )
        ) {
            _ = try SourcePhysicsCommandBatch(commands: [
                SourcePhysicsCommand(sequence: 10, payload: .deleteBody(deletion)),
                SourcePhysicsCommand(sequence: 9, payload: .deleteBody(deletion))
            ])
        }

        #expect(
            throws: SourcePhysicsContractError.simulationTickNotIncreasing(
                previous: 8,
                current: 8
            )
        ) {
            _ = try SourcePhysicsCommandBatch(commands: [
                SourcePhysicsCommand(
                    sequence: 10,
                    payload: .simulate(SourcePhysicsSimulateCommand(simulationTick: 8))
                ),
                SourcePhysicsCommand(
                    sequence: 11,
                    payload: .simulate(SourcePhysicsSimulateCommand(simulationTick: 8))
                )
            ])
        }
    }

    @Test("queries and snapshots keep generation-safe body identities")
    func queryAndSnapshotPreserveFullHandles() throws {
        let ignored = makeIdentity(entryIndex: 55, serialNumber: 2)
        let hitIdentity = makeIdentity(entryIndex: 55, serialNumber: 3)
        let hitBody = try SourcePhysicsBodyID(
            entityIdentity: hitIdentity,
            solidIndex: 1
        )
        let query = try SourcePhysicsQueryCommand(
            queryID: 700,
            geometry: .sweptHull(
                start: SourceVector3(0, 0, 64),
                end: SourceVector3(100, 0, 64),
                minimums: SourceVector3(-16, -16, -36),
                maximums: SourceVector3(16, 16, 36)
            ),
            contentsMask: UInt32.max,
            collisionGroup: 0,
            scope: .staticAndMoving,
            ignoredEntities: [ignored]
        )
        let hit = try SourcePhysicsQueryHitSnapshot(
            bodyID: hitBody,
            fraction: 0.25,
            position: SourceVector3(25, 0, 64),
            normal: SourceVector3(-1, 0, 0),
            materialIndex: 4,
            startedSolid: false,
            allSolid: false
        )
        let result = SourcePhysicsQueryResultSnapshot(
            queryID: query.queryID,
            commandSequence: 91,
            simulationTick: 12,
            hit: hit
        )
        let snapshot = try SourcePhysicsEnvironmentSnapshot(
            simulationTick: 12,
            lastProcessedCommandSequence: 91,
            bodies: [],
            queryResults: [result]
        )

        #expect(ignored.entryIndex == hitIdentity.entryIndex)
        #expect(ignored.handle != hitIdentity.handle)
        #expect(snapshot.queryResults[0].hit?.bodyID.entityIdentity == hitIdentity)
        #expect(snapshot.queryResults[0].hit?.bodyID.solidIndex == 1)
        #expect(snapshot.fixedTimeStepSeconds == 0.015)

        let startSolid = try SourcePhysicsQueryHitSnapshot(
            bodyID: hitBody,
            fraction: 0,
            position: .zero,
            normal: .zero,
            materialIndex: nil,
            startedSolid: true,
            allSolid: false
        )
        #expect(startSolid.startedSolid)
        #expect(startSolid.materialIndex == nil)

        #expect(
            throws: SourcePhysicsContractError
                .duplicateIgnoredEntity(ignored.handle.rawValue)
        ) {
            _ = try SourcePhysicsQueryCommand(
                queryID: 701,
                geometry: .lineSegment(start: .zero, end: SourceVector3(1, 0, 0)),
                contentsMask: UInt32.max,
                collisionGroup: 0,
                scope: .everything,
                ignoredEntities: [ignored, ignored]
            )
        }
    }

    @Test("environment snapshots reject duplicate bodies and query results")
    func snapshotsAreUnambiguous() throws {
        let bodyID = try SourcePhysicsBodyID(
            entityIdentity: makeIdentity(entryIndex: 88, serialNumber: 4),
            solidIndex: 0
        )
        let body = try makeBodySnapshot(bodyID: bodyID)
        #expect(throws: SourcePhysicsContractError.duplicateBody(bodyID)) {
            _ = try SourcePhysicsEnvironmentSnapshot(
                simulationTick: 5,
                lastProcessedCommandSequence: 20,
                bodies: [body, body],
                queryResults: []
            )
        }

        let result = SourcePhysicsQueryResultSnapshot(
            queryID: 9,
            commandSequence: 18,
            simulationTick: 5,
            hit: nil
        )
        #expect(throws: SourcePhysicsContractError.duplicateQueryID(9)) {
            _ = try SourcePhysicsEnvironmentSnapshot(
                simulationTick: 5,
                lastProcessedCommandSequence: 20,
                bodies: [body],
                queryResults: [result, result]
            )
        }
    }

    private func makeIdentity(
        entryIndex: Int,
        serialNumber: Int
    ) -> SourceCanonicalEntityIdentity {
        SourceCanonicalEntityIdentity(
            handle: SourceBaseHandle(
                entryIndex: entryIndex,
                serialNumber: serialNumber
            )
        )
    }

    private func makeTetrahedronShape() throws -> SourcePhysicsShapeSnapshot {
        let vertices = [
            SourceVector3(0, 0, 0),
            SourceVector3(1, 0, 0),
            SourceVector3(0, 1, 0),
            SourceVector3(0, 0, 1)
        ]
        let triangles = try [
            SourcePhysicsIndexedTriangle(
                first: 0,
                second: 2,
                third: 1,
                materialIndex: 1
            ),
            SourcePhysicsIndexedTriangle(
                first: 0,
                second: 1,
                third: 3,
                materialIndex: 1
            ),
            SourcePhysicsIndexedTriangle(
                first: 1,
                second: 2,
                third: 3,
                materialIndex: 1
            ),
            SourcePhysicsIndexedTriangle(
                first: 2,
                second: 0,
                third: 3,
                materialIndex: 1
            )
        ]
        let part = try SourcePhysicsMeshPartSnapshot(
            vertices: vertices,
            triangles: triangles
        )
        return try SourcePhysicsShapeSnapshot(
            topology: .convexParts,
            parts: [part]
        )
    }

    private func makeBodySnapshot(
        bodyID: SourcePhysicsBodyID
    ) throws -> SourcePhysicsBodySnapshot {
        try SourcePhysicsBodySnapshot(
            bodyID: bodyID,
            shape: makeTetrahedronShape(),
            massProperties: SourcePhysicsMassProperties(
                massKilograms: 2,
                principalInertia: SourceVector3(1, 2, 3)
            ),
            transform: .identity,
            linearVelocity: .zero,
            angularVelocity: .zero,
            damping: .zero,
            motionType: .dynamicBody,
            materialIndex: 0,
            isGravityEnabled: true,
            isCollisionEnabled: true,
            isSleeping: false,
            simulationTick: 5
        )
    }
}
