import XCTest
import GModEngine
@testable import GModMetal

final class GModMetalDynamicEntitySceneTests: XCTestCase {
    func testBuildSortsResourcesAndFullHandlesAndMatchesSourceTransform() throws {
        let firstID = resourceID(
            path: "models/props/a_prop.mdl",
            checksum: 10
        )
        let secondID = resourceID(
            path: "models/props/z_prop.mdl",
            checksum: 20
        )
        let earlierHandle = identity(entry: 2, serial: 11)
        let laterHandle = identity(entry: 9, serial: 3)
        let transform = SourceEntityTransform(
            origin: SourceVector3(100, -50, 20),
            angles: SourceQAngle(pitch: 17, yaw: 81, roll: -23)
        )

        let scene = try GModMetalDynamicEntityScene(
            generation: generation(),
            revision: 7,
            resources: [
                resource(id: secondID),
                resource(id: firstID),
            ],
            instances: [
                instance(identity: laterHandle, resourceID: secondID),
                instance(
                    identity: earlierHandle,
                    resourceID: firstID,
                    transform: transform
                ),
            ],
            policy: generousPolicy()
        )

        XCTAssertEqual(scene.generation, generation())
        XCTAssertEqual(scene.revision, 7)
        XCTAssertEqual(scene.resources.map(\.id), [firstID, secondID])
        XCTAssertEqual(
            scene.instances.map { $0.identity.handle.rawValue },
            [earlierHandle.handle.rawValue, laterHandle.handle.rawValue]
        )
        XCTAssertEqual(scene.instances[0].identity.serialNumber, 11)
        XCTAssertEqual(scene.instances[1].identity.serialNumber, 3)
        XCTAssertGreaterThan(scene.retainedGeometryByteCount, 0)
        XCTAssertGreaterThan(scene.retainedMetadataUTF8ByteCount, 0)

        let localSourcePoint = SourceVector3(1, 2, 3)
        let localMetalPoint = try XCTUnwrap(
            scene.resources.first?.vertices.first?.metalLocalPosition
        )
        let actualPoint = scene.instances[0].metalTransform.transformPoint(
            localMetalPoint
        )
        let expectedSourcePoint = transform.transformPointFromLocal(
            localSourcePoint
        )
        let expectedPoint = GModMetalWorldScene.convertSourceVector(SIMD3<Float>(
            expectedSourcePoint.x,
            expectedSourcePoint.y,
            expectedSourcePoint.z
        ))
        assertEqual(actualPoint, expectedPoint)

        let localSourceNormal = SourceVector3(0, 0, 1)
        let localMetalNormal = try XCTUnwrap(
            scene.resources.first?.vertices.first?.metalLocalNormal
        )
        let actualNormal = scene.instances[0].metalTransform.transformDirection(
            localMetalNormal
        )
        let expectedSourceNormal = transform.transformDirectionFromLocal(
            localSourceNormal
        )
        let expectedNormal = GModMetalWorldScene.convertSourceVector(SIMD3<Float>(
            expectedSourceNormal.x,
            expectedSourceNormal.y,
            expectedSourceNormal.z
        ))
        assertEqual(actualNormal, expectedNormal)
    }

    func testTransformOnlyUpdateReusesResourcesWithinCompleteGeneration() throws {
        let id = resourceID()
        let entity = identity(entry: 5, serial: 9)
        let original = try GModMetalDynamicEntityScene(
            generation: generation(),
            revision: 3,
            resources: [resource(id: id)],
            instances: [instance(identity: entity, resourceID: id)],
            policy: generousPolicy()
        )
        let movedTransform = SourceEntityTransform(
            origin: SourceVector3(16, 32, 64),
            angles: SourceQAngle(pitch: 5, yaw: 90, roll: 0)
        )
        let moved = try original.updatingInstances(
            revision: 4,
            instances: [instance(
                identity: entity,
                resourceID: id,
                transform: movedTransform
            )]
        )

        XCTAssertEqual(moved.generation, original.generation)
        XCTAssertEqual(moved.revision, 4)
        XCTAssertEqual(moved.resources, original.resources)
        XCTAssertEqual(moved.instances.first?.sourceTransform, movedTransform)
        let originalStorage = original.resources[0].vertices.withUnsafeBufferPointer {
            $0.baseAddress
        }
        let movedStorage = moved.resources[0].vertices.withUnsafeBufferPointer {
            $0.baseAddress
        }
        XCTAssertEqual(
            originalStorage,
            movedStorage,
            "transform-only publication must keep immutable geometry storage"
        )
        XCTAssertThrowsError(try moved.updatingInstances(
            revision: 5,
            instances: [instance(
                identity: entity,
                resourceID: id,
                sourceEntityRevision: 41
            )]
        )) { error in
            XCTAssertEqual(
                error as? GModMetalDynamicEntitySceneError,
                .sourceEntityRevisionWentBackwards(
                    handle: entity.handle.rawValue,
                    previous: 42,
                    received: 41
                )
            )
        }
        XCTAssertThrowsError(try moved.updatingInstances(
            revision: 4,
            instances: []
        )) { error in
            XCTAssertEqual(
                error as? GModMetalDynamicEntitySceneError,
                .revisionNotIncreasing(previous: 4, received: 4)
            )
        }
    }

