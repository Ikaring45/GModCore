import Foundation
import XCTest
import GModEngine
import GModMetal
@testable import GModApp
@testable import GModGameSession

final class GModDynamicEntityMetalSceneBuilderTests: XCTestCase {
    func testProductionResolverPreservesExistingVMTFailureBoundaries() throws {
        let files: [String: Data] = [
            "materials/existing/no_base.vmt": Data(
                "\"VertexLitGeneric\" { }".utf8
            ),
            "materials/existing/missing_base.vmt": Data(
                (
                    "\"VertexLitGeneric\" { \"$basetexture\" " +
                        "\"existing/not_mounted\" }"
                ).utf8
            ),
        ]
        let resolver = GModMetalSurfaceSourceMaterialResolver { path in
            files[path.lowercased()]
        }

        XCTAssertEqual(
            try resolver.resolveStudioMaterialCandidate(
                named: "materials/absent.vmt"
            ),
            .materialMissing
        )
        XCTAssertEqual(
            try resolver.resolveStudioMaterialCandidate(
                named: "materials/existing/no_base.vmt"
            ),
            .materialWithoutBaseTexture
        )
        XCTAssertEqual(
            try resolver.resolveStudioMaterialCandidate(
                named: "materials/existing/missing_base.vmt"
            ),
            .baseTextureMissing
        )
    }

    func testBuildComposesEveryGenerationAndResolvesOrderedCandidates() throws {
        let bitmap = try fixtureBitmap(name: "resolved", seed: 10)
        let probe = MaterialProbe(results: [
            "materials/models/props/missing.vmt": .missing,
            "materials/models/props/crate.vmt": .bitmap(bitmap),
        ])
        let builder = try GModDynamicEntityMetalSceneBuilder(
            policy: policy(bitmapBytes: 128),
            resolveMaterial: { [probe] in try probe.resolve($0) }
        )
        let source = scene(
            revision: 1,
            connection: 7,
            resources: [resource(candidates: [
                "materials/models/props/missing.vmt",
                "materials/models/props/crate.vmt",
            ])]
        )

        let built = try XCTUnwrap(builder.build(
            from: source,
            applicationGeneration: 3,
            laneGeneration: 5
        ))

        XCTAssertEqual(built.generation, GModMetalDynamicEntitySceneGeneration(
            application: 3,
            lane: 5,
            sourceConnection: SourceEntityReplicationConnectionGeneration(
                rawValue: 7
            )
        ))
        XCTAssertEqual(built.revision, 1)
        XCTAssertEqual(built.resources.first?.id.normalizedModelPath,
                       "models/props/crate.mdl")
        XCTAssertEqual(built.instances.first?.identity.serialNumber, 4)
        XCTAssertEqual(
            built.resources.first?.vertices.first?.textureCoordinate,
            SIMD2<Float>(0.25, 0.75)
        )
        XCTAssertEqual(probe.calls, [
            "materials/models/props/missing.vmt",
            "materials/models/props/crate.vmt",
        ])
        guard case let .resolved(candidate, retained)? = built.resources.first?
            .drawRanges.first?.materialResolution else {
            return XCTFail("expected the second ordered VMT candidate")
        }
        XCTAssertEqual(candidate, "materials/models/props/crate.vmt")
        XCTAssertEqual(retained, bitmap)
        XCTAssertEqual(retained.alphaRepresentation, .straight)
        XCTAssertEqual(retained.mipLevels, bitmap.mipLevels)
        XCTAssertEqual(builder.retainedBitmapByteCount, bitmap.totalByteCount)
    }

