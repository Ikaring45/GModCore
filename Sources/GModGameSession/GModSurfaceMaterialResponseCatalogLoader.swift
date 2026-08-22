import Foundation
import GModEngine
import GModGameAssets

/// Fail-closed ingestion failures for an independently authenticated Source
/// surface/material-response result.
public enum GModSurfaceMaterialResponseCatalogError:
    Error, Equatable, Sendable, CustomStringConvertible
{
    case attestationTooLarge(actual: Int, maximum: Int)
    case malformedAttestation(String)
    case unsupportedAttestation(schema: Int, kind: String)
    case incompleteAttestation(status: String)
    case reportedIssues([String])
    case invalidProvenance(String)
    case lookupCountOutsideBudget(Int)
    case surfaceInputCountMismatch(expected: Int, actual: Int)
    case unknownSurfaceInputPath(String)
    case duplicateSurfaceInputPath(String)
    case mountedSurfaceInputDigestMismatch(
        path: String,
        expected: String,
        actual: String
    )
    case invalidLookupName(String)
    case lookupNameMismatch(requested: String, reverse: String, data: String)
    case lookupIndexOutsideRange(Int)
    case undeclaredMountedSurface(String)
    case invalidFloat(material: String, field: String, value: String)
    case surfacePhysicsMismatch(
        material: String,
        field: String,
        mounted: Float,
        attested: Float
    )
    case materialTable(SourcePhysicsMaterialTableError)

    public var description: String {
        switch self {
        case let .attestationTooLarge(actual, maximum):
            return "surface material attestation is \(actual) bytes; maximum is \(maximum)"
        case let .malformedAttestation(reason):
            return "surface material attestation is malformed: \(reason)"
        case let .unsupportedAttestation(schema, kind):
            return "unsupported surface material attestation \(kind) schema \(schema)"
        case let .incompleteAttestation(status):
            return "surface material attestation status is \(status), not complete"
        case let .reportedIssues(issues):
            return "complete surface material attestation reports issues: \(issues.joined(separator: ","))"
        case let .invalidProvenance(reason):
            return "surface material attestation provenance is invalid: \(reason)"
        case let .lookupCountOutsideBudget(count):
            return "surface material lookup count is outside budget: \(count)"
        case let .surfaceInputCountMismatch(expected, actual):
            return "surface material input count mismatch: expected \(expected), got \(actual)"
        case let .unknownSurfaceInputPath(path):
            return "surface material attestation names an unmounted input: \(path)"
        case let .duplicateSurfaceInputPath(path):
            return "surface material attestation repeats input: \(path)"
        case let .mountedSurfaceInputDigestMismatch(path, expected, actual):
            return "mounted surface input \(path) SHA-256 mismatch: expected \(expected), got \(actual)"
        case let .invalidLookupName(name):
            return "invalid runtime surface material name: \(name)"
        case let .lookupNameMismatch(requested, reverse, data):
            return "surface lookup name mismatch: requested \(requested), reverse \(reverse), data \(data)"
        case let .lookupIndexOutsideRange(index):
            return "runtime surface material index is outside UInt16 range: \(index)"
        case let .undeclaredMountedSurface(name):
            return "runtime surface \(name) is absent from mounted surfaceproperties"
        case let .invalidFloat(material, field, value):
            return "surface \(material) has invalid \(field) value \(value)"
        case let .surfacePhysicsMismatch(material, field, mounted, attested):
            return "surface \(material) \(field) mismatch: mounted \(mounted), attested \(attested)"
        case let .materialTable(error):
            return "surface runtime name table is invalid: \(error)"
        }
    }
}

/// Converts a host-validated Source oracle result into the production runtime
/// material catalog only after rebinding it to every mounted surfaceproperties
/// input and the currently parsed physics values.
///
/// The external result is the authority for GetSurfaceIndex/GetPropName. The
/// GAME VFS is the authority for the authored files. Neither source can become
/// a catalog on its own.
public enum GModSurfaceMaterialResponseCatalogLoader {
    public static let format = "source-surface-material-response-attestation"

    public struct Budget: Equatable, Sendable {
        public let maximumAttestationBytes: Int
        public let maximumLookups: Int

        public init(
            maximumAttestationBytes: Int = 16 * 1_024 * 1_024,
            maximumLookups: Int = 4_096
        ) {
            precondition(maximumAttestationBytes > 0)
            precondition(maximumLookups > 0)
            self.maximumAttestationBytes = maximumAttestationBytes
            self.maximumLookups = maximumLookups
        }

        public static let iPadValidated = Budget()
    }

