import Foundation
import Testing
@testable import GModEngine

@Suite("Asset-backed Source Studio model loading")
struct SourceStudioModelAssetTests {
    private let checksum: Int32 = 0x1020_3040

    @Test("render payload and opaque PHY companion publish only after all four files validate")
    func loadsCompleteOpaquePHYCompanionTransaction() throws {
        let fixture = syntheticAssetSet()
        let loader = makeLoader(files: fixture)
        let outcome = loader.load(paths: paths(), requirement: .renderWithOpaquePHYCompanion)
        let asset = try #require(outcome.asset)

        #expect(outcome.unavailableReason == nil)
        #expect(asset.validation.requirement == .renderWithOpaquePHYCompanion)
        #expect(asset.validation.checksum == checksum)
        #expect(asset.validation.byteCounts[.mdl] == fixture["models/props/test.mdl"]?.count)
        #expect(asset.validation.vvd.lodVertexCounts == [1])
        #expect(asset.validation.vtx.lodCount == 1)
        #expect(asset.validation.phy?.solidCount == 1)
        #expect(asset.renderPayload.model.header.name == "models/props/test.mdl")
        #expect(asset.renderPayload.vvdData == fixture["models/props/test.vvd"])
        #expect(asset.renderPayload.vtxData == fixture["models/props/test.dx90.vtx"])
        #expect(asset.opaquePHYCompanion?.data == fixture["models/props/test.phy"])
    }