    func testTransformOnlyUpdateReusesMaterialsAndAppearanceRebuilds() throws {
        let firstBitmap = try fixtureBitmap(name: "first", seed: 20)
        let secondBitmap = try fixtureBitmap(name: "second", seed: 30)
        let firstCandidate = "materials/models/props/crate.vmt"
        let secondCandidate = "materials/models/props/barrel.vmt"
        let probe = MaterialProbe(results: [
            firstCandidate: .bitmap(firstBitmap),
            secondCandidate: .bitmap(secondBitmap),
        ])
        let builder = try GModDynamicEntityMetalSceneBuilder(
            policy: policy(bitmapBytes: 256),
            resolveMaterial: { [probe] in try probe.resolve($0) }
        )
        let initial = try XCTUnwrap(builder.build(
            from: scene(
                revision: 1,
                connection: 2,
                resources: [resource(candidates: [firstCandidate])]
            ),
            applicationGeneration: 1,
            laneGeneration: 9
        ))

        let movedSource = scene(
            revision: 2,
            connection: 2,
            resources: [resource(candidates: [firstCandidate])],
            x: 75,
            entityRevision: 2
        )
        let moved = try XCTUnwrap(builder.build(
            from: movedSource,
            applicationGeneration: 1,
            laneGeneration: 9
        ))

        XCTAssertEqual(probe.calls, [firstCandidate])
        XCTAssertEqual(moved.resources, initial.resources)
        XCTAssertEqual(moved.instances.first?.sourceTransform.origin.x, 75)
        XCTAssertEqual(builder.retainedBitmapByteCount,
                       firstBitmap.totalByteCount)

        let changed = try XCTUnwrap(builder.build(
            from: scene(
                revision: 3,
                connection: 2,
                resources: [resource(
                    path: "models/props/barrel.mdl",
                    checksum: 22,
                    candidates: [secondCandidate]
                )],
                resourcePath: "models/props/barrel.mdl",
                resourceChecksum: 22,
                entityRevision: 3
            ),
            applicationGeneration: 1,
            laneGeneration: 9
        ))
        XCTAssertEqual(probe.calls, [firstCandidate, secondCandidate])
        XCTAssertEqual(changed.resources.map(\.id.normalizedModelPath), [
            "models/props/barrel.mdl",
        ])
        XCTAssertEqual(builder.retainedBitmapByteCount,
                       secondBitmap.totalByteCount)
    }

    func testTypedFailuresNeverBecomePlaceholderBitmaps() throws {
        let retained = try fixtureBitmap(name: "retained", seed: 40)
        let overflow = try fixtureBitmap(name: "overflow", seed: 50)
        let probe = MaterialProbe(results: [
            "materials/missing.vmt": .missing,
            "materials/broken.vmt": .failed(.broken),
            "materials/retained.vmt": .bitmap(retained),
            "materials/overflow.vmt": .bitmap(overflow),
        ])
        let ranges = [
            sourceRange(firstIndex: 0, candidate: "materials/missing.vmt"),
            sourceRange(
                firstIndex: 3,
                candidates: [
                    "materials/broken.vmt",
                    "materials/retained.vmt",
                ]
            ),
            sourceRange(firstIndex: 6, candidate: "materials/retained.vmt"),
            sourceRange(firstIndex: 9, candidate: "materials/overflow.vmt"),
        ]
        let sourceResource = resource(
            vertexCount: 12,
            indices: Array(0..<12).map(UInt32.init),
            ranges: ranges
        )
        let builder = try GModDynamicEntityMetalSceneBuilder(
            policy: policy(bitmapBytes: retained.totalByteCount),
            resolveMaterial: { [probe] in try probe.resolve($0) }
        )

        let built = try XCTUnwrap(builder.build(
            from: scene(revision: 1, connection: 1,
                        resources: [sourceResource]),
            applicationGeneration: 1,
            laneGeneration: 1
        ))
        let resolutions = try XCTUnwrap(built.resources.first).drawRanges.map(
            \.materialResolution
        )

        XCTAssertEqual(resolutions[0], .sourceMissing)
        XCTAssertEqual(
            resolutions[1],
            .decodeFailed(
                candidate: "materials/broken.vmt",
                detail: "broken material"
            )
        )
        XCTAssertEqual(
            resolutions[2],
            .resolved(
                candidate: "materials/retained.vmt",
                bitmap: retained
            )
        )
        XCTAssertEqual(
            resolutions[3],
            .retentionCapacityExceeded(
                candidate: "materials/overflow.vmt",
                requiredByteCount: overflow.totalByteCount,
                retainedByteCount: retained.totalByteCount,
                maximumByteCount: retained.totalByteCount
            )
        )
        XCTAssertNil(resolutions[0].bitmap)
        XCTAssertNil(resolutions[1].bitmap)
        XCTAssertNil(resolutions[3].bitmap)
        XCTAssertEqual(builder.retainedBitmapByteCount,
                       retained.totalByteCount)
        XCTAssertEqual(probe.calls, [
            "materials/missing.vmt",
            "materials/broken.vmt",
            "materials/retained.vmt",
            "materials/overflow.vmt",
        ])
    }

