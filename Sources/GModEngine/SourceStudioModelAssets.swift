import Foundation

// Source format references (definitions only; this is an independent parser):
// - Source SDK 2013 at c8f4c6351162fbff83bfa5a428d45d1e6eed3824
//   `src/public/studio.h`: vertexFileHeader_t, vertexFileFixup_t,
//   MODEL_VERTEX_FILE_VERSION, MAX_NUM_LODS and MAXSTUDIOVERTS.
// - The same revision's `src/public/optimize.h`:
//   OptimizedModel::FileHeader_t and OPTIMIZED_MODEL_FILE_VERSION.
// - The same revision's `src/public/phyfile.h`: phyheader_t.
//
// Loading is deliberately all-or-nothing. No canonical Entity, renderer, or
// cache sees a model until every file required by the requested usage has been
// read, budgeted, structurally validated, and checksum-matched.

public enum SourceStudioModelAssetKind: String, CaseIterable, Sendable, Equatable, Hashable {
    case mdl
    case vvd
    case vtx
    case phy
}

public enum SourceStudioModelAssetRequirement: Sendable, Equatable {
    /// Geometry rendering needs the MDL metadata, VVD vertices, and one
    /// explicitly selected VTX optimized-mesh file.
    case render

    /// Adds a PHY whose header/checksum and opaque-body presence are verified.
    /// This is input for a later collision decoder, not a validated
    /// `prop_physics`, collision shape, or PhysObj.
    case renderWithOpaquePHYCompanion

    fileprivate var requiredKinds: [SourceStudioModelAssetKind] {
        switch self {
        case .render:
            return [.mdl, .vvd, .vtx]
        case .renderWithOpaquePHYCompanion:
            return [.mdl, .vvd, .vtx, .phy]
        }
    }
}

/// Exact logical paths chosen by the caller. In particular, the loader does
/// not guess whether `.dx80.vtx`, `.dx90.vtx`, or another optimized file is the
/// correct target for the active renderer.
public struct SourceStudioModelAssetPaths: Sendable, Equatable {
    public let mdl: String
    public let vvd: String
    public let vtx: String
    public let phy: String?

    public init(mdl: String, vvd: String, vtx: String, phy: String? = nil) {
        self.mdl = mdl
        self.vvd = vvd
        self.vtx = vtx
        self.phy = phy
    }

    fileprivate func path(for kind: SourceStudioModelAssetKind) -> String? {
        switch kind {
        case .mdl: return mdl
        case .vvd: return vvd
        case .vtx: return vtx
        case .phy: return phy
        }
    }
}

/// Host/deployment limits are policy, not Source file-format facts. They are
/// therefore mandatory caller input instead of guessed global defaults.
public struct SourceStudioModelAssetBudget: Sendable, Equatable {
    public let maximumBytesByKind: [SourceStudioModelAssetKind: Int]
    public let maximumTotalBytes: Int
    public let maximumVVDVertices: Int
    public let maximumVVDFixups: Int
    public let maximumVTXBodyParts: Int
    public let maximumDeclaredPHYSolids: Int?

    public init(
        maximumBytesByKind: [SourceStudioModelAssetKind: Int],
        maximumTotalBytes: Int,
        maximumVVDVertices: Int,
        maximumVVDFixups: Int,
        maximumVTXBodyParts: Int,
        maximumDeclaredPHYSolids: Int? = nil
    ) {
        self.maximumBytesByKind = maximumBytesByKind
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumVVDVertices = maximumVVDVertices
        self.maximumVVDFixups = maximumVVDFixups
        self.maximumVTXBodyParts = maximumVTXBodyParts
        self.maximumDeclaredPHYSolids = maximumDeclaredPHYSolids
    }

    fileprivate func isUsable(for requirement: SourceStudioModelAssetRequirement) -> Bool {
        guard maximumTotalBytes > 0,
              maximumVVDVertices > 0,
              maximumVVDVertices <= SourceStudioModelAssetFormat.maxStudioVertices,
              maximumVVDFixups >= 0,
              maximumVTXBodyParts >= 0,
              requirement.requiredKinds.allSatisfy({
                guard let limit = maximumBytesByKind[$0] else { return false }
                return limit > 0 && limit <= maximumTotalBytes
              }) else {
            return false
        }
        switch requirement {
        case .render:
            return true
        case .renderWithOpaquePHYCompanion:
            guard let maximumDeclaredPHYSolids else { return false }
            return maximumDeclaredPHYSolids > 0
        }
    }
}

