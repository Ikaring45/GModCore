import Foundation
import XCTest
import GModEngine
@testable import GModGameSession

final class GModDynamicEntityRenderSceneTests: XCTestCase {
    func testSharedAppearanceCompilesOnceAndTransformOnlyUpdateReusesIt() throws {
        let probe = RenderableCompileProbe()
        let cache = try makeCache(probe: probe)
        let projector = try GModDynamicEntityRenderSceneProjector(resolver: cache)

        let first = prop(index: 10, revision: 1, x: 1)
        let second = prop(index: 11, revision: 1, x: 2)
        XCTAssertTrue(try projector.update(from: projection(
            sequence: 1,
            entities: [first, second]
        )))
        let initial = try XCTUnwrap(projector.snapshot(ifChangedFrom: nil))
        XCTAssertEqual(initial.revision, 1)
        XCTAssertEqual(initial.resources.count, 1)
        XCTAssertEqual(initial.instances.count, 2)
        XCTAssertEqual(probe.callCount, 1)

        let moved = prop(index: 10, revision: 2, x: 50)
        XCTAssertTrue(try projector.update(from: projection(
            sequence: 2,
            entities: [moved, second]
        )))
        let updated = try XCTUnwrap(projector.snapshot(
            ifChangedFrom: initial.revision
        ))
        XCTAssertEqual(updated.revision, 2)
        XCTAssertEqual(updated.instances.first?.transform.origin.x, 50)
        XCTAssertEqual(probe.callCount, 1)

        let nonVisualRevision = prop(index: 10, revision: 3, x: 50)
        XCTAssertFalse(try projector.update(from: projection(
            sequence: 3,
            entities: [nonVisualRevision, second]
        )))
        XCTAssertNil(projector.snapshot(ifChangedFrom: updated.revision))
        XCTAssertEqual(projector.sourceProjectionCursor?.sequence, 3)
        XCTAssertEqual(probe.callCount, 1)
    }

    func testFailureIsCachedAndDoesNotCreateAPlaceholder() throws {
        let probe = RenderableCompileProbe(failingPaths: ["models/bad.mdl"])
        let cache = try makeCache(probe: probe)
        let projector = try GModDynamicEntityRenderSceneProjector(resolver: cache)
        let bad = prop(
            index: 3,
            revision: 1,
            x: 0,
            modelPath: "models/bad.mdl"
        )
        let good = prop(index: 4, revision: 1, x: 1)

        XCTAssertTrue(try projector.update(from: projection(
            sequence: 1,
            entities: [bad, good]
        )))
        let scene = try XCTUnwrap(projector.snapshot(ifChangedFrom: nil))
        XCTAssertEqual(scene.instances.map(\.identity), [good.identity])
        XCTAssertEqual(scene.resources.count, 1)
        XCTAssertEqual(scene.issues.map(\.identity), [bad.identity])
        XCTAssertEqual(probe.callCount, 2)

        XCTAssertFalse(try projector.update(from: projection(
            sequence: 2,
            entities: [prop(
                index: 3,
                revision: 2,
                x: 0,
                modelPath: "models/bad.mdl"
            ), good]
        )))
        XCTAssertEqual(probe.callCount, 2)
    }