    func testStructuralFailureRetainsPriorSceneAndCursorlessResetClearsIt() throws {
        let candidate = "materials/models/props/crate.vmt"
        let probe = MaterialProbe(results: [
            candidate: .bitmap(try fixtureBitmap(name: "stable", seed: 60)),
        ])
        let builder = try GModDynamicEntityMetalSceneBuilder(
            policy: policy(bitmapBytes: 128),
            resolveMaterial: { [probe] in try probe.resolve($0) }
        )
        let committed = try XCTUnwrap(builder.build(
            from: scene(
                revision: 1,
                connection: 8,
                resources: [resource(candidates: [candidate])]
            ),
            applicationGeneration: 4,
            laneGeneration: 6
        ))
        let invalid = resource(
            path: "models/props/invalid.mdl",
            checksum: 99,
            candidates: [candidate],
            indices: [0, 1, 99]
        )

        XCTAssertThrowsError(try builder.build(
            from: scene(
                revision: 2,
                connection: 8,
                resources: [invalid],
                resourcePath: "models/props/invalid.mdl",
                resourceChecksum: 99,
                entityRevision: 2
            ),
            applicationGeneration: 4,
            laneGeneration: 6
        ))
        XCTAssertEqual(builder.currentScene, committed)

        let cleared = try XCTUnwrap(builder.build(
            from: GModDynamicEntityRenderSceneSnapshot(
                revision: 2,
                sourceProjectionCursor: nil,
                resources: [],
                instances: [],
                issues: []
            ),
            applicationGeneration: 4,
            laneGeneration: 6
        ))
        XCTAssertEqual(cleared.generation, committed.generation)
        XCTAssertEqual(cleared.resources, [])
        XCTAssertEqual(cleared.instances, [])
        XCTAssertEqual(builder.retainedBitmapByteCount, 0)

        let fresh = try GModDynamicEntityMetalSceneBuilder(
            policy: policy(bitmapBytes: 128),
            resolveMaterial: { [probe] in try probe.resolve($0) }
        )
        XCTAssertNil(try fresh.build(
            from: GModDynamicEntityRenderSceneSnapshot(
                revision: 1,
                sourceProjectionCursor: nil,
                resources: [],
                instances: [],
                issues: []
            ),
            applicationGeneration: 1,
            laneGeneration: 1
        ))
    }