public struct SourceStudioVVDHeader: Sendable, Equatable {
    public let checksum: Int32
    public let lodVertexCounts: [Int]
    public let fixupCount: Int
    public let fixupTableStart: Int
    public let vertexDataStart: Int
    public let tangentDataStart: Int?
}

public struct SourceStudioVTXHeader: Sendable, Equatable {
    public let checksum: Int32
    public let lodCount: Int
    public let bodyPartCount: Int
    public let maximumBonesPerStrip: Int
    public let maximumBonesPerTriangle: Int
    public let maximumBonesPerVertex: Int
}

public struct SourceStudioPHYHeader: Sendable, Equatable {
    public let identifier: Int32
    public let checksum: Int32
    public let solidCount: Int
}

public struct SourceStudioModelAssetValidation: Sendable, Equatable {
    public let paths: SourceStudioModelAssetPaths
    public let requirement: SourceStudioModelAssetRequirement
    public let checksum: Int32
    public let byteCounts: [SourceStudioModelAssetKind: Int]
    public let totalByteCount: Int
    public let vvd: SourceStudioVVDHeader
    public let vtx: SourceStudioVTXHeader
    public let phy: SourceStudioPHYHeader?
}

/// Renderer-neutral immutable handoff. Raw companion bytes are retained so a
/// later Studio mesh decoder can resolve relative offsets without reopening a
/// mutable filesystem view. Material-table decoding is intentionally not
/// claimed by this boundary.
public struct SourceStudioImmutableRenderPayload: Sendable {
    public let model: SourceStudioModel
    public let mdlData: Data
    public let vvdData: Data
    public let vtxData: Data
    public let vvdHeader: SourceStudioVVDHeader
    public let vtxHeader: SourceStudioVTXHeader

    fileprivate init(
        model: SourceStudioModel,
        mdlData: Data,
        vvdData: Data,
        vtxData: Data,
        vvdHeader: SourceStudioVVDHeader,
        vtxHeader: SourceStudioVTXHeader
    ) {
        self.model = model
        self.mdlData = mdlData
        self.vvdData = vvdData
        self.vtxData = vtxData
        self.vvdHeader = vvdHeader
        self.vtxHeader = vtxHeader
    }
}

/// Header-matched PHY bytes for a later collision-format decoder. Presence in
/// this value is not evidence that collision geometry or a PhysObj is valid.
public struct SourceStudioOpaquePHYCompanion: Sendable {
    public let data: Data
    public let header: SourceStudioPHYHeader

    fileprivate init(data: Data, header: SourceStudioPHYHeader) {
        self.data = data
        self.header = header
    }
}

public struct SourceStudioModelAsset: Sendable {
    public let validation: SourceStudioModelAssetValidation
    public let renderPayload: SourceStudioImmutableRenderPayload
    public let opaquePHYCompanion: SourceStudioOpaquePHYCompanion?
}

public enum SourceStudioBoundedAssetReadOutcome: Sendable, Equatable {
    case data(Data)
    case missing
    case exceeded(actual: Int)
    case failed(String)
}

/// Implementations must enforce `maximumBytes` before constructing an
/// unbounded in-memory Data value. A provider that cannot make that guarantee
/// must not conform; the Source filesystem adapter belongs in a later
/// integration commit once it has a bounded/streaming backend.
public protocol SourceStudioBoundedAssetReading: Sendable {
    func read(
        path: String,
        pathID: String?,
        maximumBytes: Int
    ) -> SourceStudioBoundedAssetReadOutcome
}

