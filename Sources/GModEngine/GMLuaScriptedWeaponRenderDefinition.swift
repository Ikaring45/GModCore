import Foundation
import GModLua

/// Renderer-relevant fields from the inherited table returned by the original
/// `weapons.Get`. Empty model strings remain an intentional no-model request;
/// this value does not validate or manufacture a Studio asset.
public struct GMLuaScriptedWeaponRenderDefinition: Sendable, Equatable {
    public let className: String
    public let viewModel: SourceEntityModelReference?
    public let worldModel: SourceEntityModelReference?
    public let viewModelFieldOfViewDegrees: Float

    public init(
        className: String,
        viewModel: SourceEntityModelReference?,
        worldModel: SourceEntityModelReference?,
        viewModelFieldOfViewDegrees: Float
    ) {
        self.className = className
        self.viewModel = viewModel
        self.worldModel = worldModel
        self.viewModelFieldOfViewDegrees = viewModelFieldOfViewDegrees
    }
}

public enum GMLuaScriptedWeaponRenderDefinitionError:
    Error,
    Sendable,
    Equatable,
    CustomStringConvertible
{
    case runtimeClosed
    case invalidClassName(String)
    case weaponsLibraryUnavailable
    case getFunctionUnavailable(actualType: String)
    case classUnavailable(String, actualType: String)
    case invalidField(className: String, field: String, actualType: String)
    case invalidModelUTF8(className: String, field: String)
    case invalidViewModelFieldOfView(className: String, value: Double)

    public var description: String {
        switch self {
        case .runtimeClosed:
            return "scripted Weapon render definition runtime is closed"
        case let .invalidClassName(className):
            return "scripted Weapon render class name is invalid: '\(className)'"
        case .weaponsLibraryUnavailable:
            return "weapons library is unavailable"
        case let .getFunctionUnavailable(actualType):
            return "weapons.Get is unavailable (got \(actualType))"
        case let .classUnavailable(className, actualType):
            return "weapons.Get('\(className)') returned \(actualType)"
        case let .invalidField(className, field, actualType):
            return "\(className).\(field) has type \(actualType)"
        case let .invalidModelUTF8(className, field):
            return "\(className).\(field) is not valid UTF-8"
        case let .invalidViewModelFieldOfView(className, value):
            return "\(className).ViewModelFOV is outside (0, 180): \(value)"
        }
    }
}

public extension GMLuaRuntime {
    /// Resolves the real inherited SWEP table in this realm. The caller must
    /// invoke this on the runtime's serialized lane, just like other Lua reads.
    func scriptedWeaponRenderDefinition(
        className: String
    ) throws -> GMLuaScriptedWeaponRenderDefinition {
        guard !isClosed else {
            throw GMLuaScriptedWeaponRenderDefinitionError.runtimeClosed
        }
        guard SourceCanonicalEntityKind.isStructurallyValidWeaponClassName(
            className
        ) else {
            throw GMLuaScriptedWeaponRenderDefinitionError.invalidClassName(
                className
            )
        }
        guard case let .table(weapons) = state.getGlobal("weapons") else {
            throw GMLuaScriptedWeaponRenderDefinitionError
                .weaponsLibraryUnavailable
        }
        let get = try state.rawTableValue(
            for: .string("Get"),
            in: weapons
        )
        switch get {
        case .luaFunction, .nativeFunction:
            break
        default:
            throw GMLuaScriptedWeaponRenderDefinitionError
                .getFunctionUnavailable(actualType: get.typeName)
        }
        let resolved = try state.call(
            get,
            arguments: [.string(LuaString(className))]
        ).first ?? .nilValue
        guard case let .table(table) = resolved else {
            throw GMLuaScriptedWeaponRenderDefinitionError.classUnavailable(
                className,
                actualType: resolved.typeName
            )
        }
        return try scriptedWeaponRenderDefinition(
            className: className,
            resolvedTable: table
        )
    }
}

extension GMLuaRuntime {
    /// Shared by SERVER initialization after it has already obtained the exact
    /// `weapons.Get` result and by the public CLIENT read above.
    func scriptedWeaponRenderDefinition(
        className: String,
        resolvedTable table: LuaTable
    ) throws -> GMLuaScriptedWeaponRenderDefinition {
        let viewModel = try scriptedWeaponModelField(
            "ViewModel",
            className: className,
            table: table
        )
        let worldModel = try scriptedWeaponModelField(
            "WorldModel",
            className: className,
            table: table
        )
        let fovValue = try state.rawTableValue(
            for: .string("ViewModelFOV"),
            in: table
        )
        guard case let .number(rawFOV) = fovValue else {
            throw GMLuaScriptedWeaponRenderDefinitionError.invalidField(
                className: className,
                field: "ViewModelFOV",
                actualType: fovValue.typeName
            )
        }
        guard rawFOV.isFinite, rawFOV > 0, rawFOV < 180 else {
            throw GMLuaScriptedWeaponRenderDefinitionError
                .invalidViewModelFieldOfView(
                    className: className,
                    value: rawFOV
                )
        }
        return GMLuaScriptedWeaponRenderDefinition(
            className: className,
            viewModel: viewModel,
            worldModel: worldModel,
            viewModelFieldOfViewDegrees: Float(rawFOV)
        )
    }

    private func scriptedWeaponModelField(
        _ field: String,
        className: String,
        table: LuaTable
    ) throws -> SourceEntityModelReference? {
        let value = try state.rawTableValue(
            for: .string(LuaString(field)),
            in: table
        )
        guard case let .string(bytes) = value else {
            throw GMLuaScriptedWeaponRenderDefinitionError.invalidField(
                className: className,
                field: field,
                actualType: value.typeName
            )
        }
        guard let path = String(bytes: bytes.bytes, encoding: .utf8) else {
            throw GMLuaScriptedWeaponRenderDefinitionError.invalidModelUTF8(
                className: className,
                field: field
            )
        }
        return path.isEmpty ? nil : SourceEntityModelReference(path)
    }
}