    public static func load(
        independentAttestationData data: Data,
        mountedSurfaceProperties: SourceSurfacePropertiesAttestation,
        fileSystem: SourceSearchPathFileSystem,
        budget: Budget = .iPadValidated
    ) throws -> SourcePhysicsRuntimeMaterialCatalog {
        guard data.count <= budget.maximumAttestationBytes else {
            throw GModSurfaceMaterialResponseCatalogError.attestationTooLarge(
                actual: data.count,
                maximum: budget.maximumAttestationBytes
            )
        }

        let result: Attestation
        do {
            result = try JSONDecoder().decode(Attestation.self, from: data)
        } catch {
            throw GModSurfaceMaterialResponseCatalogError
                .malformedAttestation(String(describing: error))
        }
        guard result.schema == 1, result.kind == format else {
            throw GModSurfaceMaterialResponseCatalogError.unsupportedAttestation(
                schema: result.schema,
                kind: result.kind
            )
        }
        guard result.status == "complete" else {
            throw GModSurfaceMaterialResponseCatalogError
                .incompleteAttestation(status: result.status)
        }
        guard result.issues.isEmpty else {
            throw GModSurfaceMaterialResponseCatalogError
                .reportedIssues(result.issues)
        }
        guard !result.surfaceLookups.isEmpty,
              result.surfaceLookups.count <= budget.maximumLookups else {
            throw GModSurfaceMaterialResponseCatalogError
                .lookupCountOutsideBudget(result.surfaceLookups.count)
        }

        try validateProvenance(result.provenance)
        let inputDigests = try validateSurfaceInputs(
            result.provenance.surfaceInputs,
            mountedSurfaceProperties: mountedSurfaceProperties,
            fileSystem: fileSystem
        )

        var entries: [SourcePhysicsRuntimeMaterialCatalogEntry] = []
        entries.reserveCapacity(result.surfaceLookups.count)
        for lookup in result.surfaceLookups {
            guard !lookup.requestedName.isEmpty,
                  lookup.requestedName.utf8.count <= 128,
                  !lookup.requestedName.contains("\0") else {
                throw GModSurfaceMaterialResponseCatalogError
                    .invalidLookupName(lookup.requestedName)
            }
            let requested = fold(lookup.requestedName)
            guard requested == fold(lookup.reverseName),
                  requested == fold(lookup.data.name) else {
                throw GModSurfaceMaterialResponseCatalogError.lookupNameMismatch(
                    requested: lookup.requestedName,
                    reverse: lookup.reverseName,
                    data: lookup.data.name
                )
            }
            guard (0 ... Int(UInt16.max)).contains(lookup.surfaceIndex) else {
                throw GModSurfaceMaterialResponseCatalogError
                    .lookupIndexOutsideRange(lookup.surfaceIndex)
            }
            guard let mounted = mountedSurfaceProperties.material(
                named: lookup.reverseName
            ) else {
                throw GModSurfaceMaterialResponseCatalogError
                    .undeclaredMountedSurface(lookup.reverseName)
            }
            try validatePhysics(
                lookup.data,
                mounted: mounted.resolvedPhysics,
                material: lookup.reverseName
            )
            do {
                entries.append(try SourcePhysicsRuntimeMaterialCatalogEntry(
                    runtimeName: lookup.reverseName,
                    runtimeMaterialIndex: lookup.surfaceIndex,
                    surfacePhysics: mounted.resolvedPhysics
                ))
            } catch let error as SourcePhysicsMaterialTableError {
                throw GModSurfaceMaterialResponseCatalogError
                    .materialTable(error)
            }
        }
        entries.sort {
            if $0.runtimeMaterialIndex != $1.runtimeMaterialIndex {
                return $0.runtimeMaterialIndex < $1.runtimeMaterialIndex
            }
            return fold($0.runtimeName) < fold($1.runtimeName)
        }
        do {
            return try SourcePhysicsRuntimeMaterialCatalog(
                provenance: SourcePhysicsRuntimeMaterialCatalogProvenance(
                    appID: result.provenance.appID,
                    branch: result.provenance.branch,
                    buildID: result.provenance.buildID,
                    requestID: result.provenance.requestID,
                    vphysicsSHA256: result.provenance.vphysics.sha256,
                    surfaceInputSHA256ByLogicalPath: inputDigests
                ),
                entries: entries
            )
        } catch let error as SourcePhysicsMaterialTableError {
            throw GModSurfaceMaterialResponseCatalogError.materialTable(error)
        }
    }
}

private extension GModSurfaceMaterialResponseCatalogLoader {
    struct Attestation: Decodable {
        let schema: Int
        let kind: String
        let status: String
        let provenance: Provenance
        let surfaceLookups: [SurfaceLookup]
        let issues: [String]

        enum CodingKeys: String, CodingKey {
            case schema, kind, status, provenance, issues
            case surfaceLookups = "surface_lookups"
        }
    }

    struct Provenance: Decodable {
        let appID: Int
        let branch: String
        let buildID: String
        let requestID: String
        let vphysics: SurfaceInput
        let surfaceInputs: [SurfaceInput]

        enum CodingKeys: String, CodingKey {
            case branch, vphysics
            case appID = "app_id"
            case buildID = "build_id"
            case requestID = "request_id"
            case surfaceInputs = "surface_inputs"
        }
    }

    struct SurfaceInput: Decodable {
        let path: String
        let sha256: String
    }

    struct SurfaceLookup: Decodable {
        let requestedName: String
        let surfaceIndex: Int
        let reverseName: String
        let data: SurfaceData

        enum CodingKeys: String, CodingKey {
            case requestedName = "requested_name"
            case surfaceIndex = "surface_index"
            case reverseName = "reverse_name"
            case data
        }
    }