    func testLifecycleSerialReuseAndDisconnectPublishExactSceneChanges() throws {
        let cache = try makeCache(probe: RenderableCompileProbe())
        let projector = try GModDynamicEntityRenderSceneProjector(resolver: cache)
        let created = prop(index: 8, revision: 0, x: 0, lifecycle: .created)
        XCTAssertTrue(try projector.update(from: projection(
            sequence: 1,
            entities: [created]
        )))
        let empty = try XCTUnwrap(projector.snapshot(ifChangedFrom: nil))
        XCTAssertEqual(empty.instances, [])

        let spawned = prop(index: 8, revision: 1, x: 2, lifecycle: .spawned)
        XCTAssertTrue(try projector.update(from: projection(
            sequence: 2,
            entities: [spawned]
        )))
        let visible = try XCTUnwrap(projector.snapshot(
            ifChangedFrom: empty.revision
        ))
        XCTAssertEqual(visible.instances.map(\.identity), [spawned.identity])

        let replacement = prop(
            index: 8,
            serial: 9,
            revision: 0,
            x: 4,
            lifecycle: .active
        )
        XCTAssertTrue(try projector.update(from: projection(
            sequence: 3,
            entities: [replacement]
        )))
        let replaced = try XCTUnwrap(projector.snapshot(
            ifChangedFrom: visible.revision
        ))
        XCTAssertEqual(replaced.instances.map(\.identity), [replacement.identity])

        XCTAssertTrue(try projector.reset())
        let disconnected = try XCTUnwrap(projector.snapshot(
            ifChangedFrom: replaced.revision
        ))
        XCTAssertNil(disconnected.sourceProjectionCursor)
        XCTAssertEqual(disconnected.resources, [])
        XCTAssertEqual(disconnected.instances, [])
        XCTAssertEqual(disconnected.issues, [])
    }