    func testCompleteGenerationRejectsZeroComponents() {
        let invalid = GModMetalDynamicEntitySceneGeneration(
            application: 0,
            lane: 2,
            sourceConnection: .init(rawValue: 1)
        )
        XCTAssertThrowsError(try GModMetalDynamicEntityScene(
            generation: invalid,
            revision: 1,
            resources: [],
            instances: [],
            policy: generousPolicy()
        )) { error in
            XCTAssertEqual(
                error as? GModMetalDynamicEntitySceneError,
                .invalidSceneGeneration(field: "application", value: 0)
            )
        }
    }

    func testResourceIdentityAndCanonicalPathAreFailClosed() {
        let validID = resourceID()
        XCTAssertThrowsError(try GModMetalDynamicEntityScene(
            generation: generation(),
            revision: 1,
            resources: [resource(id: validID, compiledChecksum: 999)],
            instances: [],
            policy: generousPolicy()
        )) { error in
            XCTAssertEqual(
                error as? GModMetalDynamicEntitySceneError,
                .invalidResourceIdentity(id: validID, field: "checksum")
            )
        }

        let nonCanonical = resourceID(path: "Models/Props/Test.mdl")
        XCTAssertThrowsError(try GModMetalDynamicEntityScene(
            generation: generation(),
            revision: 1,
            resources: [resource(id: nonCanonical)],
            instances: [],
            policy: generousPolicy()
        )) { error in
            XCTAssertEqual(
                error as? GModMetalDynamicEntitySceneError,
                .nonCanonicalModelPath("Models/Props/Test.mdl")
            )
        }
    }

    func testNaNZeroNormalAndOutOfRangeIndexAreFailClosed() {
        let id = resourceID()
        var vertices = sourceVertices()
        vertices[0] = GModMetalDynamicEntitySourceVertex(
            position: SourceVector3(.nan, 2, 3),
            normal: SourceVector3(0, 0, 1),
            textureCoordinate: .zero
        )
        XCTAssertThrowsError(try GModMetalDynamicEntityScene(
            generation: generation(),
            revision: 1,
            resources: [resource(id: id, vertices: vertices)],
            instances: [],
            policy: generousPolicy()
        )) { error in
            XCTAssertEqual(
                error as? GModMetalDynamicEntitySceneError,
                .invalidVertex(id: id, index: 0, field: "position")
            )
        }

        vertices = sourceVertices()
        vertices[0] = GModMetalDynamicEntitySourceVertex(
            position: SourceVector3(1, 2, 3),
            normal: .zero,
            textureCoordinate: .zero
        )
        XCTAssertThrowsError(try GModMetalDynamicEntityScene(
            generation: generation(),
            revision: 1,
            resources: [resource(id: id, vertices: vertices)],
            instances: [],
            policy: generousPolicy()
        )) { error in
            XCTAssertEqual(
                error as? GModMetalDynamicEntitySceneError,
                .invalidVertex(id: id, index: 0, field: "normal")
            )
        }

        XCTAssertThrowsError(try GModMetalDynamicEntityScene(
            generation: generation(),
            revision: 1,
            resources: [resource(id: id, indices: [0, 1, 3])],
            instances: [],
            policy: generousPolicy()
        )) { error in
            XCTAssertEqual(
                error as? GModMetalDynamicEntitySceneError,
                .invalidIndex(id: id, position: 2, value: 3, vertexCount: 3)
            )
        }
    }

