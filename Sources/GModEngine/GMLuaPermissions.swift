import Foundation
import GModLua

/// Immutable native ownership projected by MENU's `permissions.GetAll`.
/// The values remain grouped by the server which requested each capability;
/// the Lua bridge serializes each sorted list to the comma-delimited strings
/// consumed by the shipped PermissionViewer.
public struct GMLuaPermissionSnapshot: Sendable, Equatable {
    public let temporary: [String: [String]]
    public let permanent: [String: [String]]

    public init(
        temporary: [String: [String]],
        permanent: [String: [String]]
    ) {
        self.temporary = temporary
        self.permanent = permanent
    }
}

/// A successful `permissions.Connect` result. Remote transport deliberately
/// has no success case until a real multiplayer host is supplied.
public enum GMLuaPermissionConnectResult: Sendable, Equatable {
    case localSession
}

/// App-owned permission storage presented to one trusted MENU realm.
///
/// MENU rendering and native permission persistence both run on the app's
/// main actor. Keeping that executor in the function types prevents a Lua
/// state from silently mutating ObservableObject state on a worker thread.
public struct GMLuaPermissionsHost: @unchecked Sendable {
    private let currentServerIdentifierBody: @MainActor () throws -> String
    private let grantBody: @MainActor (
        String, String, Bool
    ) throws -> Bool
    private let revokeBody: @MainActor (String, String) throws -> Bool
    private let isGrantedBody: @MainActor (String, String) throws -> Bool
    private let getAllBody: @MainActor () throws -> GMLuaPermissionSnapshot
    private let connectBody: @MainActor (
        String
    ) throws -> GMLuaPermissionConnectResult

    public init(
        currentServerIdentifier: @escaping @MainActor () throws -> String,
        grant: @escaping @MainActor (
            _ permission: String,
            _ serverIdentifier: String,
            _ sessionOnly: Bool
        ) throws -> Bool,
        revoke: @escaping @MainActor (
            _ permission: String,
            _ serverIdentifier: String
        ) throws -> Bool,
        isGranted: @escaping @MainActor (
            _ permission: String,
            _ serverIdentifier: String
        ) throws -> Bool,
        getAll: @escaping @MainActor () throws -> GMLuaPermissionSnapshot,
        connect: @escaping @MainActor (
            _ target: String
        ) throws -> GMLuaPermissionConnectResult
    ) {
        currentServerIdentifierBody = currentServerIdentifier
        grantBody = grant
        revokeBody = revoke
        isGrantedBody = isGranted
        getAllBody = getAll
        connectBody = connect
    }

    @MainActor
    fileprivate func currentServerIdentifier() throws -> String {
        try currentServerIdentifierBody()
    }

    @MainActor
    fileprivate func grant(
        _ permission: String,
        serverIdentifier: String,
        sessionOnly: Bool
    ) throws -> Bool {
        try grantBody(permission, serverIdentifier, sessionOnly)
    }

    @MainActor
    fileprivate func revoke(
        _ permission: String,
        serverIdentifier: String
    ) throws -> Bool {
        try revokeBody(permission, serverIdentifier)
    }

    @MainActor
    fileprivate func isGranted(
        _ permission: String,
        serverIdentifier: String
    ) throws -> Bool {
        try isGrantedBody(permission, serverIdentifier)
    }

    @MainActor
    fileprivate func getAll() throws -> GMLuaPermissionSnapshot {
        try getAllBody()
    }

    @MainActor
    fileprivate func connect(
        to target: String
    ) throws -> GMLuaPermissionConnectResult {
        try connectBody(target)
    }
}