    @Test("render requirement is MDL plus VVD plus caller-selected VTX, without a fake PHY")
    func loadsRenderableWithoutPhysics() throws {
        var fixture = syntheticAssetSet()
        fixture.removeValue(forKey: "models/props/test.phy")
        let loader = makeLoader(files: fixture, budget: renderBudget())
        let outcome = loader.load(
            paths: paths(includePHYPath: false),
            requirement: .render
        )
        let asset = try #require(outcome.asset)

        #expect(asset.validation.byteCounts.keys.sorted(by: { $0.rawValue < $1.rawValue })
            == [.mdl, .vtx, .vvd])
        #expect(asset.validation.phy == nil)
        #expect(asset.opaquePHYCompanion == nil)
    }

    @Test("missing selected VTX is a typed unavailable result and never emits a partial payload")
    func missingVTXFailsClosed() throws {
        var fixture = syntheticAssetSet()
        fixture.removeValue(forKey: "models/props/test.dx90.vtx")
        let loader = makeLoader(files: fixture)
        let outcome = loader.load(paths: paths(), requirement: .renderWithOpaquePHYCompanion)

        #expect(outcome.asset == nil)
        #expect(outcome.unavailableReason == .missing(
            kind: .vtx,
            path: "models/props/test.dx90.vtx"
        ))
    }

    @Test("opaque PHY companion validation requires an explicit PHY path")
    func opaquePHYCompanionRequiresPHYPath() throws {
        let loader = makeLoader(files: syntheticAssetSet())
        let outcome = loader.load(
            paths: paths(includePHYPath: false),
            requirement: .renderWithOpaquePHYCompanion
        )

        #expect(outcome.asset == nil)
        #expect(outcome.unavailableReason == .invalidRequest(
            "PHY path is required for renderWithOpaquePHYCompanion"
        ))
    }

    @Test("companion checksum mismatch is attributed to the exact asset")
    func vtxChecksumMismatch() throws {
        var fixture = syntheticAssetSet()
        fixture["models/props/test.dx90.vtx"] = makeVTX(checksum: 99)
        let loader = makeLoader(files: fixture)
        let outcome = loader.load(paths: paths(), requirement: .renderWithOpaquePHYCompanion)

        #expect(outcome.asset == nil)
        #expect(outcome.unavailableReason == .malformed(
            kind: .vtx,
            error: .checksumMismatch(expected: checksum, actual: 99)
        ))
    }

    @Test("per-file byte budget rejects before format parsing")
    func perFileBudgetFailsClosed() throws {
        var budget = standardBudget()
        var limits = budget.maximumBytesByKind
        limits[.vvd] = 64
        budget = SourceStudioModelAssetBudget(
            maximumBytesByKind: limits,
            maximumTotalBytes: budget.maximumTotalBytes,
            maximumVVDVertices: budget.maximumVVDVertices,
            maximumVVDFixups: budget.maximumVVDFixups,
            maximumVTXBodyParts: budget.maximumVTXBodyParts,
            maximumDeclaredPHYSolids: budget.maximumDeclaredPHYSolids
        )
        let loader = makeLoader(files: syntheticAssetSet(), budget: budget)
        let outcome = loader.load(paths: paths(), requirement: .renderWithOpaquePHYCompanion)

        #expect(outcome.asset == nil)
        #expect(outcome.unavailableReason == .byteBudgetExceeded(
            kind: .vvd,
            actual: 128,
            cap: 64
        ))
    }

    @Test("remaining total budget is passed to the bounded reader before allocation")
    func totalBudgetIsEnforcedByReadCap() throws {
        let budget = SourceStudioModelAssetBudget(
            maximumBytesByKind: [
                .mdl: 512,
                .vvd: 512,
                .vtx: 512,
                .phy: 512
            ],
            maximumTotalBytes: 570,
            maximumVVDVertices: 128,
            maximumVVDFixups: 128,
            maximumVTXBodyParts: 128,
            maximumDeclaredPHYSolids: 128
        )
        let loader = makeLoader(files: syntheticAssetSet(), budget: budget)
        let outcome = loader.load(
            paths: paths(),
            requirement: .renderWithOpaquePHYCompanion
        )

        #expect(outcome.unavailableReason == .totalByteBudgetExceeded(
            actual: 580,
            cap: 570
        ))
    }

    @Test("bounded reader failure remains a typed file-specific failure")
    func boundedReaderFailureIsTyped() {
        let loader = SourceStudioModelAssetLoader(
            reader: FailingStudioAssetReader(reason: "provider unavailable"),
            budget: renderBudget()
        )
        let outcome = loader.load(
            paths: paths(includePHYPath: false),
            requirement: .render
        )

        #expect(outcome.unavailableReason == .readFailed(
            kind: .mdl,
            path: "models/props/test.mdl",
            reason: "provider unavailable"
        ))
    }

    @Test("VVD vertex count respects the caller cap and SDK maximum")
    func vvdVertexCap() throws {
        var fixture = syntheticAssetSet()
        fixture["models/props/test.vvd"] = makeVVD(checksum: checksum, vertexCount: 2)
        let budget = SourceStudioModelAssetBudget(
            maximumBytesByKind: standardBudget().maximumBytesByKind,
            maximumTotalBytes: 8_192,
            maximumVVDVertices: 1,
            maximumVVDFixups: 16,
            maximumVTXBodyParts: 16,
            maximumDeclaredPHYSolids: 16
        )
        let loader = makeLoader(files: fixture, budget: budget)
        let outcome = loader.load(paths: paths(), requirement: .renderWithOpaquePHYCompanion)

        #expect(outcome.unavailableReason == .malformed(
            kind: .vvd,
            error: .exceedsCap(
                field: "vertexFileHeader_t.numLODVertexes[0]",
                value: 2,
                cap: 1
            )
        ))
    }

    @Test("VVD and VTX must advertise the same LOD count")
    func companionLODCountsMustMatch() throws {
        var fixture = syntheticAssetSet()
        fixture["models/props/test.dx90.vtx"] = makeVTX(checksum: checksum, lodCount: 2)
        let loader = makeLoader(files: fixture)
        let outcome = loader.load(paths: paths(), requirement: .renderWithOpaquePHYCompanion)

        #expect(outcome.unavailableReason == .malformed(
            kind: .vtx,
            error: .inconsistentLODCount(vvd: 1, vtx: 2)
        ))
    }

    @Test("PHY header without opaque body bytes never becomes an available companion")
    func emptyPHYBodyFailsClosed() throws {
        var fixture = syntheticAssetSet()
        fixture["models/props/test.phy"] = makePHY(checksum: checksum, includeBody: false)
        let loader = makeLoader(files: fixture)
        let outcome = loader.load(paths: paths(), requirement: .renderWithOpaquePHYCompanion)

        #expect(outcome.unavailableReason == .malformed(
            kind: .phy,
            error: .emptyPHYBody
        ))
    }

    @Test("unsafe or mistyped logical paths are invalid requests")
    func validatesLogicalPathsAndExtensions() throws {
        let loader = makeLoader(files: syntheticAssetSet())
        let unsafe = loader.load(
            paths: SourceStudioModelAssetPaths(
                mdl: "../test.mdl",
                vvd: "models/props/test.vvd",
                vtx: "models/props/test.dx90.vtx"
            ),
            requirement: .render
        )
        #expect(unsafe.asset == nil)
        guard case .invalidRequest? = unsafe.unavailableReason else {
            Issue.record("expected typed invalid request, got \(String(describing: unsafe.unavailableReason))")
            return
        }

        let mistyped = loader.load(
            paths: SourceStudioModelAssetPaths(
                mdl: "models/props/test.vvd",
                vvd: "models/props/test.vvd",
                vtx: "models/props/test.dx90.vtx"
            ),
            requirement: .render
        )
        #expect(mistyped.unavailableReason == .invalidRequest(
            "MDL path has the wrong extension: models/props/test.vvd"
        ))
    }
}