public enum SourceStudioModelAssetFormatError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    case studio(SourceStudioError)
    case truncatedHeader(required: Int, actual: Int)
    case invalidMagic(expected: UInt32, actual: UInt32)
    case unsupportedVersion(expected: Int32, actual: Int32)
    case checksumMismatch(expected: Int32, actual: Int32)
    case invalidCount(field: String, value: Int32)
    case exceedsCap(field: String, value: Int, cap: Int)
    case invalidOffset(field: String, value: Int32)
    case outOfBounds(field: String, start: Int, byteCount: Int, length: Int)
    case inconsistentLODCount(vvd: Int, vtx: Int)
    case increasingLODVertexCount(previous: Int, next: Int, lod: Int)
    case invalidVVDVertexRange(fixup: Int, start: Int, count: Int, vertices: Int)
    case invalidPHYHeaderSize(expected: Int32, actual: Int32)
    case emptyPHYBody

    public var description: String {
        switch self {
        case let .studio(error):
            return error.description
        case let .truncatedHeader(required, actual):
            return "header requires \(required) bytes, got \(actual)"
        case let .invalidMagic(expected, actual):
            return String(format: "invalid magic 0x%08X; expected 0x%08X", actual, expected)
        case let .unsupportedVersion(expected, actual):
            return "unsupported version \(actual); expected \(expected)"
        case let .checksumMismatch(expected, actual):
            return "companion checksum \(actual) does not match MDL checksum \(expected)"
        case let .invalidCount(field, value):
            return "invalid \(field) count \(value)"
        case let .exceedsCap(field, value, cap):
            return "\(field) \(value) exceeds cap \(cap)"
        case let .invalidOffset(field, value):
            return "invalid \(field) offset \(value)"
        case let .outOfBounds(field, start, byteCount, length):
            return "\(field) range \(start)..<\(start + byteCount) exceeds \(length) bytes"
        case let .inconsistentLODCount(vvd, vtx):
            return "VVD LOD count \(vvd) does not match VTX LOD count \(vtx)"
        case let .increasingLODVertexCount(previous, next, lod):
            return "VVD LOD \(lod) vertex count \(next) exceeds prior LOD count \(previous)"
        case let .invalidVVDVertexRange(fixup, start, count, vertices):
            return "VVD fixup \(fixup) range \(start)..<\(start + count) exceeds \(vertices) vertices"
        case let .invalidPHYHeaderSize(expected, actual):
            return "PHY header size \(actual) does not match \(expected)"
        case .emptyPHYBody:
            return "PHY declares solids but contains no collision body bytes"
        }
    }
}

public enum SourceStudioModelAssetUnavailable: Error, Sendable, Equatable,
    CustomStringConvertible
{
    case invalidRequest(String)
    case missing(kind: SourceStudioModelAssetKind, path: String)
    case readFailed(kind: SourceStudioModelAssetKind, path: String, reason: String)
    case byteBudgetExceeded(kind: SourceStudioModelAssetKind, actual: Int, cap: Int)
    case totalByteBudgetExceeded(actual: Int, cap: Int)
    case malformed(kind: SourceStudioModelAssetKind, error: SourceStudioModelAssetFormatError)

    public var description: String {
        switch self {
        case let .invalidRequest(reason):
            return "invalid Studio asset request: \(reason)"
        case let .missing(kind, path):
            return "missing \(kind.rawValue.uppercased()) asset: \(path)"
        case let .readFailed(kind, path, reason):
            return "failed to read \(kind.rawValue.uppercased()) asset \(path): \(reason)"
        case let .byteBudgetExceeded(kind, actual, cap):
            return "\(kind.rawValue.uppercased()) asset is \(actual) bytes; cap is \(cap)"
        case let .totalByteBudgetExceeded(actual, cap):
            return "Studio asset set is \(actual) bytes; cap is \(cap)"
        case let .malformed(kind, error):
            return "malformed \(kind.rawValue.uppercased()) asset: \(error)"
        }
    }
}

public enum SourceStudioModelAssetLoadOutcome: Sendable {
    case loaded(SourceStudioModelAsset)
    case unavailable(SourceStudioModelAssetUnavailable)

    public var asset: SourceStudioModelAsset? {
        guard case let .loaded(asset) = self else { return nil }
        return asset
    }

    public var unavailableReason: SourceStudioModelAssetUnavailable? {
        guard case let .unavailable(reason) = self else { return nil }
        return reason
    }
}

public final class SourceStudioModelAssetLoader: @unchecked Sendable {
    private let reader: any SourceStudioBoundedAssetReading
    private let budget: SourceStudioModelAssetBudget

    public init(
        reader: any SourceStudioBoundedAssetReading,
        budget: SourceStudioModelAssetBudget
    ) {
        self.reader = reader
        self.budget = budget
    }