    struct SurfaceData: Decodable {
        let name: String
        let friction: String
        let elasticity: String
        let density: String
        let thickness: String
        let dampening: String

        enum CodingKeys: String, CodingKey {
            case name, elasticity, density, thickness, dampening
            case friction = "friction_coefficient"
        }
    }

    static func validateProvenance(_ provenance: Provenance) throws {
        guard provenance.appID == 4020 else {
            throw GModSurfaceMaterialResponseCatalogError
                .invalidProvenance("app_id must be 4020")
        }
        guard provenance.branch == "x86-64" else {
            throw GModSurfaceMaterialResponseCatalogError
                .invalidProvenance("branch must be x86-64")
        }
        guard !provenance.buildID.isEmpty,
              provenance.buildID.allSatisfy(\.isNumber) else {
            throw GModSurfaceMaterialResponseCatalogError
                .invalidProvenance("build_id is not decimal")
        }
        guard isLowercaseHex(provenance.requestID, count: 32) else {
            throw GModSurfaceMaterialResponseCatalogError
                .invalidProvenance("request_id is not 32 lowercase hex digits")
        }
        guard !provenance.vphysics.path.isEmpty,
              isLowercaseHex(provenance.vphysics.sha256, count: 64) else {
            throw GModSurfaceMaterialResponseCatalogError
                .invalidProvenance("vphysics file identity is invalid")
        }
    }

    static func validateSurfaceInputs(
        _ inputs: [SurfaceInput],
        mountedSurfaceProperties: SourceSurfacePropertiesAttestation,
        fileSystem: SourceSearchPathFileSystem
    ) throws -> [String: String] {
        let expectedPaths = [mountedSurfaceProperties.manifestPath] +
            mountedSurfaceProperties.files.map(\.logicalPath)
        guard inputs.count == expectedPaths.count else {
            throw GModSurfaceMaterialResponseCatalogError
                .surfaceInputCountMismatch(
                    expected: expectedPaths.count,
                    actual: inputs.count
                )
        }
        var matched: Set<String> = []
        var digests: [String: String] = [:]
        for input in inputs {
            guard isLowercaseHex(input.sha256, count: 64) else {
                throw GModSurfaceMaterialResponseCatalogError
                    .invalidProvenance("surface input SHA-256 is invalid")
            }
            guard let logicalPath = logicalPath(
                matching: input.path,
                expectedPaths: expectedPaths
            ) else {
                throw GModSurfaceMaterialResponseCatalogError
                    .unknownSurfaceInputPath(input.path)
            }
            guard matched.insert(fold(logicalPath)).inserted else {
                throw GModSurfaceMaterialResponseCatalogError
                    .duplicateSurfaceInputPath(input.path)
            }
            let mountedData = try fileSystem.readFile(
                logicalPath,
                pathID: "GAME"
            )
            var hasher = GModContentSHA256()
            hasher.update(mountedData)
            let actual = hasher.hexadecimalDigest()
            guard actual == input.sha256 else {
                throw GModSurfaceMaterialResponseCatalogError
                    .mountedSurfaceInputDigestMismatch(
                        path: logicalPath,
                        expected: input.sha256,
                        actual: actual
                    )
            }
            digests[logicalPath] = actual
        }
        return digests
    }

    static func logicalPath(
        matching attestedPath: String,
        expectedPaths: [String]
    ) -> String? {
        let path = fold(attestedPath.replacingOccurrences(of: "\\", with: "/"))
        return expectedPaths.first { expected in
            let candidate = fold(expected)
            return path == candidate || path.hasSuffix("/" + candidate)
        }
    }

    static func validatePhysics(
        _ data: SurfaceData,
        mounted: SourceSurfacePhysicsProperties,
        material: String
    ) throws {
        try requireSameFloat(
            data.density,
            mounted: mounted.density,
            material: material,
            field: "density"
        )
        try requireSameFloat(
            data.friction,
            mounted: mounted.friction,
            material: material,
            field: "friction"
        )
        try requireSameFloat(
            data.elasticity,
            mounted: mounted.elasticity,
            material: material,
            field: "elasticity"
        )
        try requireSameFloat(
            data.dampening,
            mounted: mounted.dampening,
            material: material,
            field: "dampening"
        )
        if let thickness = mounted.thickness {
            try requireSameFloat(
                data.thickness,
                mounted: thickness,
                material: material,
                field: "thickness"
            )
        }
    }

    static func requireSameFloat(
        _ text: String,
        mounted: Float,
        material: String,
        field: String
    ) throws {
        guard let attested = Float(text), attested.isFinite else {
            throw GModSurfaceMaterialResponseCatalogError.invalidFloat(
                material: material,
                field: field,
                value: text
            )
        }
        guard attested.bitPattern == mounted.bitPattern else {
            throw GModSurfaceMaterialResponseCatalogError.surfacePhysicsMismatch(
                material: material,
                field: field,
                mounted: mounted,
                attested: attested
            )
        }
    }

    static func fold(_ value: String) -> String {
        value.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == count && bytes.allSatisfy {
            (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0)
        }
    }
}