private extension SourceStudioModelAssetTests {
    func paths(includePHYPath: Bool = true) -> SourceStudioModelAssetPaths {
        SourceStudioModelAssetPaths(
            mdl: "models/props/test.mdl",
            vvd: "models/props/test.vvd",
            vtx: "models/props/test.dx90.vtx",
            phy: includePHYPath ? "models/props/test.phy" : nil
        )
    }

    func standardBudget() -> SourceStudioModelAssetBudget {
        SourceStudioModelAssetBudget(
            maximumBytesByKind: [
                .mdl: 4_096,
                .vvd: 4_096,
                .vtx: 4_096,
                .phy: 4_096
            ],
            maximumTotalBytes: 16_384,
            maximumVVDVertices: 128,
            maximumVVDFixups: 128,
            maximumVTXBodyParts: 128,
            maximumDeclaredPHYSolids: 128
        )
    }

    func renderBudget() -> SourceStudioModelAssetBudget {
        SourceStudioModelAssetBudget(
            maximumBytesByKind: [
                .mdl: 4_096,
                .vvd: 4_096,
                .vtx: 4_096
            ],
            maximumTotalBytes: 12_288,
            maximumVVDVertices: 128,
            maximumVVDFixups: 128,
            maximumVTXBodyParts: 128
        )
    }

    func makeLoader(
        files: [String: Data],
        budget: SourceStudioModelAssetBudget? = nil
    ) -> SourceStudioModelAssetLoader {
        return SourceStudioModelAssetLoader(
            reader: BoundedMemoryStudioAssetReader(files: files),
            budget: budget ?? standardBudget()
        )
    }

    func syntheticAssetSet() -> [String: Data] {
        [
            "models/props/test.mdl": makeMDL(checksum: checksum),
            "models/props/test.vvd": makeVVD(checksum: checksum),
            "models/props/test.dx90.vtx": makeVTX(checksum: checksum),
            "models/props/test.phy": makePHY(checksum: checksum)
        ]
    }

