import Foundation
import XCTest
@testable import GModGameSession
@testable import GModEngine

final class GModStudioModelRepositoryTests: XCTestCase {
    func testExplicitDX90PathsAreCachedAndMissingModelIsInvalid() {
        let recorder = LoadRecorder(outcome: .unavailable(.missing(
            kind: .mdl,
            path: "models/props/test.mdl"
        )))
        let repository = GModStudioModelRepository { [recorder] paths, requirement in
            recorder.load(paths: paths, requirement: requirement)
        }
        let model = SourceEntityModelReference("models/props/test.mdl")

        XCTAssertEqual(repository.validation(for: model, kind: .propPhysics), .invalid)
        XCTAssertEqual(repository.validation(for: model, kind: .propPhysics), .invalid)
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests.first?.paths.mdl, "models/props/test.mdl")
        XCTAssertEqual(recorder.requests.first?.paths.vvd, "models/props/test.vvd")
        XCTAssertEqual(recorder.requests.first?.paths.vtx, "models/props/test.dx90.vtx")
        XCTAssertNil(recorder.requests.first?.paths.phy)
        XCTAssertEqual(recorder.requests.first?.requirement, .render)
    }

    func testOpaquePHYRequestUsesSeparateCacheAndDoesNotBecomePropVerdict() {
        let recorder = LoadRecorder(outcome: .unavailable(.readFailed(
            kind: .phy,
            path: "models/props/test.phy",
            reason: "injected I/O failure"
        )))
        let repository = GModStudioModelRepository { [recorder] paths, requirement in
            recorder.load(paths: paths, requirement: requirement)
        }
        let model = SourceEntityModelReference("models/props/test.mdl")

        _ = repository.renderAssetWithOpaquePHY(for: model)
        _ = repository.renderAssetWithOpaquePHY(for: model)

        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests.first?.paths.phy, "models/props/test.phy")
        XCTAssertEqual(
            recorder.requests.first?.requirement,
            .renderWithOpaquePHYCompanion
        )
    }

    func testReadFailureIsUnavailableAndInvalidPathDoesNotReachLoader() {
        let recorder = LoadRecorder(outcome: .unavailable(.readFailed(
            kind: .mdl,
            path: "models/props/test.mdl",
            reason: "injected"
        )))
        let repository = GModStudioModelRepository { [recorder] paths, requirement in
            recorder.load(paths: paths, requirement: requirement)
        }

        XCTAssertEqual(
            repository.validation(
                for: SourceEntityModelReference("models/props/test.mdl"),
                kind: .propPhysics
            ),
            .unavailable
        )
        _ = repository.renderAsset(for: SourceEntityModelReference("../outside.mdl"))
        XCTAssertEqual(recorder.requests.count, 1)
    }

    func testWeaponValidationAndCollisionPropertyUseAuthoredStudioHull() throws {
        let model = SourceEntityModelReference(
            "models/weapons/w_authored_test.mdl"
        )
        let checksum: Int32 = 207
        var files = studioFiles([(model.path, checksum)])
        files[model.path] = makeMDL(
            path: model.path,
            checksum: checksum,
            hullMinimum: SourceVector3(-11, -7, -3),
            hullMaximum: SourceVector3(13, 8, 9)
        )
        let repository = GModStudioModelRepository(
            reader: CountingStudioAssetReader(files: files),
            budget: repositoryBudget()
        )

        XCTAssertEqual(repository.validation(for: model, kind: .weapon), .valid)
        XCTAssertEqual(
            repository.collisionPropertyResolution(for: model, kind: .weapon),
            .valid(try SourceCollisionProperty(
                mins: SourceVector3(-11, -7, -3),
                maxs: SourceVector3(13, 8, 9)
            ))
        )
        XCTAssertEqual(
            repository.collisionPropertyResolution(
                for: model,
                kind: .propPhysics
            ),
            .unavailable,
            "Studio hull metadata must not replace an attested prop PHY contract"
        )
    }

    func testRawAssetCacheEvictsLeastRecentModelWithinExactByteCap() {
        let reader = CountingStudioAssetReader(files: studioFiles([
            ("models/a.mdl", 101),
            ("models/b.mdl", 102),
            ("models/c.mdl", 103),
        ]))
        let repository = GModStudioModelRepository(
            reader: reader,
            budget: repositoryBudget(),
            cachePolicy: GModStudioModelRepositoryCachePolicy(
                maximumEntryCount: 2,
                maximumRawByteCount: 1_160
            )
        )
        let a = SourceEntityModelReference("models/a.mdl")
        let b = SourceEntityModelReference("models/b.mdl")
        let c = SourceEntityModelReference("models/c.mdl")

        _ = repository.renderAsset(for: a)
        _ = repository.renderAsset(for: b)
        _ = repository.renderAsset(for: a)
        _ = repository.renderAsset(for: c)
        XCTAssertEqual(repository.cachedEntryCount, 2)
        XCTAssertEqual(repository.cachedRawByteCount, 1_160)
        XCTAssertEqual(reader.readCount(for: "models/a.mdl"), 1)
        XCTAssertEqual(reader.readCount(for: "models/b.mdl"), 1)
        XCTAssertEqual(reader.readCount(for: "models/c.mdl"), 1)

        _ = repository.renderAsset(for: b)
        XCTAssertEqual(reader.readCount(for: "models/b.mdl"), 2)
        XCTAssertEqual(repository.cachedEntryCount, 2)
        XCTAssertLessThanOrEqual(repository.cachedRawByteCount, 1_160)
    }

    func testBodyGroupLayoutAndBodyValueShareValidatedStudioMesh() throws {
        let model = SourceEntityModelReference("models/props/bodygroup.mdl")
        let checksum: Int32 = 701
        let files = studioFiles([(model.path, checksum)])
        let loader = SourceStudioModelAssetLoader(
            reader: CountingStudioAssetReader(files: files),
            budget: repositoryBudget()
        )
        let paths = SourceStudioModelAssetPaths(
            mdl: model.path,
            vvd: "models/props/bodygroup.vvd",
            vtx: "models/props/bodygroup.dx90.vtx"
        )
        let asset = try XCTUnwrap(
            loader.load(paths: paths, requirement: .render).asset
        )
        let mesh = makeBodyGroupMesh(
            checksum: asset.validation.checksum,
            modelName: asset.renderPayload.model.header.name
        )
        let repository = GModStudioModelRepository(
            decodeRootMesh: { _, _ in mesh },
            loadAsset: { _, _ in .loaded(asset) }
        )

        let layout = try repository.bodyGroupLayout(for: model)
        XCTAssertEqual(layout.bodyGroupCount, 2)
        XCTAssertEqual(layout.bodyParts, [
            .init(modelSelectionBase: 1, modelCount: 2),
            .init(modelSelectionBase: 2, modelCount: 3),
        ])
        XCTAssertEqual(layout.appearance?.skinFamilyCount, 0)
        XCTAssertEqual(
            layout.appearance?.bodyGroups.map(\.name),
            ["body_0", "body_1"]
        )
        XCTAssertEqual(
            layout.appearance?.bodyGroups[1].submodelNames,
            ["model_0", "model_1", "model_2"]
        )
        XCTAssertEqual(
            try repository.bodyValue(
                for: model,
                applyingBodyGroups: "12",
                to: 0
            ),
            5
        )

        let mismatchedMesh = makeBodyGroupMesh(
            checksum: checksum &+ 1,
            modelName: asset.renderPayload.model.header.name
        )
        let mismatchedRepository = GModStudioModelRepository(
            decodeRootMesh: { _, _ in mismatchedMesh },
            loadAsset: { _, _ in .loaded(asset) }
        )
        XCTAssertThrowsError(
            try mismatchedRepository.bodyGroupLayout(for: model)
        ) { error in
            XCTAssertEqual(
                error as? GModStudioBodyGroupResolutionError,
                .inconsistentChecksum(
                    expected: checksum,
                    actual: checksum &+ 1
                )
            )
        }
    }

    private func repositoryBudget() -> SourceStudioModelAssetBudget {
        SourceStudioModelAssetBudget(
            maximumBytesByKind: [.mdl: 4_096, .vvd: 4_096, .vtx: 4_096],
            maximumTotalBytes: 12_288,
            maximumVVDVertices: 128,
            maximumVVDFixups: 128,
            maximumVTXBodyParts: 128
        )
    }

    private func studioFiles(
        _ models: [(path: String, checksum: Int32)]
    ) -> [String: Data] {
        var files: [String: Data] = [:]
        for model in models {
            let stem = String(model.path.dropLast(4))
            files[model.path] = makeMDL(path: model.path, checksum: model.checksum)
            files["\(stem).vvd"] = makeVVD(checksum: model.checksum)
            files["\(stem).dx90.vtx"] = makeVTX(checksum: model.checksum)
        }
        return files
    }

    private func makeBodyGroupMesh(
        checksum: Int32,
        modelName: String
    ) -> SourceStudioModelMeshSnapshot {
        SourceStudioModelMeshSnapshot(
            checksum: checksum,
            modelName: modelName,
            lodIndex: 0,
            bodyParts: [2, 3].enumerated().map { bodyGroupID, modelCount in
                SourceStudioBodyPartMeshSnapshot(
                    index: bodyGroupID,
                    name: "body_\(bodyGroupID)",
                    modelSelectionBase: bodyGroupID == 0 ? 1 : 2,
                    models: (0..<modelCount).map { modelID in
                        SourceStudioSubmodelSnapshot(
                            index: modelID,
                            name: "model_\(modelID)",
                            type: 0,
                            boundingRadius: 1,
                            rootLODVertexCount: 0,
                            meshes: []
                        )
                    }
                )
            }
        )
    }

    private func makeMDL(
        path: String,
        checksum: Int32,
        hullMinimum: SourceVector3 = .zero,
        hullMaximum: SourceVector3 = .zero
    ) -> Data {
        var bytes = [UInt8](repeating: 0, count: 408)
        putUInt32(SourceStudioModel.magic, at: 0, into: &bytes)
        putInt32(48, at: 4, into: &bytes)
        putInt32(checksum, at: 8, into: &bytes)
        putCString(path, at: 12, capacity: 64, into: &bytes)
        putInt32(Int32(bytes.count), at: 76, into: &bytes)
        putVector(hullMinimum, at: 104, into: &bytes)
        putVector(hullMaximum, at: 116, into: &bytes)
        putInt32(360, at: 308, into: &bytes)
        putCString("default", at: 360, capacity: 32, into: &bytes)
        return Data(bytes)
    }

    private func makeVVD(checksum: Int32) -> Data {
        var bytes = [UInt8](repeating: 0, count: 128)
        putUInt32(0x5653_4449, at: 0, into: &bytes)
        putInt32(4, at: 4, into: &bytes)
        putInt32(checksum, at: 8, into: &bytes)
        putInt32(1, at: 12, into: &bytes)
        putInt32(1, at: 16, into: &bytes)
        putInt32(64, at: 56, into: &bytes)
        putInt32(112, at: 60, into: &bytes)
        return Data(bytes)
    }

    private func makeVTX(checksum: Int32) -> Data {
        var bytes = [UInt8](repeating: 0, count: 44)
        putInt32(7, at: 0, into: &bytes)
        putInt32(32, at: 4, into: &bytes)
        putUInt16(3, at: 8, into: &bytes)
        putUInt16(3, at: 10, into: &bytes)
        putInt32(3, at: 12, into: &bytes)
        putInt32(checksum, at: 16, into: &bytes)
        putInt32(1, at: 20, into: &bytes)
        putInt32(36, at: 24, into: &bytes)
        return Data(bytes)
    }

    private func putCString(
        _ value: String,
        at offset: Int,
        capacity: Int,
        into bytes: inout [UInt8]
    ) {
        let encoded = Array(value.utf8.prefix(capacity - 1))
        bytes.replaceSubrange(offset..<(offset + encoded.count), with: encoded)
        bytes[offset + encoded.count] = 0
    }

    private func putUInt16(_ value: UInt16, at offset: Int, into bytes: inout [UInt8]) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private func putInt32(_ value: Int32, at offset: Int, into bytes: inout [UInt8]) {
        putUInt32(UInt32(bitPattern: value), at: offset, into: &bytes)
    }

    private func putVector(
        _ value: SourceVector3,
        at offset: Int,
        into bytes: inout [UInt8]
    ) {
        putUInt32(value.x.bitPattern, at: offset, into: &bytes)
        putUInt32(value.y.bitPattern, at: offset + 4, into: &bytes)
        putUInt32(value.z.bitPattern, at: offset + 8, into: &bytes)
    }

    private func putUInt32(_ value: UInt32, at offset: Int, into bytes: inout [UInt8]) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}