    public func load(
        paths: SourceStudioModelAssetPaths,
        requirement: SourceStudioModelAssetRequirement,
        pathID: String? = "GAME"
    ) -> SourceStudioModelAssetLoadOutcome {
        do {
            let normalized = try normalizedPaths(paths, requirement: requirement)
            guard budget.isUsable(for: requirement) else {
                throw SourceStudioModelAssetUnavailable.invalidRequest(
                    "budget must provide positive per-file and total byte limits plus valid caps"
                )
            }

            var files: [SourceStudioModelAssetKind: Data] = [:]
            var totalBytes = 0
            for kind in requirement.requiredKinds {
                guard let path = normalized.path(for: kind) else {
                    throw SourceStudioModelAssetUnavailable.invalidRequest(
                        "\(kind.rawValue.uppercased()) path is required for \(requirement)"
                    )
                }
                let kindCap = budget.maximumBytesByKind[kind]!
                let remainingTotal = budget.maximumTotalBytes - totalBytes
                let readCap = min(kindCap, remainingTotal)
                let data: Data
                switch reader.read(path: path, pathID: pathID, maximumBytes: readCap) {
                case let .data(value):
                    data = value
                case .missing:
                    throw SourceStudioModelAssetUnavailable.missing(kind: kind, path: path)
                case let .exceeded(actual):
                    if readCap < kindCap {
                        let (attemptedTotal, overflow) = totalBytes.addingReportingOverflow(actual)
                        throw SourceStudioModelAssetUnavailable.totalByteBudgetExceeded(
                            actual: overflow ? Int.max : attemptedTotal,
                            cap: budget.maximumTotalBytes
                        )
                    }
                    throw SourceStudioModelAssetUnavailable.byteBudgetExceeded(
                        kind: kind,
                        actual: actual,
                        cap: kindCap
                    )
                case let .failed(reason):
                    throw SourceStudioModelAssetUnavailable.readFailed(
                        kind: kind,
                        path: path,
                        reason: reason
                    )
                }
                // Defend against a faulty provider without relying on it for
                // correctness. Conforming readers must avoid this allocation.
                guard data.count <= readCap else {
                    if readCap < kindCap {
                        let (attemptedTotal, overflow) = totalBytes.addingReportingOverflow(data.count)
                        throw SourceStudioModelAssetUnavailable.totalByteBudgetExceeded(
                            actual: overflow ? Int.max : attemptedTotal,
                            cap: budget.maximumTotalBytes
                        )
                    }
                    throw SourceStudioModelAssetUnavailable.byteBudgetExceeded(
                        kind: kind,
                        actual: data.count,
                        cap: kindCap
                    )
                }
                let (nextTotal, overflow) = totalBytes.addingReportingOverflow(data.count)
                guard !overflow, nextTotal <= budget.maximumTotalBytes else {
                    throw SourceStudioModelAssetUnavailable.totalByteBudgetExceeded(
                        actual: overflow ? Int.max : nextTotal,
                        cap: budget.maximumTotalBytes
                    )
                }
                files[kind] = data
                totalBytes = nextTotal
            }

            guard let mdlData = files[.mdl],
                  let vvdData = files[.vvd],
                  let vtxData = files[.vtx] else {
                throw SourceStudioModelAssetUnavailable.invalidRequest(
                    "internal required-file set is incomplete"
                )
            }

            let model: SourceStudioModel
            do {
                model = try SourceStudioModel(data: mdlData)
            } catch let error as SourceStudioError {
                throw SourceStudioModelAssetUnavailable.malformed(
                    kind: .mdl,
                    error: .studio(error)
                )
            }
            let checksum = model.header.checksum
            let vvd = try mapFormatError(kind: .vvd) {
                try SourceStudioModelAssetFormat.parseVVD(
                    vvdData,
                    expectedChecksum: checksum,
                    budget: budget
                )
            }
            let vtx = try mapFormatError(kind: .vtx) {
                try SourceStudioModelAssetFormat.parseVTX(
                    vtxData,
                    expectedChecksum: checksum,
                    vvdLODCount: vvd.lodVertexCounts.count,
                    budget: budget
                )
            }

            var phyHeader: SourceStudioPHYHeader?
            var opaquePHYCompanion: SourceStudioOpaquePHYCompanion?
            if let phyData = files[.phy] {
                let header = try mapFormatError(kind: .phy) {
                    try SourceStudioModelAssetFormat.parsePHY(
                        phyData,
                        expectedChecksum: checksum,
                        budget: budget
                    )
                }
                phyHeader = header
                opaquePHYCompanion = SourceStudioOpaquePHYCompanion(data: phyData, header: header)
            }

            // Commit point: only fully validated local values are published.
            let byteCounts = files.mapValues(\.count)
            let validation = SourceStudioModelAssetValidation(
                paths: normalized,
                requirement: requirement,
                checksum: checksum,
                byteCounts: byteCounts,
                totalByteCount: totalBytes,
                vvd: vvd,
                vtx: vtx,
                phy: phyHeader
            )
            let render = SourceStudioImmutableRenderPayload(
                model: model,
                mdlData: mdlData,
                vvdData: vvdData,
                vtxData: vtxData,
                vvdHeader: vvd,
                vtxHeader: vtx
            )
            return .loaded(SourceStudioModelAsset(
                validation: validation,
                renderPayload: render,
                opaquePHYCompanion: opaquePHYCompanion
            ))
        } catch let unavailable as SourceStudioModelAssetUnavailable {
            return .unavailable(unavailable)
        } catch {
            return .unavailable(.invalidRequest(String(describing: error)))
        }
    }