    func testSourceAndHostGenerationChangesForceNewPublication() throws {
        let candidate = "materials/models/props/crate.vmt"
        let probe = MaterialProbe(results: [
            candidate: .bitmap(try fixtureBitmap(name: "generation", seed: 70)),
        ])
        let builder = try GModDynamicEntityMetalSceneBuilder(
            policy: policy(bitmapBytes: 128),
            resolveMaterial: { [probe] in try probe.resolve($0) }
        )
        _ = try builder.build(
            from: scene(
                revision: 1,
                connection: 1,
                resources: [resource(candidates: [candidate])]
            ),
            applicationGeneration: 1,
            laneGeneration: 1
        )
        let reconnected = try XCTUnwrap(builder.build(
            from: scene(
                revision: 1,
                connection: 2,
                resources: [resource(candidates: [candidate])]
            ),
            applicationGeneration: 1,
            laneGeneration: 1
        ))
        let replacedApp = try XCTUnwrap(builder.build(
            from: scene(
                revision: 1,
                connection: 1,
                resources: [resource(candidates: [candidate])]
            ),
            applicationGeneration: 2,
            laneGeneration: 1
        ))

        XCTAssertEqual(reconnected.generation.sourceConnection.rawValue, 2)
        XCTAssertEqual(replacedApp.generation.application, 2)
        XCTAssertEqual(replacedApp.generation.sourceConnection.rawValue, 1)
        XCTAssertEqual(probe.calls, [candidate, candidate, candidate])
    }

    func testCurrentBudgetFailureClearsButStaleFailureCannotClearNewerScene()
        throws
    {
        let candidate = "materials/models/props/crate.vmt"
        let probe = MaterialProbe(results: [
            candidate: .bitmap(try fixtureBitmap(name: "budget", seed: 80)),
        ])
        let builder = try GModDynamicEntityMetalSceneBuilder(
            policy: policy(
                bitmapBytes: 128,
                maximumTotalVertexCount: 3
            ),
            resolveMaterial: { [probe] in try probe.resolve($0) }
        )
        let firstSnapshot = scene(
            revision: 1,
            connection: 9,
            resources: [resource(candidates: [candidate])]
        )
        let firstScene = try XCTUnwrap(builder.build(
            from: firstSnapshot,
            applicationGeneration: 4,
            laneGeneration: 6
        ))
        var publishedScene: GModMetalDynamicEntityScene? = firstScene
        var consumedSourceRevision: UInt64? = firstSnapshot.revision

        let rejectedSnapshot = scene(
            revision: 2,
            connection: 9,
            resources: [resource(
                path: "models/props/oversize.mdl",
                checksum: 99,
                candidates: [candidate],
                vertexCount: 4
            )],
            resourcePath: "models/props/oversize.mdl",
            resourceChecksum: 99,
            entityRevision: 2
        )
        var rejectionDescription: String?
        XCTAssertThrowsError(try builder.build(
            from: rejectedSnapshot,
            applicationGeneration: 4,
            laneGeneration: 6
        )) { error in
            XCTAssertEqual(
                error as? GModMetalDynamicEntitySceneError,
                .countBudgetExceeded(kind: "vertex", requested: 4, cap: 3)
            )
            rejectionDescription = GMLuaRuntime.describe(error)
        }
        let failure = try XCTUnwrap(rejectionDescription)
        let rejectedRequest = GModDynamicEntitySceneBuildRequest(
            snapshot: rejectedSnapshot,
            applicationGeneration: 4,
            laneGeneration: 6,
            buildEpoch: 7,
            requestRevision: 2
        )
        let rejectedResult = GModDynamicEntitySceneBuildResult(
            scene: nil,
            failure: failure
        )

        switch GModDynamicEntitySceneBuildCompletion.resolve(
            request: rejectedRequest,
            result: rejectedResult,
            currentBuildEpoch: 7,
            currentRequestRevision: 2,
            currentApplicationGeneration: 4,
            currentLaneGeneration: 6,
            isReady: true
        ) {
        case let .reject(revision, receivedFailure):
            consumedSourceRevision = revision
            publishedScene = nil
            builder.reset()
            XCTAssertEqual(receivedFailure, failure)
        default:
            XCTFail("the current failed conversion must be rejected")
        }
        XCTAssertEqual(consumedSourceRevision, 2)
        XCTAssertNil(publishedScene)
        XCTAssertNil(builder.currentScene)

        let newerSnapshot = scene(
            revision: 3,
            connection: 9,
            resources: [resource(candidates: [candidate])],
            x: 30,
            entityRevision: 3
        )
        let newerScene = try XCTUnwrap(builder.build(
            from: newerSnapshot,
            applicationGeneration: 4,
            laneGeneration: 6
        ))
        let newerRequest = GModDynamicEntitySceneBuildRequest(
            snapshot: newerSnapshot,
            applicationGeneration: 4,
            laneGeneration: 6,
            buildEpoch: 8,
            requestRevision: 3
        )
        switch GModDynamicEntitySceneBuildCompletion.resolve(
            request: newerRequest,
            result: GModDynamicEntitySceneBuildResult(
                scene: newerScene,
                failure: nil
            ),
            currentBuildEpoch: 8,
            currentRequestRevision: 3,
            currentApplicationGeneration: 4,
            currentLaneGeneration: 6,
            isReady: true
        ) {
        case let .publish(revision, scene):
            consumedSourceRevision = revision
            publishedScene = scene
        default:
            XCTFail("the newer valid conversion must publish")
        }

        let staleCompletion = GModDynamicEntitySceneBuildCompletion.resolve(
            request: rejectedRequest,
            result: rejectedResult,
            currentBuildEpoch: 8,
            currentRequestRevision: 3,
            currentApplicationGeneration: 4,
            currentLaneGeneration: 6,
            isReady: true
        )
        if case .reject = staleCompletion {
            publishedScene = nil
        }
        XCTAssertEqual(staleCompletion, .discard)
        XCTAssertEqual(consumedSourceRevision, 3)
        XCTAssertEqual(publishedScene, newerScene)
    }
}