private final class LoadRecorder: @unchecked Sendable {
    struct Request {
        let paths: SourceStudioModelAssetPaths
        let requirement: SourceStudioModelAssetRequirement
    }

    private let lock = NSLock()
    private let outcome: SourceStudioModelAssetLoadOutcome
    private var requestsStorage: [Request] = []

    init(outcome: SourceStudioModelAssetLoadOutcome) {
        self.outcome = outcome
    }

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return requestsStorage
    }

    func load(
        paths: SourceStudioModelAssetPaths,
        requirement: SourceStudioModelAssetRequirement
    ) -> SourceStudioModelAssetLoadOutcome {
        lock.lock()
        requestsStorage.append(Request(paths: paths, requirement: requirement))
        lock.unlock()
        return outcome
    }
}

private final class CountingStudioAssetReader:
    SourceStudioBoundedAssetReading,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let files: [String: Data]
    private var readCounts: [String: Int] = [:]

    init(files: [String: Data]) {
        self.files = Dictionary(uniqueKeysWithValues: files.map {
            ($0.key.lowercased(), $0.value)
        })
    }

    func read(
        path: String,
        pathID: String?,
        maximumBytes: Int
    ) -> SourceStudioBoundedAssetReadOutcome {
        let key = path.lowercased()
        lock.lock()
        readCounts[key, default: 0] += 1
        let data = files[key]
        lock.unlock()
        guard let data else { return .missing }
        guard data.count <= maximumBytes else { return .exceeded(actual: data.count) }
        return .data(data)
    }

    func readCount(for path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return readCounts[path.lowercased(), default: 0]
    }
}