    private func normalizedPaths(
        _ paths: SourceStudioModelAssetPaths,
        requirement: SourceStudioModelAssetRequirement
    ) throws -> SourceStudioModelAssetPaths {
        let normalizedMDL = try normalize(paths.mdl, kind: .mdl)
        let normalizedVVD = try normalize(paths.vvd, kind: .vvd)
        let normalizedVTX = try normalize(paths.vtx, kind: .vtx)
        let normalizedPHY: String?
        if let path = paths.phy {
            normalizedPHY = try normalize(path, kind: .phy)
        } else {
            normalizedPHY = nil
        }
        if requirement == .renderWithOpaquePHYCompanion, normalizedPHY == nil {
            throw SourceStudioModelAssetUnavailable.invalidRequest(
                "PHY path is required for renderWithOpaquePHYCompanion"
            )
        }
        return SourceStudioModelAssetPaths(
            mdl: normalizedMDL,
            vvd: normalizedVVD,
            vtx: normalizedVTX,
            phy: normalizedPHY
        )
    }

    private func normalize(
        _ rawPath: String,
        kind: SourceStudioModelAssetKind
    ) throws -> String {
        let normalized: String
        do {
            normalized = try SourceLogicalPath.normalize(rawPath, allowEmpty: false)
        } catch {
            throw SourceStudioModelAssetUnavailable.invalidRequest(String(describing: error))
        }
        guard normalized.lowercased().hasSuffix(".\(kind.rawValue)") else {
            throw SourceStudioModelAssetUnavailable.invalidRequest(
                "\(kind.rawValue.uppercased()) path has the wrong extension: \(normalized)"
            )
        }
        return normalized
    }

    private func mapFormatError<T>(
        kind: SourceStudioModelAssetKind,
        _ body: () throws -> T
    ) throws -> T {
        do {
            return try body()
        } catch let error as SourceStudioModelAssetFormatError {
            throw SourceStudioModelAssetUnavailable.malformed(kind: kind, error: error)
        }
    }
}

private enum SourceStudioModelAssetFormat {
    static let maxLODCount = 8
    static let maxStudioVertices = 65_536
    static let maximumBonesPerVertex = 3
    static let maximumBonesPerTriangle = 9
    static let maximumBonesPerStrip = 512
    static let vvdMagic: UInt32 = 0x5653_4449 // little-endian bytes "IDSV"
    static let vvdVersion: Int32 = 4
    static let vtxVersion: Int32 = 7
    static let vvdHeaderSize = 64
    static let vtxHeaderSize = 36
    static let phyHeaderSize: Int32 = 16
    static let studioVertexSize = 48
    static let tangentSize = 16
    static let fixupSize = 12
    static let vtxMaterialReplacementListSize = 8
    static let vtxBodyPartSize = 8