    func testOlderProjectionAndWrongResolvedIdentityAreTransactional() throws {
        let cache = try makeCache(probe: RenderableCompileProbe())
        let projector = try GModDynamicEntityRenderSceneProjector(resolver: cache)
        let entity = prop(index: 5, revision: 1, x: 1)
        _ = try projector.update(from: projection(sequence: 2, entities: [entity]))
        let committed = try XCTUnwrap(projector.snapshot(ifChangedFrom: nil))

        XCTAssertThrowsError(try projector.update(from: projection(
            sequence: 1,
            entities: []
        ))) { error in
            guard case GModDynamicEntityRenderSceneError.sourceCursorNotIncreasing =
                    error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(projector.snapshot(ifChangedFrom: nil), committed)

        let wrongResolver = WrongIdentityResolver()
        let wrongProjector = try GModDynamicEntityRenderSceneProjector(
            resolver: wrongResolver
        )
        XCTAssertThrowsError(try wrongProjector.update(from: projection(
            sequence: 1,
            entities: [entity]
        ))) { error in
            guard case GModDynamicEntityRenderSceneError
                .resolvedResourceIdentityMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertNil(wrongProjector.snapshot(ifChangedFrom: nil))
    }

    func testOversizedGeometryFailureIsCachedAndLRUEvictsByAppearance() throws {
        let probe = RenderableCompileProbe(vertexCount: 3)
        let cache = try GModStudioRenderableModelCache(
            policy: GModStudioRenderableModelCachePolicy(
                maximumEntryCount: 2,
                maximumGeometryByteCount: 64
            ),
            compile: { [probe] model, bodyValue, skinFamilyIndex in
                probe.resolve(
                    model: model,
                    bodyValue: bodyValue,
                    skinFamilyIndex: skinFamilyIndex
                )
            }
        )
        let model = SourceEntityModelReference("models/large.mdl")
        let first = cache.resolve(model: model, bodyValue: 0, skinFamilyIndex: 0)
        let second = cache.resolve(model: model, bodyValue: 0, skinFamilyIndex: 0)
        XCTAssertEqual(first, second)
        guard case .failed(.cache(.geometryExceedsCache)) = first else {
            return XCTFail("expected a stable cache-cap failure")
        }
        XCTAssertEqual(probe.callCount, 1)
        XCTAssertEqual(cache.cachedEntryCount, 1)
        XCTAssertEqual(cache.cachedGeometryByteCount, 0)
    }

    private func makeCache(
        probe: RenderableCompileProbe
    ) throws -> GModStudioRenderableModelCache {
        try GModStudioRenderableModelCache(
            policy: GModStudioRenderableModelCachePolicy(
                maximumEntryCount: 8,
                maximumGeometryByteCount: 1_024 * 1_024
            ),
            compile: { [probe] model, bodyValue, skinFamilyIndex in
                probe.resolve(
                    model: model,
                    bodyValue: bodyValue,
                    skinFamilyIndex: skinFamilyIndex
                )
            }
        )
    }

    private func projection(
        generation: UInt64 = 1,
        sequence: UInt64,
        entities: [SourceCanonicalEntitySnapshot]
    ) -> SourceCanonicalEntityKindProjection {
        SourceCanonicalEntityKindProjection(
            kind: .propPhysics,
            cursor: SourceEntityReplicationCursor(
                connectionGeneration: SourceEntityReplicationConnectionGeneration(
                    rawValue: generation
                ),
                sequence: sequence
            ),
            entities: entities
        )
    }

    private func prop(
        index: Int,
        serial: Int = 1,
        revision: UInt64,
        x: Float,
        modelPath: String = "models/props/crate.mdl",
        lifecycle: SourceCanonicalEntityLifecycle = .active,
        body: Int = 0,
        skin: Int = 0
    ) -> SourceCanonicalEntitySnapshot {
        SourceCanonicalEntitySnapshot(
            identity: SourceCanonicalEntityIdentity(handle: SourceBaseHandle(
                entryIndex: index,
                serialNumber: serial
            )),
            kind: .propPhysics,
            className: SourceCanonicalEntityKind.propPhysics.className,
            transform: SourceEntityTransform(origin: SourceVector3(x, 0, 0)),
            motion: SourceEntityMotionState(),
            model: SourceEntityModelReference(modelPath),
            solidType: .vPhysics,
            moveType: .vPhysics,
            lifecycle: lifecycle,
            isNetworkable: true,
            revision: revision,
            skin: skin,
            bodyValue: body
        )
    }
}

private final class RenderableCompileProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let failingPaths: Set<String>
    private let vertexCount: Int
    private var callCountStorage = 0

    init(failingPaths: Set<String> = [], vertexCount: Int = 1) {
        self.failingPaths = failingPaths
        self.vertexCount = vertexCount
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCountStorage
    }

    func resolve(
        model: SourceEntityModelReference,
        bodyValue: Int,
        skinFamilyIndex: Int
    ) -> GModStudioRenderableModelResolution {
        lock.lock()
        callCountStorage += 1
        lock.unlock()
        let normalized = model.path.lowercased()
        if failingPaths.contains(normalized) {
            return .failed(.cache(.invalidModelPath(model.path)))
        }
        return .resolved(makeRenderableResource(
            path: normalized,
            bodyValue: bodyValue,
            skinFamilyIndex: skinFamilyIndex,
            vertexCount: vertexCount
        ))
    }
}

private struct WrongIdentityResolver: GModStudioRenderableModelResolving {
    func resolve(
        model: SourceEntityModelReference,
        bodyValue: Int,
        skinFamilyIndex: Int
    ) -> GModStudioRenderableModelResolution {
        .resolved(makeRenderableResource(
            path: "models/wrong.mdl",
            bodyValue: bodyValue,
            skinFamilyIndex: skinFamilyIndex,
            vertexCount: 1
        ))
    }
}

private func makeRenderableResource(
    path: String,
    bodyValue: Int,
    skinFamilyIndex: Int,
    vertexCount: Int
) -> GModStudioRenderableModelResource {
    let checksum: Int32 = 0x1020_3040
    let vertices = (0..<vertexCount).map { index in
        GModDynamicModelVertex(
            position: SourceVector3(Float(index), 0, 0),
            normal: SourceVector3(0, 0, 1),
            textureCoordinate: SourceStudioTextureCoordinate(u: 0, v: 0)
        )
    }
    let model = GModStudioRenderableModelSnapshot(
        checksum: checksum,
        modelName: path,
        lodIndex: 0,
        bodyValue: bodyValue,
        skinFamilyIndex: skinFamilyIndex,
        vertices: vertices,
        indices: vertexCount >= 3 ? [0, 1, 2] : [],
        drawRanges: []
    )
    return GModStudioRenderableModelResource(
        id: GModStudioRenderableModelResourceID(
            normalizedModelPath: path,
            checksum: checksum,
            bodyValue: bodyValue,
            skinFamilyIndex: skinFamilyIndex
        ),
        model: model
    )
}
