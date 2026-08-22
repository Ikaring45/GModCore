import XCTest
@testable import GModEngine
import GModLua

final class SourcePhysicsMaterialDragBuoyancyTests: XCTestCase {
    func testDeterministicBackendCommitsMutableStateAndQueryMaterial() throws {
        let bodyID = try makeBodyID(entry: 70, serial: 8)
        let environment = SourceDeterministicPhysicsEnvironment(
            configuration: try .init(gravity: .zero)
        )
        let creation = try makeCreation(
            bodyID: bodyID,
            materialIndex: 3,
            isDragEnabled: true,
            buoyancyRatio: .automatic
        )
        let first = try environment.execute(SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(sequence: 1, payload: .createBody(creation)),
            SourcePhysicsCommand(
                sequence: 2,
                payload: .mutateBody(try .init(
                    bodyID: bodyID,
                    mutation: .setMaterialIndex(7)
                ))
            ),
            SourcePhysicsCommand(
                sequence: 3,
                payload: .mutateBody(try .init(
                    bodyID: bodyID,
                    mutation: .setDragEnabled(false)
                ))
            ),
            SourcePhysicsCommand(
                sequence: 4,
                payload: .mutateBody(try .init(
                    bodyID: bodyID,
                    mutation: .setBuoyancyRatio(1.75)
                ))
            ),
            SourcePhysicsCommand(
                sequence: 5,
                payload: .simulate(.init(simulationTick: 1))
            ),
            SourcePhysicsCommand(
                sequence: 6,
                payload: .query(try .init(
                    queryID: 88,
                    geometry: .lineSegment(
                        start: SourceVector3(-3, 0, 0),
                        end: SourceVector3(3, 0, 0)
                    ),
                    contentsMask: UInt32.max,
                    collisionGroup: 0,
                    scope: .everything,
                    ignoredEntities: []
                ))
            ),
        ]))

        let body = try XCTUnwrap(first.bodies.first)
        XCTAssertEqual(body.materialIndex, 7)
        XCTAssertFalse(body.isDragEnabled)
        XCTAssertEqual(body.buoyancyRatio.explicitValue, 1.75)
        XCTAssertEqual(
            try XCTUnwrap(first.queryResults.first?.hit).materialIndex,
            7
        )

        let second = try environment.execute(SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(
                sequence: 7,
                payload: .mutateBody(try .init(
                    bodyID: bodyID,
                    mutation: .setMassKilograms(2)
                ))
            ),
            SourcePhysicsCommand(
                sequence: 8,
                payload: .simulate(.init(simulationTick: 2))
            ),
        ]))
        XCTAssertEqual(second.bodies.first?.buoyancyRatio, .automatic)
        XCTAssertEqual(second.bodies.first?.materialIndex, 7)
        XCTAssertEqual(second.bodies.first?.isDragEnabled, false)
    }

    func testMutableMaterialSelectsContactPairAtItsFIFOPosition() throws {
        let staticID = try makeBodyID(entry: 71, serial: 8)
        let dynamicID = try makeBodyID(entry: 72, serial: 8)
        let table = try SourcePhysicsMaterialTable(interactions: [
            SourcePhysicsMaterialInteraction(
                firstMaterialIndex: 7,
                secondMaterialIndex: 9,
                coefficients: SourcePhysicsContactMaterialCoefficients(
                    staticFriction: 0,
                    dynamicFriction: 0,
                    restitution: 0
                )
            ),
        ])
        let environment = SourceDeterministicPhysicsEnvironment(
            configuration: try .init(gravity: .zero),
            materialTable: table
        )
        let snapshot = try environment.execute(SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(
                sequence: 1,
                payload: .createBody(try makeCreation(
                    bodyID: staticID,
                    materialIndex: 3,
                    motionType: .staticBody
                ))
            ),
            SourcePhysicsCommand(
                sequence: 2,
                payload: .createBody(try makeCreation(
                    bodyID: dynamicID,
                    materialIndex: 7,
                    origin: SourceVector3(1.5, 0, 0),
                    linearVelocity: SourceVector3(-1, 0, 0)
                ))
            ),
            SourcePhysicsCommand(
                sequence: 3,
                payload: .mutateBody(try .init(
                    bodyID: staticID,
                    mutation: .setMaterialIndex(9)
                ))
            ),
            SourcePhysicsCommand(
                sequence: 4,
                payload: .simulate(.init(simulationTick: 1))
            ),
        ]))

        XCTAssertEqual(
            snapshot.bodies.first { $0.bodyID == staticID }?.materialIndex,
            9
        )
        let contact = try XCTUnwrap(environment.latestContacts.first)
        XCTAssertEqual(contact.firstMaterialIndex, 9)
        XCTAssertEqual(contact.secondMaterialIndex, 7)
    }

    func testReplayV11RoundTripsCreationMutationsAndSnapshots() throws {
        let bodyID = try makeBodyID(entry: 73, serial: 8)
        let creation = try makeCreation(
            bodyID: bodyID,
            materialIndex: 3,
            isDragEnabled: true,
            buoyancyRatio: try .init(explicit: 0.75)
        )
        let mutations: [SourcePhysicsBodyMutation] = [
            .setMaterialIndex(7),
            .setDragEnabled(false),
            .setBuoyancyRatio(1.25),
            .setDamping(linear: 0.5, angular: 0.75),
        ]
        var commands = [
            SourcePhysicsCommand(sequence: 1, payload: .createBody(creation)),
        ]
        for (offset, mutation) in mutations.enumerated() {
            commands.append(SourcePhysicsCommand(
                sequence: UInt64(offset + 2),
                payload: .mutateBody(try .init(
                    bodyID: bodyID,
                    mutation: mutation
                ))
            ))
        }
        commands.append(SourcePhysicsCommand(
            sequence: 6,
            payload: .simulate(.init(simulationTick: 1))
        ))
        let batch = try SourcePhysicsCommandBatch(commands: commands)
        let harness = SourcePhysicsDeterministicReplayHarness()
        let log = try harness.record(
            commandBatches: [batch],
            using: SourceDeterministicPhysicsEnvironment(
                configuration: try .init(gravity: .zero)
            )
        )

        XCTAssertEqual(SourcePhysicsReplayLog.formatVersion, 11)
        let decoded = try SourcePhysicsReplayLog(
            canonicalBytes: log.canonicalBytes
        )
        XCTAssertEqual(decoded, log)
        XCTAssertEqual(
            decoded.frames.first?.bodySnapshots.first?.materialIndex,
            7
        )
        XCTAssertEqual(
            decoded.frames.first?.bodySnapshots.first?.isDragEnabled,
            false
        )
        XCTAssertEqual(
            decoded.frames.first?.bodySnapshots.first?.buoyancyRatio
                .explicitValue,
            1.25
        )
        _ = try harness.replay(
            decoded,
            using: SourceDeterministicPhysicsEnvironment(
                configuration: try .init(gravity: .zero)
            )
        )
    }

    func testPhysObjMaterialDragAndBuoyancyUseAuthenticatedState() throws {
        let runtime = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: GMLuaNetTransport()
        )
        defer { _ = runtime.close() }
        try XCTUnwrap(runtime.typeSystem).installFallbackUtilities()

        let entity = makeProp(entryIndex: 74, serial: 8)
        let bodyID = try SourcePhysicsBodyID(
            entityIdentity: entity.identity,
            solidIndex: 0
        )
        let pending = try SourceCanonicalPhysicsObjectSnapshot(
            pendingEntity: entity,
            definition: makeDefinition(materialIndex: 7)
        )
        let host = MaterialDragBuoyancyPhysicsHost()
        host.publish(pending)
        _ = try XCTUnwrap(runtime.entityRegistry)
            .applyAuthoritativeSnapshot(entity)
        let names = try SourcePhysicsMaterialNameTable(entries: [
            SourcePhysicsMaterialNameEntry(name: "plastic", materialIndex: 7),
            SourcePhysicsMaterialNameEntry(name: "rubber", materialIndex: 9),
        ])
        _ = try SourceCanonicalPhysicsObjectGLuaBridge.install(
            into: runtime,
            host: host,
            materialNames: names
        )

        try runtime.execute(
            #"""
            PHYS = Entity(74):GetPhysicsObject()
            assert(PHYS:GetMaterial() == "plastic")
            assert(PHYS:IsDragEnabled() == true)
            local ok, message = pcall(function()
                return PHYS:GetBuoyancyRatio()
            end)
            assert(ok == false)
            assert(string.find(message, "automatic material/fluid", 1, true))

            PHYS:SetMaterial("RUBBER")
            PHYS:EnableDrag(false)
            PHYS:SetBuoyancyRatio(1.5)
            ok, message = pcall(function()
                PHYS:SetMaterial("not_registered")
            end)
            assert(ok == false)
            assert(string.find(message, "could not resolve", 1, true))
            """#,
            sourceName: "=(material drag buoyancy mutations)"
        )
        XCTAssertEqual(host.mutations, try [
            SourcePhysicsBodyMutationCommand(
                bodyID: bodyID,
                mutation: .setMaterialIndex(9)
            ),
            SourcePhysicsBodyMutationCommand(
                bodyID: bodyID,
                mutation: .setDragEnabled(false)
            ),
            SourcePhysicsBodyMutationCommand(
                bodyID: bodyID,
                mutation: .setBuoyancyRatio(1.5)
            ),
        ])

        let published = try SourcePhysicsBodySnapshot(
            bodyID: bodyID,
            shape: makeShape(),
            massProperties: SourcePhysicsMassProperties(
                massKilograms: 1,
                principalInertia: SourceVector3(1, 1, 1)
            ),
            transform: .identity,
            linearVelocity: .zero,
            angularVelocity: .zero,
            damping: .zero,
            motionType: .dynamicBody,
            materialIndex: 9,
            isGravityEnabled: false,
            isCollisionEnabled: true,
            isSleeping: false,
            simulationTick: 1,
            isDragEnabled: false,
            buoyancyRatio: try .init(explicit: 1.5)
        )
        host.publish(try .init(body: published))
        try runtime.execute(
            #"""
            assert(PHYS:GetMaterial() == "rubber")
            assert(PHYS:IsDragEnabled() == false)
            assert(PHYS:GetBuoyancyRatio() == 1.5)
            """#,
            sourceName: "=(material drag buoyancy published state)"
        )
    }

    func testMaterialNameAndMutationContractsFailClosed() throws {
        XCTAssertThrowsError(try SourcePhysicsMaterialNameTable(entries: [
            SourcePhysicsMaterialNameEntry(name: "metal", materialIndex: 2),
            SourcePhysicsMaterialNameEntry(name: "METAL", materialIndex: 3),
        ])) { error in
            XCTAssertEqual(
                error as? SourcePhysicsMaterialTableError,
                .duplicateMaterialName("METAL")
            )
        }
        let bodyID = try makeBodyID(entry: 75, serial: 8)
        XCTAssertThrowsError(try SourcePhysicsBodyMutationCommand(
            bodyID: bodyID,
            mutation: .setMaterialIndex(-1)
        ))
        XCTAssertThrowsError(try SourcePhysicsBodyMutationCommand(
            bodyID: bodyID,
            mutation: .setBuoyancyRatio(-0.01)
        ))
        XCTAssertThrowsError(try SourcePhysicsBodyMutationCommand(
            bodyID: bodyID,
            mutation: .setBuoyancyRatio(.infinity)
        ))
    }

    private func makeBodyID(
        entry: Int,
        serial: Int
    ) throws -> SourcePhysicsBodyID {
        try SourcePhysicsBodyID(
            entityIdentity: SourceCanonicalEntityIdentity(
                handle: SourceBaseHandle(
                    entryIndex: entry,
                    serialNumber: serial
                )
            ),
            solidIndex: 0
        )
    }

    private func makeCreation(
        bodyID: SourcePhysicsBodyID,
        materialIndex: Int,
        origin: SourceVector3 = .zero,
        linearVelocity: SourceVector3 = .zero,
        motionType: SourcePhysicsMotionType = .dynamicBody,
        isDragEnabled: Bool = true,
        buoyancyRatio: SourcePhysicsBuoyancyRatio = .automatic
    ) throws -> SourcePhysicsBodyCreationCommand {
        try SourcePhysicsBodyCreationCommand(
            bodyID: bodyID,
            shape: makeShape(),
            massProperties: SourcePhysicsMassProperties(
                massKilograms: 1,
                principalInertia: SourceVector3(1, 1, 1)
            ),
            transform: SourceEntityTransform(origin: origin, angles: .zero),
            linearVelocity: linearVelocity,
            angularVelocity: .zero,
            damping: .zero,
            motionType: motionType,
            materialIndex: materialIndex,
            isGravityEnabled: false,
            isCollisionEnabled: true,
            startsAwake: true,
            isDragEnabled: isDragEnabled,
            buoyancyRatio: buoyancyRatio
        )
    }

    private func makeShape() throws -> SourcePhysicsShapeSnapshot {
        let vertices = [
            SourceVector3(-1, -1, -1),
            SourceVector3(1, -1, -1),
            SourceVector3(1, 1, -1),
            SourceVector3(-1, 1, -1),
            SourceVector3(-1, -1, 1),
            SourceVector3(1, -1, 1),
            SourceVector3(1, 1, 1),
            SourceVector3(-1, 1, 1),
        ]
        let indices = [
            (0, 2, 1), (0, 3, 2),
            (4, 5, 6), (4, 6, 7),
            (0, 1, 5), (0, 5, 4),
            (1, 2, 6), (1, 6, 5),
            (2, 3, 7), (2, 7, 6),
            (3, 0, 4), (3, 4, 7),
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
                        materialIndex: 7
                    )
                }
            )]
        )
    }

    private func makeProp(
        entryIndex: Int,
        serial: Int
    ) -> SourceCanonicalEntitySnapshot {
        SourceCanonicalEntitySnapshot(
            identity: SourceCanonicalEntityIdentity(
                handle: SourceBaseHandle(
                    entryIndex: entryIndex,
                    serialNumber: serial
                )
            ),
            kind: .propPhysics,
            className: SourceCanonicalEntityKind.propPhysics.className,
            transform: .identity,
            motion: SourceEntityMotionState(),
            model: SourceEntityModelReference("models/props/test.mdl"),
            solidType: .vPhysics,
            moveType: .vPhysics,
            lifecycle: .active,
            isNetworkable: true,
            revision: 1
        )
    }

    private func makeDefinition(
        materialIndex: Int
    ) throws -> SourceCanonicalPropPhysicsBodyDefinition {
        try SourceCanonicalPropPhysicsBodyDefinition(
            solidIndex: 0,
            shape: makeShape(),
            massProperties: SourcePhysicsMassProperties(
                massKilograms: 1,
                principalInertia: SourceVector3(1, 1, 1)
            ),
            damping: .zero,
            motionType: .dynamicBody,
            materialIndex: materialIndex,
            isGravityEnabled: false,
            isCollisionEnabled: true,
            startsAwake: true
        )
    }
}

private final class MaterialDragBuoyancyPhysicsHost:
    SourceCanonicalPhysicsObjectLuaHost
{
    private(set) var mutations: [SourcePhysicsBodyMutationCommand] = []
    private var body: SourceCanonicalPhysicsObjectSnapshot?

    func publish(_ snapshot: SourceCanonicalPhysicsObjectSnapshot) {
        body = snapshot
    }

    func primaryCanonicalPhysicsObject(
        for entity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalPhysicsObjectSnapshot? {
        guard body?.bodyID.entityIdentity == entity else { return nil }
        return body
    }

    func canonicalPhysicsObject(
        for bodyID: SourcePhysicsBodyID
    ) -> SourceCanonicalPhysicsObjectSnapshot? {
        guard body?.bodyID == bodyID else { return nil }
        return body
    }

    func enqueueCanonicalPhysicsObjectMutation(
        _ command: SourcePhysicsBodyMutationCommand
    ) throws {
        guard body?.bodyID == command.bodyID else {
            throw SourceDeterministicPhysicsEnvironment.Error
                .missingBody(command.bodyID)
        }
        mutations.append(command)
    }
}