private enum FixtureMaterialError: Error, Sendable, CustomStringConvertible {
    case broken

    var description: String { "broken material" }
}

private final class MaterialProbe: @unchecked Sendable {
    enum Result: Sendable {
        case missing
        case bitmap(GModMetalSurfaceBitmap)
        case failed(FixtureMaterialError)
    }

    private let lock = NSLock()
    private let results: [String: Result]
    private var callsStorage: [String] = []

    init(results: [String: Result]) {
        self.results = results
    }

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return callsStorage
    }

    func resolve(
        _ candidate: String
    ) throws -> GModMetalStudioMaterialCandidateResolution {
        lock.lock()
        callsStorage.append(candidate)
        let result = results[candidate]
        lock.unlock()
        switch result {
        case .none, .some(.missing): return .materialMissing
        case let .some(.bitmap(bitmap)): return .resolved(bitmap)
        case let .some(.failed(error)): throw error
        }
    }
}

private func policy(
    bitmapBytes: Int,
    maximumTotalVertexCount: Int = 1_024
) -> GModDynamicEntityMetalSceneBuilderPolicy {
    GModDynamicEntityMetalSceneBuilderPolicy(
        metalScene: GModMetalDynamicEntityScenePolicy(
            maximumResourceCount: 16,
            maximumInstanceCount: 32,
            maximumTotalVertexCount: maximumTotalVertexCount,
            maximumTotalIndexCount: 3_072,
            maximumTotalDrawRangeCount: 128,
            maximumGeometryByteCount: 1_024 * 1_024,
            maximumMetadataUTF8ByteCount: 1_024 * 1_024
        ),
        maximumRetainedBitmapByteCount: bitmapBytes
    )
}