    func testDrawRangesRequireContiguousTrianglesAndLogicalVMTs() {
        let id = resourceID()
        let gap = drawRange(firstIndex: 1, indexCount: 2)
        XCTAssertThrowsError(try GModMetalDynamicEntityScene(
            generation: generation(),
            revision: 1,
            resources: [resource(id: id, drawRanges: [gap])],
            instances: [],
            policy: generousPolicy()
        )) { error in
            XCTAssertEqual(
                error as? GModMetalDynamicEntitySceneError,
                .invalidDrawRange(
                    id: id,
                    index: 0,
                    reason: "non-contiguous or out-of-bounds index span"
                )
            )
        }

        let invalidMaterial = GModMetalDynamicEntityMaterialBinding(
            sourceMaterialIndex: 0,
            skinFamilyIndex: 0,
            textureIndex: 0,
            textureName: "test",
            vmtCandidates: ["../test.vmt"]
        )
        let invalidVMT = GModMetalDynamicEntityDrawRange(
            bodyPartIndex: 0,
            submodelIndex: 0,
            meshIndex: 0,
            firstIndex: 0,
            indexCount: 3,
            material: invalidMaterial
        )
        XCTAssertThrowsError(try GModMetalDynamicEntityScene(
            generation: generation(),
            revision: 1,
            resources: [resource(id: id, drawRanges: [invalidVMT])],
            instances: [],
            policy: generousPolicy()
        )) { error in
            XCTAssertEqual(
                error as? GModMetalDynamicEntitySceneError,
                .invalidDrawRange(
                    id: id,
                    index: 0,
                    reason: "invalid VMT candidate '../test.vmt'"
                )
            )
        }
    }

    func testAggregateBudgetsRejectBeforePublishingScene() {
        let id = resourceID()
        let vertexLimited = policy(maximumTotalVertexCount: 2)
        XCTAssertThrowsError(try GModMetalDynamicEntityScene(
            generation: generation(),
            revision: 1,
            resources: [resource(id: id)],
            instances: [],
            policy: vertexLimited
        )) { error in
            XCTAssertEqual(
                error as? GModMetalDynamicEntitySceneError,
                .countBudgetExceeded(kind: "vertex", requested: 3, cap: 2)
            )
        }

        let geometryLimited = policy(maximumGeometryByteCount: 1)
        XCTAssertThrowsError(try GModMetalDynamicEntityScene(
            generation: generation(),
            revision: 1,
            resources: [resource(id: id)],
            instances: [],
            policy: geometryLimited
        )) { error in
            guard case let .geometryByteBudgetExceeded(requested, cap)? =
                    error as? GModMetalDynamicEntitySceneError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertGreaterThan(requested, 1)
            XCTAssertEqual(cap, 1)
        }

        let metadataLimited = policy(maximumMetadataUTF8ByteCount: 1)
        XCTAssertThrowsError(try GModMetalDynamicEntityScene(
            generation: generation(),
            revision: 1,
            resources: [resource(id: id)],
            instances: [],
            policy: metadataLimited
        )) { error in
            guard case let .metadataByteBudgetExceeded(requested, cap)? =
                    error as? GModMetalDynamicEntitySceneError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertGreaterThan(requested, 1)
            XCTAssertEqual(cap, 1)
        }
    }

    func testInstancesRequireOneGenerationPerEntryAndExistingResource() {
        let id = resourceID()
        let first = identity(entry: 4, serial: 1)
        let reused = identity(entry: 4, serial: 2)
        XCTAssertThrowsError(try GModMetalDynamicEntityScene(
            generation: generation(),
            revision: 1,
            resources: [resource(id: id)],
            instances: [
                instance(identity: reused, resourceID: id),
                instance(identity: first, resourceID: id),
            ],
            policy: generousPolicy()
        )) { error in
            XCTAssertEqual(
                error as? GModMetalDynamicEntitySceneError,
                .duplicateEntityEntryIndex(
                    entryIndex: 4,
                    firstHandle: first.handle.rawValue,
                    secondHandle: reused.handle.rawValue
                )
            )
        }

        let missing = resourceID(path: "models/props/missing.mdl", checksum: 12)
        XCTAssertThrowsError(try GModMetalDynamicEntityScene(
            generation: generation(),
            revision: 1,
            resources: [resource(id: id)],
            instances: [instance(identity: first, resourceID: missing)],
            policy: generousPolicy()
        )) { error in
            XCTAssertEqual(
                error as? GModMetalDynamicEntitySceneError,
                .missingInstanceResource(
                    handle: first.handle.rawValue,
                    resourceID: missing
                )
            )
        }

        let invalidTransform = SourceEntityTransform(
            origin: SourceVector3(.infinity, 0, 0)
        )
        XCTAssertThrowsError(try GModMetalDynamicEntityScene(
            generation: generation(),
            revision: 1,
            resources: [resource(id: id)],
            instances: [instance(
                identity: first,
                resourceID: id,
                transform: invalidTransform
            )],
            policy: generousPolicy()
        )) { error in
            XCTAssertEqual(
                error as? GModMetalDynamicEntitySceneError,
                .invalidInstanceTransform(handle: first.handle.rawValue)
            )
        }
    }
}