/// Native implementation of the MENU-only permissions library used by
/// shipped `menu/openurl.lua` and `menu/problems/permissions.lua`.
public enum GMLuaPermissions {
    @discardableResult
    public static func install(
        into state: LuaState,
        realm: GMLuaRealm,
        host: GMLuaPermissionsHost,
        onPermissionsChanged: @escaping () -> Void = {},
        onLocalSessionConnect: @escaping () throws -> Void = {}
    ) throws -> Bool {
        guard realm == .menu else { return false }

        let permissionsTable: LuaTable
        if case let .table(existing) = state.getGlobal("permissions") {
            permissionsTable = existing
        } else {
            permissionsTable = LuaTable()
        }

        try set("Grant", in: permissionsTable, state: state) { arguments in
            let permission = try requiredString(
                arguments,
                index: 0,
                function: "permissions.Grant"
            )
            let sessionOnly = try requiredBoolean(
                arguments,
                index: 1,
                function: "permissions.Grant"
            )
            let changed = try onMainActor {
                let server = try host.currentServerIdentifier()
                return try host.grant(
                    permission,
                    serverIdentifier: server,
                    sessionOnly: sessionOnly
                )
            }
            if changed { onPermissionsChanged() }
            return []
        }

        try set("Revoke", in: permissionsTable, state: state) { arguments in
            let permission = try requiredString(
                arguments,
                index: 0,
                function: "permissions.Revoke"
            )
            let server = try requiredString(
                arguments,
                index: 1,
                function: "permissions.Revoke"
            )
            let changed = try onMainActor {
                try host.revoke(permission, serverIdentifier: server)
            }
            if changed { onPermissionsChanged() }
            return []
        }

        try set("IsGranted", in: permissionsTable, state: state) { arguments in
            let permission = try requiredString(
                arguments,
                index: 0,
                function: "permissions.IsGranted"
            )
            let granted = try onMainActor {
                let server = try host.currentServerIdentifier()
                return try host.isGranted(
                    permission,
                    serverIdentifier: server
                )
            }
            return [.boolean(granted)]
        }

        try set("GetAll", in: permissionsTable, state: state) { _ in
            let snapshot = try onMainActor { try host.getAll() }
            return [.table(try makeLuaSnapshot(snapshot, state: state))]
        }

        try set("Connect", in: permissionsTable, state: state) { arguments in
            let target = try requiredString(
                arguments,
                index: 0,
                function: "permissions.Connect"
            )
            let result = try onMainActor { try host.connect(to: target) }
            switch result {
            case .localSession:
                try onLocalSessionConnect()
            }
            return []
        }

        state.setGlobal("permissions", value: .table(permissionsTable))
        return true
    }

    private static func makeLuaSnapshot(
        _ snapshot: GMLuaPermissionSnapshot,
        state: LuaState
    ) throws -> LuaTable {
        let root = LuaTable()
        let temporary = try makeLuaGroup(snapshot.temporary, state: state)
        let permanent = try makeLuaGroup(snapshot.permanent, state: state)
        try state.setRawTableValue(
            .table(temporary),
            for: .string("temporary"),
            in: root
        )
        try state.setRawTableValue(
            .table(permanent),
            for: .string("permanent"),
            in: root
        )
        return root
    }

    private static func makeLuaGroup(
        _ group: [String: [String]],
        state: LuaState
    ) throws -> LuaTable {
        let table = LuaTable()
        for server in group.keys.sorted() {
            let permissions = (group[server] ?? []).sorted()
            try state.setRawTableValue(
                .string(LuaString(permissions.joined(separator: ","))),
                for: .string(LuaString(server)),
                in: table
            )
        }
        return table
    }

    private static func onMainActor<T>(
        _ operation: @MainActor () throws -> T
    ) throws -> T {
        guard Thread.isMainThread else {
            throw LuaError.runtime(
                "permissions MENU bridge must be invoked on the main actor"
            )
        }
        return try MainActor.assumeIsolated(operation)
    }

    private static func requiredString(
        _ arguments: [LuaValue],
        index: Int,
        function: String
    ) throws -> String {
        guard arguments.indices.contains(index),
              case let .string(value) = arguments[index] else {
            let actual = arguments.indices.contains(index)
                ? arguments[index].typeName
                : "no value"
            throw LuaError.runtime(
                "bad argument #\(index + 1) to '\(function)' " +
                    "(string expected, got \(actual))"
            )
        }
        return value.utf8String
    }

    private static func requiredBoolean(
        _ arguments: [LuaValue],
        index: Int,
        function: String
    ) throws -> Bool {
        guard arguments.indices.contains(index),
              case let .boolean(value) = arguments[index] else {
            let actual = arguments.indices.contains(index)
                ? arguments[index].typeName
                : "no value"
            throw LuaError.runtime(
                "bad argument #\(index + 1) to '\(function)' " +
                    "(boolean expected, got \(actual))"
            )
        }
        return value
    }

    private static func set(
        _ name: String,
        in table: LuaTable,
        state: LuaState,
        body: @escaping LuaNativeFunction
    ) throws {
        try state.setRawTableValue(
            .nativeFunction(LuaNativeFunctionBox(
                body,
                debugName: "permissions.\(name)"
            )),
            for: .string(LuaString(name)),
            in: table
        )
    }
}