    static func parseVVD(
        _ data: Data,
        expectedChecksum: Int32,
        budget: SourceStudioModelAssetBudget
    ) throws -> SourceStudioVVDHeader {
        let reader = Reader(data)
        guard data.count >= vvdHeaderSize else {
            throw SourceStudioModelAssetFormatError.truncatedHeader(
                required: vvdHeaderSize,
                actual: data.count
            )
        }
        let magic = try reader.uint32(at: 0, field: "vertexFileHeader_t.id")
        guard magic == vvdMagic else {
            throw SourceStudioModelAssetFormatError.invalidMagic(
                expected: vvdMagic,
                actual: magic
            )
        }
        let version = try reader.int32(at: 4, field: "vertexFileHeader_t.version")
        guard version == vvdVersion else {
            throw SourceStudioModelAssetFormatError.unsupportedVersion(
                expected: vvdVersion,
                actual: version
            )
        }
        let checksum = try reader.int32(at: 8, field: "vertexFileHeader_t.checksum")
        guard checksum == expectedChecksum else {
            throw SourceStudioModelAssetFormatError.checksumMismatch(
                expected: expectedChecksum,
                actual: checksum
            )
        }
        let lodCount = try positiveCount(reader.int32(at: 12, field: "vertexFileHeader_t.numLODs"), field: "vertexFileHeader_t.numLODs")
        guard lodCount <= maxLODCount else {
            throw SourceStudioModelAssetFormatError.exceedsCap(
                field: "vertexFileHeader_t.numLODs",
                value: lodCount,
                cap: maxLODCount
            )
        }
        var counts: [Int] = []
        counts.reserveCapacity(lodCount)
        for lod in 0..<lodCount {
            let raw = try reader.int32(
                at: 16 + lod * 4,
                field: "vertexFileHeader_t.numLODVertexes[\(lod)]"
            )
            guard raw >= 0 else {
                throw SourceStudioModelAssetFormatError.invalidCount(
                    field: "vertexFileHeader_t.numLODVertexes[\(lod)]",
                    value: raw
                )
            }
            let value = Int(raw)
            guard value <= budget.maximumVVDVertices else {
                throw SourceStudioModelAssetFormatError.exceedsCap(
                    field: "vertexFileHeader_t.numLODVertexes[\(lod)]",
                    value: value,
                    cap: budget.maximumVVDVertices
                )
            }
            if let previous = counts.last, value > previous {
                throw SourceStudioModelAssetFormatError.increasingLODVertexCount(
                    previous: previous,
                    next: value,
                    lod: lod
                )
            }
            counts.append(value)
        }

        let fixupCount = try nonnegativeCount(
            reader.int32(at: 48, field: "vertexFileHeader_t.numFixups"),
            field: "vertexFileHeader_t.numFixups"
        )
        guard fixupCount <= budget.maximumVVDFixups else {
            throw SourceStudioModelAssetFormatError.exceedsCap(
                field: "vertexFileHeader_t.numFixups",
                value: fixupCount,
                cap: budget.maximumVVDFixups
            )
        }
        let fixupStart = try reader.int32(at: 52, field: "vertexFileHeader_t.fixupTableStart")
        let vertexStart = try reader.int32(at: 56, field: "vertexFileHeader_t.vertexDataStart")
        let tangentStart = try reader.int32(at: 60, field: "vertexFileHeader_t.tangentDataStart")
        let vertexCount = counts[0]
        let vertexBytes = try multiplied(
            vertexCount,
            studioVertexSize,
            field: "VVD vertex data"
        )
        try reader.validateRange(
            start: vertexStart,
            byteCount: vertexBytes,
            field: "vertexFileHeader_t.vertexDataStart",
            zeroAllowed: vertexCount == 0
        )
        if tangentStart != 0 {
            let tangentBytes = try multiplied(
                vertexCount,
                tangentSize,
                field: "VVD tangent data"
            )
            try reader.validateRange(
                start: tangentStart,
                byteCount: tangentBytes,
                field: "vertexFileHeader_t.tangentDataStart",
                zeroAllowed: false
            )
        }

        if fixupCount > 0 {
            let bytes = try multiplied(fixupCount, fixupSize, field: "VVD fixup table")
            try reader.validateRange(
                start: fixupStart,
                byteCount: bytes,
                field: "vertexFileHeader_t.fixupTableStart",
                zeroAllowed: false
            )
            let start = Int(fixupStart)
            for index in 0..<fixupCount {
                let offset = start + index * fixupSize
                let lod = try reader.int32(at: offset, field: "vertexFileFixup_t[\(index)].lod")
                guard lod >= 0, lod < Int32(lodCount) else {
                    throw SourceStudioModelAssetFormatError.invalidCount(
                        field: "vertexFileFixup_t[\(index)].lod",
                        value: lod
                    )
                }
                let source = try reader.int32(
                    at: offset + 4,
                    field: "vertexFileFixup_t[\(index)].sourceVertexID"
                )
                let count = try reader.int32(
                    at: offset + 8,
                    field: "vertexFileFixup_t[\(index)].numVertexes"
                )
                guard source >= 0, count >= 0,
                      Int64(source) + Int64(count) <= Int64(vertexCount) else {
                    throw SourceStudioModelAssetFormatError.invalidVVDVertexRange(
                        fixup: index,
                        start: Int(source),
                        count: Int(count),
                        vertices: vertexCount
                    )
                }
            }
        }

        return SourceStudioVVDHeader(
            checksum: checksum,
            lodVertexCounts: counts,
            fixupCount: fixupCount,
            fixupTableStart: Int(fixupStart),
            vertexDataStart: Int(vertexStart),
            tangentDataStart: tangentStart == 0 ? nil : Int(tangentStart)
        )
    }