private extension GModMetalDynamicEntitySceneTests {
    func generation() -> GModMetalDynamicEntitySceneGeneration {
        GModMetalDynamicEntitySceneGeneration(
            application: 5,
            lane: 7,
            sourceConnection: .init(rawValue: 1)
        )
    }

    func resourceID(
        path: String = "models/props/test.mdl",
        checksum: Int32 = 10,
        bodyValue: Int = 0,
        skinFamilyIndex: Int = 0
    ) -> GModMetalDynamicEntityResourceID {
        GModMetalDynamicEntityResourceID(
            normalizedModelPath: path,
            checksum: checksum,
            bodyValue: bodyValue,
            skinFamilyIndex: skinFamilyIndex
        )
    }

    func sourceVertices() -> [GModMetalDynamicEntitySourceVertex] {
        [
            .init(
                position: SourceVector3(1, 2, 3),
                normal: SourceVector3(0, 0, 1),
                textureCoordinate: SIMD2<Float>(0, 0)
            ),
            .init(
                position: SourceVector3(4, 5, 6),
                normal: SourceVector3(0, 0, 1),
                textureCoordinate: SIMD2<Float>(1, 0)
            ),
            .init(
                position: SourceVector3(7, 8, 9),
                normal: SourceVector3(0, 0, 1),
                textureCoordinate: SIMD2<Float>(0, 1)
            ),
        ]
    }

    func drawRange(
        firstIndex: Int = 0,
        indexCount: Int = 3,
        skinFamilyIndex: Int = 0
    ) -> GModMetalDynamicEntityDrawRange {
        GModMetalDynamicEntityDrawRange(
            bodyPartIndex: 0,
            submodelIndex: 0,
            meshIndex: 0,
            firstIndex: firstIndex,
            indexCount: indexCount,
            material: GModMetalDynamicEntityMaterialBinding(
                sourceMaterialIndex: 0,
                skinFamilyIndex: skinFamilyIndex,
                textureIndex: 0,
                textureName: "test",
                vmtCandidates: ["materials/models/props/test.vmt"]
            )
        )
    }

    func resource(
        id: GModMetalDynamicEntityResourceID,
        compiledChecksum: Int32? = nil,
        vertices: [GModMetalDynamicEntitySourceVertex]? = nil,
        indices: [UInt32] = [0, 1, 2],
        drawRanges: [GModMetalDynamicEntityDrawRange]? = nil
    ) -> GModMetalDynamicEntityResourceInput {
        GModMetalDynamicEntityResourceInput(
            id: id,
            checksum: compiledChecksum ?? id.checksum,
            modelName: id.normalizedModelPath,
            lodIndex: 0,
            bodyValue: id.bodyValue,
            skinFamilyIndex: id.skinFamilyIndex,
            vertices: vertices ?? sourceVertices(),
            indices: indices,
            drawRanges: drawRanges ?? [drawRange(
                indexCount: indices.count,
                skinFamilyIndex: id.skinFamilyIndex
            )]
        )
    }

    func identity(entry: Int, serial: Int) -> SourceCanonicalEntityIdentity {
        SourceCanonicalEntityIdentity(handle: SourceBaseHandle(
            entryIndex: entry,
            serialNumber: serial
        ))
    }

    func instance(
        identity: SourceCanonicalEntityIdentity,
        resourceID: GModMetalDynamicEntityResourceID,
        transform: SourceEntityTransform = .identity,
        sourceEntityRevision: UInt64 = 42
    ) -> GModMetalDynamicEntityInstanceInput {
        GModMetalDynamicEntityInstanceInput(
            identity: identity,
            sourceEntityRevision: sourceEntityRevision,
            transform: transform,
            resourceID: resourceID
        )
    }

    func generousPolicy() -> GModMetalDynamicEntityScenePolicy {
        policy()
    }

    func policy(
        maximumTotalVertexCount: Int = 100,
        maximumGeometryByteCount: Int = 1_000_000,
        maximumMetadataUTF8ByteCount: Int = 100_000
    ) -> GModMetalDynamicEntityScenePolicy {
        GModMetalDynamicEntityScenePolicy(
            maximumResourceCount: 8,
            maximumInstanceCount: 8,
            maximumTotalVertexCount: maximumTotalVertexCount,
            maximumTotalIndexCount: 100,
            maximumTotalDrawRangeCount: 20,
            maximumGeometryByteCount: maximumGeometryByteCount,
            maximumMetadataUTF8ByteCount: maximumMetadataUTF8ByteCount
        )
    }

    func assertEqual(
        _ actual: SIMD3<Float>,
        _ expected: SIMD3<Float>,
        accuracy: Float = 0.000_1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, file: file, line: line)
    }
}
