import Foundation

/// One exact `mstudiobodyparts_t` entry and its ordered `mstudiomodel_t`
/// names. These strings are decoded from the mounted MDL and are retained so
/// GLua body-group menus never fabricate labels from a model path.
public struct SourceStudioBodyGroupAppearance: Equatable, Sendable {
    public let id: Int
    public let name: String
    public let modelSelectionBase: Int32
    public let submodelNames: [String]

    public init(
        id: Int,
        name: String,
        modelSelectionBase: Int32,
        submodelNames: [String]
    ) {
        self.id = id
        self.name = name
        self.modelSelectionBase = modelSelectionBase
        self.submodelNames = submodelNames
    }

    public var modelCount: Int { submodelNames.count }

    public var selectionDescriptor: SourceStudioBodyGroupSelectionDescriptor {
        SourceStudioBodyGroupSelectionDescriptor(
            modelSelectionBase: modelSelectionBase,
            modelCount: modelCount
        )
    }
}

public enum SourceStudioModelAppearanceLayoutError: Error, Equatable,
    Sendable, CustomStringConvertible
{
    case inconsistentChecksum(mesh: Int32, materials: Int32)
    case inconsistentModelName(mesh: String, materials: String)
    case invalidSkinFamilyCount(Int)
    case noncontiguousBodyGroupID(expected: Int, actual: Int)
    case invalidBodyGroupModelCount(bodyGroupID: Int, value: Int)
    case invalidBodyGroupSelectionBase(bodyGroupID: Int, value: Int32)

    public var description: String {
        switch self {
        case let .inconsistentChecksum(mesh, materials):
            return "Studio appearance mesh checksum \(mesh) does not match material checksum \(materials)"
        case let .inconsistentModelName(mesh, materials):
            return "Studio appearance mesh model '\(mesh)' does not match material model '\(materials)'"
        case let .invalidSkinFamilyCount(value):
            return "Studio appearance has invalid skin-family count \(value)"
        case let .noncontiguousBodyGroupID(expected, actual):
            return "Studio appearance expected body-group ID \(expected), got \(actual)"
        case let .invalidBodyGroupModelCount(id, value):
            return "Studio appearance body group \(id) has invalid model count \(value)"
        case let .invalidBodyGroupSelectionBase(id, value):
            return "Studio appearance body group \(id) has invalid selection base \(value)"
        }
    }
}

/// Renderer-independent appearance metadata for one validated Studio asset.
///
/// Skin families come from `studiohdr_t::pSkinref`; body-group names, bases,
/// and submodel names come from the decoded MDL/VTX hierarchy. The value is
/// immutable and is only attached to a canonical layout after checksum and
/// model-name agreement, so a stale asset revision cannot validate another
/// entity's appearance state.
public struct SourceStudioModelAppearanceLayout: Equatable, Sendable {
    public let checksum: Int32
    public let modelName: String
    public let skinFamilyCount: Int
    public let bodyGroups: [SourceStudioBodyGroupAppearance]

    public init(
        checksum: Int32,
        modelName: String,
        skinFamilyCount: Int,
        bodyGroups: [SourceStudioBodyGroupAppearance]
    ) throws {
        guard skinFamilyCount >= 0 else {
            throw SourceStudioModelAppearanceLayoutError
                .invalidSkinFamilyCount(skinFamilyCount)
        }
        for (expectedID, bodyGroup) in bodyGroups.enumerated() {
            guard bodyGroup.id == expectedID else {
                throw SourceStudioModelAppearanceLayoutError
                    .noncontiguousBodyGroupID(
                        expected: expectedID,
                        actual: bodyGroup.id
                    )
            }
            guard bodyGroup.modelCount > 0 else {
                throw SourceStudioModelAppearanceLayoutError
                    .invalidBodyGroupModelCount(
                        bodyGroupID: bodyGroup.id,
                        value: bodyGroup.modelCount
                    )
            }
            guard bodyGroup.modelSelectionBase > 0 else {
                throw SourceStudioModelAppearanceLayoutError
                    .invalidBodyGroupSelectionBase(
                        bodyGroupID: bodyGroup.id,
                        value: bodyGroup.modelSelectionBase
                    )
            }
        }
        self.checksum = checksum
        self.modelName = modelName
        self.skinFamilyCount = skinFamilyCount
        self.bodyGroups = bodyGroups
    }

    public init(
        mesh: SourceStudioModelMeshSnapshot,
        materials: SourceStudioModelMaterialTableSnapshot
    ) throws {
        guard mesh.checksum == materials.checksum else {
            throw SourceStudioModelAppearanceLayoutError.inconsistentChecksum(
                mesh: mesh.checksum,
                materials: materials.checksum
            )
        }
        guard mesh.modelName == materials.modelName else {
            throw SourceStudioModelAppearanceLayoutError.inconsistentModelName(
                mesh: mesh.modelName,
                materials: materials.modelName
            )
        }
        try self.init(
            checksum: mesh.checksum,
            modelName: mesh.modelName,
            skinFamilyCount: materials.skinFamilies.count,
            bodyGroups: mesh.bodyParts.map { bodyPart in
                SourceStudioBodyGroupAppearance(
                    id: bodyPart.index,
                    name: bodyPart.name,
                    modelSelectionBase: bodyPart.modelSelectionBase,
                    submodelNames: bodyPart.models.map(\.name)
                )
            }
        )
    }

    public func bodyGroup(
        id: Int
    ) -> SourceStudioBodyGroupAppearance? {
        guard bodyGroups.indices.contains(id) else { return nil }
        return bodyGroups[id]
    }

    public func validateSkinFamily(_ skinFamily: Int) throws {
        guard skinFamily >= 0, skinFamily < skinFamilyCount else {
            throw SourceStudioModelMaterialDecodeError.invalidSkinFamily(
                value: skinFamily,
                available: skinFamilyCount
            )
        }
    }
}