    static func parseVTX(
        _ data: Data,
        expectedChecksum: Int32,
        vvdLODCount: Int,
        budget: SourceStudioModelAssetBudget
    ) throws -> SourceStudioVTXHeader {
        let reader = Reader(data)
        guard data.count >= vtxHeaderSize else {
            throw SourceStudioModelAssetFormatError.truncatedHeader(
                required: vtxHeaderSize,
                actual: data.count
            )
        }
        let version = try reader.int32(at: 0, field: "OptimizedModel::FileHeader_t.version")
        guard version == vtxVersion else {
            throw SourceStudioModelAssetFormatError.unsupportedVersion(
                expected: vtxVersion,
                actual: version
            )
        }
        let maxStrip = Int(try reader.uint16(at: 8, field: "FileHeader_t.maxBonesPerStrip"))
        let maxTriangle = Int(try reader.uint16(at: 10, field: "FileHeader_t.maxBonesPerTri"))
        let maxVertex = try reader.int32(at: 12, field: "FileHeader_t.maxBonesPerVert")
        guard maxStrip <= maximumBonesPerStrip else {
            throw SourceStudioModelAssetFormatError.exceedsCap(
                field: "FileHeader_t.maxBonesPerStrip",
                value: maxStrip,
                cap: maximumBonesPerStrip
            )
        }
        guard maxTriangle <= maximumBonesPerTriangle else {
            throw SourceStudioModelAssetFormatError.exceedsCap(
                field: "FileHeader_t.maxBonesPerTri",
                value: maxTriangle,
                cap: maximumBonesPerTriangle
            )
        }
        guard maxVertex >= 0, maxVertex <= Int32(maximumBonesPerVertex) else {
            throw SourceStudioModelAssetFormatError.exceedsCap(
                field: "FileHeader_t.maxBonesPerVert",
                value: Int(maxVertex),
                cap: maximumBonesPerVertex
            )
        }
        let checksum = try reader.int32(at: 16, field: "FileHeader_t.checkSum")
        guard checksum == expectedChecksum else {
            throw SourceStudioModelAssetFormatError.checksumMismatch(
                expected: expectedChecksum,
                actual: checksum
            )
        }
        let lodCount = try positiveCount(
            reader.int32(at: 20, field: "FileHeader_t.numLODs"),
            field: "FileHeader_t.numLODs"
        )
        guard lodCount <= maxLODCount else {
            throw SourceStudioModelAssetFormatError.exceedsCap(
                field: "FileHeader_t.numLODs",
                value: lodCount,
                cap: maxLODCount
            )
        }
        guard lodCount == vvdLODCount else {
            throw SourceStudioModelAssetFormatError.inconsistentLODCount(
                vvd: vvdLODCount,
                vtx: lodCount
            )
        }
        let materialStart = try reader.int32(
            at: 24,
            field: "FileHeader_t.materialReplacementListOffset"
        )
        try reader.validateRange(
            start: materialStart,
            byteCount: try multiplied(
                lodCount,
                vtxMaterialReplacementListSize,
                field: "VTX material replacement lists"
            ),
            field: "FileHeader_t.materialReplacementListOffset",
            zeroAllowed: false
        )
        let bodyPartCount = try nonnegativeCount(
            reader.int32(at: 28, field: "FileHeader_t.numBodyParts"),
            field: "FileHeader_t.numBodyParts"
        )
        guard bodyPartCount <= budget.maximumVTXBodyParts else {
            throw SourceStudioModelAssetFormatError.exceedsCap(
                field: "FileHeader_t.numBodyParts",
                value: bodyPartCount,
                cap: budget.maximumVTXBodyParts
            )
        }
        let bodyPartStart = try reader.int32(at: 32, field: "FileHeader_t.bodyPartOffset")
        if bodyPartCount > 0 {
            try reader.validateRange(
                start: bodyPartStart,
                byteCount: try multiplied(
                    bodyPartCount,
                    vtxBodyPartSize,
                    field: "VTX body parts"
                ),
                field: "FileHeader_t.bodyPartOffset",
                zeroAllowed: false
            )
        }
        return SourceStudioVTXHeader(
            checksum: checksum,
            lodCount: lodCount,
            bodyPartCount: bodyPartCount,
            maximumBonesPerStrip: maxStrip,
            maximumBonesPerTriangle: maxTriangle,
            maximumBonesPerVertex: Int(maxVertex)
        )
    }