private func scene(
    revision: UInt64,
    connection: UInt64,
    resources: [GModStudioRenderableModelResource],
    resourcePath: String = "models/props/crate.mdl",
    resourceChecksum: Int32 = 11,
    x: Float = 10,
    entityRevision: UInt64 = 1
) -> GModDynamicEntityRenderSceneSnapshot {
    let resourceID = GModStudioRenderableModelResourceID(
        normalizedModelPath: resourcePath,
        checksum: resourceChecksum,
        bodyValue: 0,
        skinFamilyIndex: 0
    )
    return GModDynamicEntityRenderSceneSnapshot(
        revision: revision,
        sourceProjectionCursor: SourceEntityReplicationCursor(
            connectionGeneration: SourceEntityReplicationConnectionGeneration(
                rawValue: connection
            ),
            sequence: revision
        ),
        resources: resources,
        instances: [GModDynamicEntityRenderInstanceSnapshot(
            identity: SourceCanonicalEntityIdentity(handle: SourceBaseHandle(
                entryIndex: 12,
                serialNumber: 4
            )),
            sourceEntityRevision: entityRevision,
            transform: SourceEntityTransform(origin: SourceVector3(x, 2, 3)),
            resourceID: resourceID
        )],
        issues: []
    )
}

private func resource(
    path: String = "models/props/crate.mdl",
    checksum: Int32 = 11,
    candidates: [String] = ["materials/models/props/crate.vmt"],
    vertexCount: Int = 3,
    indices: [UInt32] = [0, 1, 2],
    ranges: [GModStudioRenderableDrawRange]? = nil
) -> GModStudioRenderableModelResource {
    let vertices = (0..<vertexCount).map { index in
        GModDynamicModelVertex(
            position: SourceVector3(Float(index), Float(index + 1), 2),
            normal: SourceVector3(0, 0, 1),
            textureCoordinate: SourceStudioTextureCoordinate(u: 0.25, v: 0.75)
        )
    }
    let actualRanges = ranges ?? [GModStudioRenderableDrawRange(
        bodyPartIndex: 0,
        submodelIndex: 0,
        meshIndex: 0,
        firstIndex: 0,
        indexCount: indices.count,
        material: GModStudioRenderableMaterial(
            sourceMaterialIndex: 0,
            skinFamilyIndex: 0,
            textureIndex: 0,
            textureName: "crate",
            vmtCandidates: candidates
        )
    )]
    let model = GModStudioRenderableModelSnapshot(
        checksum: checksum,
        modelName: path,
        lodIndex: 0,
        bodyValue: 0,
        skinFamilyIndex: 0,
        vertices: vertices,
        indices: indices,
        drawRanges: actualRanges
    )
    return GModStudioRenderableModelResource(
        id: GModStudioRenderableModelResourceID(
            normalizedModelPath: path,
            checksum: checksum,
            bodyValue: 0,
            skinFamilyIndex: 0
        ),
        model: model
    )
}

private func sourceRange(
    firstIndex: Int,
    candidate: String
) -> GModStudioRenderableDrawRange {
    sourceRange(firstIndex: firstIndex, candidates: [candidate])
}

private func sourceRange(
    firstIndex: Int,
    candidates: [String]
) -> GModStudioRenderableDrawRange {
    GModStudioRenderableDrawRange(
        bodyPartIndex: 0,
        submodelIndex: 0,
        meshIndex: firstIndex / 3,
        firstIndex: firstIndex,
        indexCount: 3,
        material: GModStudioRenderableMaterial(
            sourceMaterialIndex: Int32(firstIndex / 3),
            skinFamilyIndex: 0,
            textureIndex: firstIndex / 3,
            textureName: "material_\(firstIndex / 3)",
            vmtCandidates: candidates
        )
    )
}

private func fixtureBitmap(
    name: String,
    seed: UInt8
) throws -> GModMetalSurfaceBitmap {
    let base = Data((0..<16).map { seed &+ UInt8($0) })
    let mip = Data([seed, seed &+ 1, seed &+ 2, 255])
    return try GModMetalSurfaceBitmap(
        resourceIdentifier: name,
        width: 2,
        height: 2,
        premultipliedRGBA8: base,
        mipLevels: [
            GModMetalSurfaceMipLevel(
                width: 2,
                height: 2,
                premultipliedRGBA8: base
            ),
            GModMetalSurfaceMipLevel(
                width: 1,
                height: 1,
                premultipliedRGBA8: mip
            ),
        ],
        alphaRepresentation: .straight
    )
}
