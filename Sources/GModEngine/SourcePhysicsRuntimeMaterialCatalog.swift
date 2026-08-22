/// One VPhysics runtime material mapping authenticated independently from the
/// mounted surface-properties declaration order.
///
/// `runtimeMaterialIndex` is the value returned by Source's
/// `IPhysicsSurfaceProps::GetSurfaceIndex`. It is deliberately not populated
/// from `SourceSurfaceMaterialAttestation.declarationOrdinal`, BSP texture
/// indices, or the seven-bit material field stored in a serialized collide.
public struct SourcePhysicsRuntimeMaterialCatalogEntry:
    Equatable, Sendable
{
    public let runtimeName: String
    public let runtimeMaterialIndex: Int
    public let surfacePhysics: SourceSurfacePhysicsProperties

    public init(
        runtimeName: String,
        runtimeMaterialIndex: Int,
        surfacePhysics: SourceSurfacePhysicsProperties
    ) throws {
        _ = try SourcePhysicsMaterialNameEntry(
            name: runtimeName,
            materialIndex: runtimeMaterialIndex
        )
        self.runtimeName = runtimeName
        self.runtimeMaterialIndex = runtimeMaterialIndex
        self.surfacePhysics = surfacePhysics
    }
}

/// Exact external runtime and mounted-input identity behind one catalog.
public struct SourcePhysicsRuntimeMaterialCatalogProvenance:
    Equatable, Sendable
{
    public let appID: Int
    public let branch: String
    public let buildID: String
    public let requestID: String
    public let vphysicsSHA256: String
    public let surfaceInputSHA256ByLogicalPath: [String: String]

    public init(
        appID: Int,
        branch: String,
        buildID: String,
        requestID: String,
        vphysicsSHA256: String,
        surfaceInputSHA256ByLogicalPath: [String: String]
    ) {
        self.appID = appID
        self.branch = branch
        self.buildID = buildID
        self.requestID = requestID
        self.vphysicsSHA256 = vphysicsSHA256
        self.surfaceInputSHA256ByLogicalPath =
            surfaceInputSHA256ByLogicalPath
    }
}

/// Immutable, partial-or-complete view of Source's runtime surface database.
///
/// A catalog may contain only the names exercised by an independent oracle.
/// Missing names and indices remain unavailable; no declaration ordinal or
/// default material is synthesized to fill a gap.
public struct SourcePhysicsRuntimeMaterialCatalog: Equatable, Sendable {
    public let provenance: SourcePhysicsRuntimeMaterialCatalogProvenance
    public let entries: [SourcePhysicsRuntimeMaterialCatalogEntry]
    public let nameTable: SourcePhysicsMaterialNameTable

    public init(
        provenance: SourcePhysicsRuntimeMaterialCatalogProvenance,
        entries: [SourcePhysicsRuntimeMaterialCatalogEntry]
    ) throws {
        let nameEntries = try entries.map {
            try SourcePhysicsMaterialNameEntry(
                name: $0.runtimeName,
                materialIndex: $0.runtimeMaterialIndex
            )
        }
        nameTable = try SourcePhysicsMaterialNameTable(entries: nameEntries)
        self.provenance = provenance
        self.entries = entries
    }

    public func entry(runtimeMaterialIndex: Int)
        -> SourcePhysicsRuntimeMaterialCatalogEntry?
    {
        entries.first { $0.runtimeMaterialIndex == runtimeMaterialIndex }
    }

    public func entry(named name: String)
        -> SourcePhysicsRuntimeMaterialCatalogEntry?
    {
        guard let index = nameTable.materialIndex(named: name) else {
            return nil
        }
        return entry(runtimeMaterialIndex: index)
    }
}