    static func parsePHY(
        _ data: Data,
        expectedChecksum: Int32,
        budget: SourceStudioModelAssetBudget
    ) throws -> SourceStudioPHYHeader {
        let reader = Reader(data)
        guard data.count >= Int(phyHeaderSize) else {
            throw SourceStudioModelAssetFormatError.truncatedHeader(
                required: Int(phyHeaderSize),
                actual: data.count
            )
        }
        let size = try reader.int32(at: 0, field: "phyheader_t.size")
        guard size == phyHeaderSize else {
            throw SourceStudioModelAssetFormatError.invalidPHYHeaderSize(
                expected: phyHeaderSize,
                actual: size
            )
        }
        let identifier = try reader.int32(at: 4, field: "phyheader_t.id")
        let solids = try positiveCount(
            reader.int32(at: 8, field: "phyheader_t.solidCount"),
            field: "phyheader_t.solidCount"
        )
        guard let maximumDeclaredPHYSolids = budget.maximumDeclaredPHYSolids else {
            throw SourceStudioModelAssetFormatError.exceedsCap(
                field: "phyheader_t.solidCount",
                value: solids,
                cap: 0
            )
        }
        guard solids <= maximumDeclaredPHYSolids else {
            throw SourceStudioModelAssetFormatError.exceedsCap(
                field: "phyheader_t.solidCount",
                value: solids,
                cap: maximumDeclaredPHYSolids
            )
        }
        let checksum = try reader.int32(at: 12, field: "phyheader_t.checkSum")
        guard checksum == expectedChecksum else {
            throw SourceStudioModelAssetFormatError.checksumMismatch(
                expected: expectedChecksum,
                actual: checksum
            )
        }
        guard data.count > Int(phyHeaderSize) else {
            throw SourceStudioModelAssetFormatError.emptyPHYBody
        }
        return SourceStudioPHYHeader(
            identifier: identifier,
            checksum: checksum,
            solidCount: solids
        )
    }

    private static func positiveCount(_ value: Int32, field: String) throws -> Int {
        guard value > 0 else {
            throw SourceStudioModelAssetFormatError.invalidCount(field: field, value: value)
        }
        return Int(value)
    }

    private static func nonnegativeCount(_ value: Int32, field: String) throws -> Int {
        guard value >= 0 else {
            throw SourceStudioModelAssetFormatError.invalidCount(field: field, value: value)
        }
        return Int(value)
    }

    private static func multiplied(_ lhs: Int, _ rhs: Int, field: String) throws -> Int {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else {
            throw SourceStudioModelAssetFormatError.exceedsCap(
                field: field,
                value: Int.max,
                cap: Int.max
            )
        }
        return result
    }

    private struct Reader {
        let data: Data

        init(_ data: Data) {
            self.data = data
        }

        func uint16(at offset: Int, field: String) throws -> UInt16 {
            try require(offset: offset, byteCount: 2, field: field)
            return data.withUnsafeBytes { raw in
                UInt16(raw[offset]) | (UInt16(raw[offset + 1]) << 8)
            }
        }

        func uint32(at offset: Int, field: String) throws -> UInt32 {
            try require(offset: offset, byteCount: 4, field: field)
            return data.withUnsafeBytes { raw in
                UInt32(raw[offset])
                    | (UInt32(raw[offset + 1]) << 8)
                    | (UInt32(raw[offset + 2]) << 16)
                    | (UInt32(raw[offset + 3]) << 24)
            }
        }

        func int32(at offset: Int, field: String) throws -> Int32 {
            Int32(bitPattern: try uint32(at: offset, field: field))
        }

        func validateRange(
            start: Int32,
            byteCount: Int,
            field: String,
            zeroAllowed: Bool
        ) throws {
            guard start >= 0, zeroAllowed || start != 0 else {
                throw SourceStudioModelAssetFormatError.invalidOffset(
                    field: field,
                    value: start
                )
            }
            let startInt = Int(start)
            let (end, overflow) = startInt.addingReportingOverflow(byteCount)
            guard !overflow, startInt <= data.count, end <= data.count else {
                throw SourceStudioModelAssetFormatError.outOfBounds(
                    field: field,
                    start: startInt,
                    byteCount: byteCount,
                    length: data.count
                )
            }
        }

        private func require(offset: Int, byteCount: Int, field: String) throws {
            let (end, overflow) = offset.addingReportingOverflow(byteCount)
            guard offset >= 0, !overflow, end <= data.count else {
                throw SourceStudioModelAssetFormatError.outOfBounds(
                    field: field,
                    start: offset,
                    byteCount: byteCount,
                    length: data.count
                )
            }
        }
    }
}