    func makeMDL(checksum: Int32) -> Data {
        var bytes = [UInt8](repeating: 0, count: 408)
        putUInt32(SourceStudioModel.magic, at: 0, into: &bytes)
        putInt32(48, at: 4, into: &bytes)
        putInt32(checksum, at: 8, into: &bytes)
        putCString("models/props/test.mdl", at: 12, capacity: 64, into: &bytes)
        putInt32(Int32(bytes.count), at: 76, into: &bytes)
        return Data(bytes)
    }

    func makeVVD(checksum: Int32, vertexCount: Int32 = 1) -> Data {
        let headerSize = 64
        let vertexBytes = Int(vertexCount) * 48
        let tangentStart = headerSize + vertexBytes
        var bytes = [UInt8](repeating: 0, count: tangentStart + Int(vertexCount) * 16)
        putUInt32(0x5653_4449, at: 0, into: &bytes)
        putInt32(4, at: 4, into: &bytes)
        putInt32(checksum, at: 8, into: &bytes)
        putInt32(1, at: 12, into: &bytes)
        putInt32(vertexCount, at: 16, into: &bytes)
        putInt32(0, at: 48, into: &bytes)
        putInt32(0, at: 52, into: &bytes)
        putInt32(Int32(headerSize), at: 56, into: &bytes)
        putInt32(Int32(tangentStart), at: 60, into: &bytes)
        return Data(bytes)
    }

    func makeVTX(checksum: Int32, lodCount: Int32 = 1) -> Data {
        let materialListsStart = 36
        var bytes = [UInt8](
            repeating: 0,
            count: materialListsStart + Int(lodCount) * 8
        )
        putInt32(7, at: 0, into: &bytes)
        putInt32(32, at: 4, into: &bytes)
        putUInt16(3, at: 8, into: &bytes)
        putUInt16(3, at: 10, into: &bytes)
        putInt32(3, at: 12, into: &bytes)
        putInt32(checksum, at: 16, into: &bytes)
        putInt32(lodCount, at: 20, into: &bytes)
        putInt32(Int32(materialListsStart), at: 24, into: &bytes)
        putInt32(0, at: 28, into: &bytes)
        putInt32(0, at: 32, into: &bytes)
        return Data(bytes)
    }

    func makePHY(checksum: Int32, includeBody: Bool = true) -> Data {
        var bytes = [UInt8](repeating: 0, count: includeBody ? 17 : 16)
        putInt32(16, at: 0, into: &bytes)
        putInt32(0, at: 4, into: &bytes)
        putInt32(1, at: 8, into: &bytes)
        putInt32(checksum, at: 12, into: &bytes)
        if includeBody { bytes[16] = 1 }
        return Data(bytes)
    }

    func putCString(_ value: String, at offset: Int, capacity: Int, into bytes: inout [UInt8]) {
        let encoded = Array(value.utf8.prefix(capacity - 1))
        bytes.replaceSubrange(offset..<(offset + encoded.count), with: encoded)
        bytes[offset + encoded.count] = 0
    }

    func putUInt16(_ value: UInt16, at offset: Int, into bytes: inout [UInt8]) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    func putInt32(_ value: Int32, at offset: Int, into bytes: inout [UInt8]) {
        putUInt32(UInt32(bitPattern: value), at: offset, into: &bytes)
    }

    func putUInt32(_ value: UInt32, at offset: Int, into bytes: inout [UInt8]) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}

private struct BoundedMemoryStudioAssetReader: SourceStudioBoundedAssetReading {
    let files: [String: Data]

    func read(
        path: String,
        pathID: String?,
        maximumBytes: Int
    ) -> SourceStudioBoundedAssetReadOutcome {
        guard let data = files[path.lowercased()] else { return .missing }
        guard data.count <= maximumBytes else { return .exceeded(actual: data.count) }
        return .data(data)
    }
}

private struct FailingStudioAssetReader: SourceStudioBoundedAssetReading {
    let reason: String

    func read(
        path: String,
        pathID: String?,
        maximumBytes: Int
    ) -> SourceStudioBoundedAssetReadOutcome {
        .failed(reason)
    }
}
