import Foundation
import GModLua

/// Weapon-selector metadata copied from the inherited table returned by the
/// original `weapons.Get`. `printName` intentionally preserves localization
/// tokens such as `#gmod_tool`; localization and presentation belong to later
/// UI layers.
public struct GMLuaScriptedWeaponSelectionMetadata: Sendable, Equatable {
    public let className: String
    public let slot: Int
    public let slotPosition: Int
    public let printName: String

    public init(
        className: String,
        slot: Int,
        slotPosition: Int,
        printName: String
    ) {
        self.className = className
        self.slot = slot
        self.slotPosition = slotPosition
        self.printName = printName
    }
}

public enum GMLuaScriptedWeaponSelectionMetadataError:
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
    case missingField(className: String, field: String)
    case invalidFieldType(className: String, field: String, actualType: String)
    case invalidIntegerField(className: String, field: String, value: Double)
    case invalidUTF8(className: String, field: String)

    public var description: String {
        switch self {
        case .runtimeClosed:
            return "scripted weapon selection metadata runtime is closed"
        case let .invalidClassName(className):
            return "scripted weapon selection class name is invalid: '\(className)'"
        case .weaponsLibraryUnavailable:
            return "weapons library is unavailable"
        case let .getFunctionUnavailable(actualType):
            return "weapons.Get is unavailable (got \(actualType))"
        case let .classUnavailable(className, actualType):
            return "weapons.Get('\(className)') returned \(actualType)"
        case let .missingField(className, field):
            return "\(className).\(field) is missing"
        case let .invalidFieldType(className, field, actualType):
            return "\(className).\(field) has type \(actualType)"
        case let .invalidIntegerField(className, field, value):
            return "\(className).\(field) is not an exactly representable integer: \(value)"
        case let .invalidUTF8(className, field):
            return "\(className).\(field) is not valid UTF-8"
        }
    }
}

public extension GMLuaRuntime {
    /// Reads selector metadata from the exact inherited SWEP table produced by
    /// `weapons.Get`. Missing or malformed fields fail closed; this resolver
    /// does not invent selector defaults outside the original Lua inheritance.
    func scriptedWeaponSelectionMetadata(
        className: String
    ) throws -> GMLuaScriptedWeaponSelectionMetadata {
        guard !isClosed else {
            throw GMLuaScriptedWeaponSelectionMetadataError.runtimeClosed
        }
        guard SourceCanonicalEntityKind.isStructurallyValidWeaponClassName(
            className
        ) else {
            throw GMLuaScriptedWeaponSelectionMetadataError.invalidClassName(
                className
            )
        }
        guard case let .table(weapons) = state.getGlobal("weapons") else {
            throw GMLuaScriptedWeaponSelectionMetadataError
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
            throw GMLuaScriptedWeaponSelectionMetadataError
                .getFunctionUnavailable(actualType: get.typeName)
        }
        let resolved = try state.call(
            get,
            arguments: [.string(LuaString(className))]
        ).first ?? .nilValue
        guard case let .table(table) = resolved else {
            throw GMLuaScriptedWeaponSelectionMetadataError.classUnavailable(
                className,
                actualType: resolved.typeName
            )
        }
        return try scriptedWeaponSelectionMetadata(
            className: className,
            resolvedTable: table
        )
    }
}

extension GMLuaRuntime {
    func scriptedWeaponSelectionMetadata(
        className: String,
        resolvedTable table: LuaTable
    ) throws -> GMLuaScriptedWeaponSelectionMetadata {
        GMLuaScriptedWeaponSelectionMetadata(
            className: className,
            slot: try scriptedWeaponSelectionIntegerField(
                "Slot",
                className: className,
                table: table
            ),
            slotPosition: try scriptedWeaponSelectionIntegerField(
                "SlotPos",
                className: className,
                table: table
            ),
            printName: try scriptedWeaponSelectionStringField(
                "PrintName",
                className: className,
                table: table
            )
        )
    }

    private func scriptedWeaponSelectionIntegerField(
        _ field: String,
        className: String,
        table: LuaTable
    ) throws -> Int {
        let value = try state.rawTableValue(
            for: .string(LuaString(field)),
            in: table
        )
        if case .nilValue = value {
            throw GMLuaScriptedWeaponSelectionMetadataError.missingField(
                className: className,
                field: field
            )
        }
        guard case let .number(rawValue) = value else {
            throw GMLuaScriptedWeaponSelectionMetadataError.invalidFieldType(
                className: className,
                field: field,
                actualType: value.typeName
            )
        }
        guard rawValue.isFinite, let result = Int(exactly: rawValue) else {
            throw GMLuaScriptedWeaponSelectionMetadataError.invalidIntegerField(
                className: className,
                field: field,
                value: rawValue
            )
        }
        return result
    }

    private func scriptedWeaponSelectionStringField(
        _ field: String,
        className: String,
        table: LuaTable
    ) throws -> String {
        let value = try state.rawTableValue(
            for: .string(LuaString(field)),
            in: table
        )
        if case .nilValue = value {
            throw GMLuaScriptedWeaponSelectionMetadataError.missingField(
                className: className,
                field: field
            )
        }
        guard case let .string(bytes) = value else {
            throw GMLuaScriptedWeaponSelectionMetadataError.invalidFieldType(
                className: className,
                field: field,
                actualType: value.typeName
            )
        }
        guard let result = String(bytes: bytes.bytes, encoding: .utf8) else {
            throw GMLuaScriptedWeaponSelectionMetadataError.invalidUTF8(
                className: className,
                field: field
            )
        }
        return result
    }
}
