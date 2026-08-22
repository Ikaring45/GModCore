import Combine
import Foundation
import GModEngine

enum GModPermissionLifetime: String, Codable, CaseIterable, Sendable {
    case temporary
    case permanent
}

struct GModPermissionGrant: Identifiable, Equatable, Sendable {
    let serverIdentifier: String
    let permission: String
    let lifetime: GModPermissionLifetime

    var id: String {
        "\(serverIdentifier)|\(lifetime.rawValue)|\(permission)"
    }
}

struct GModPermissionCollection: Equatable, Sendable {
    let temporary: [String: [String]]
    let permanent: [String: [String]]

    static let empty = GModPermissionCollection(
        temporary: [:],
        permanent: [:]
    )

    var grants: [GModPermissionGrant] {
        Self.flatten(temporary, lifetime: .temporary)
            + Self.flatten(permanent, lifetime: .permanent)
    }

    private static func flatten(
        _ groups: [String: [String]],
        lifetime: GModPermissionLifetime
    ) -> [GModPermissionGrant] {
        groups.keys.sorted().flatMap { server in
            (groups[server] ?? []).sorted().map { permission in
                GModPermissionGrant(
                    serverIdentifier: server,
                    permission: permission,
                    lifetime: lifetime
                )
            }
        }
    }
}

enum GModPermissionStoreError: Error, Equatable, Sendable {
    case malformedServerIdentifier
    case malformedPermission
    case malformedConnectTarget
    case malformedPersistedPermissions
    case multiplayerTransportUnavailable
}

enum GModPermissionConnectionResult: Equatable, Sendable {
    case localSession
}

extension GModPermissionStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .malformedServerIdentifier:
            return "permission server identifier is empty or contains invalid characters"
        case .malformedPermission:
            return "permission name is empty or contains invalid characters"
        case .malformedConnectTarget:
            return "connection target is empty or contains invalid characters"
        case .malformedPersistedPermissions:
            return "persisted permissions failed schema or value validation"
        case .multiplayerTransportUnavailable:
            return "multiplayer transport is not implemented; permissions.Connect was rejected"
        }
    }
}

/// Native ownership and persistence shared by the MENU Lua permissions
/// library and the iPad Problems view. Remote multiplayer remains an explicit
/// unavailable boundary, while the real local single-player host is routable.
@MainActor
final class GModPermissionStore: ObservableObject {
    static let shared = GModPermissionStore()
    static let localServerIdentifier = "local://garrys-pad"
    static let permanentPermissionsKey =
        "GarrysPAD.Permissions.Permanent.v1"
    static let didChangeNotification = Notification.Name(
        "GarrysPAD.PermissionsDidChange"
    )

    @Published private(set) var collection: GModPermissionCollection
    @Published private(set) var persistenceError: GModPermissionStoreError?

    private var temporary: [String: Set<String>] = [:]
    private var permanent: [String: Set<String>] = [:]
    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter

    init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter

        let loaded = Self.loadPermanentPermissions(from: defaults)
        permanent = loaded.permissions
        persistenceError = loaded.error
        collection = Self.makeCollection(
            temporary: [:],
            permanent: loaded.permissions
        )
    }

    @discardableResult
    func grant(
        _ rawPermission: String,
        for rawServerIdentifier: String,
        lifetime: GModPermissionLifetime
    ) throws -> Bool {
        let server = try Self.validatedServerIdentifier(rawServerIdentifier)
        let permission = try Self.validatedPermission(rawPermission)

        switch lifetime {
        case .temporary:
            guard permanent[server]?.contains(permission) != true else {
                return false
            }
            var permissions = temporary[server, default: []]
            guard permissions.insert(permission).inserted else { return false }
            temporary[server] = permissions

        case .permanent:
            var permissions = permanent[server, default: []]
            let inserted = permissions.insert(permission).inserted
            let removedTemporary = temporary[server]?.contains(permission) == true
            guard inserted || removedTemporary else { return false }

            var replacement = permanent
            replacement[server] = permissions
            try persist(replacement)
            permanent = replacement
            _ = temporary[server]?.remove(permission)
            removeEmptyGroup(server, from: &temporary)
        }

        publishChange()
        return true
    }

    @discardableResult
    func revoke(
        _ rawPermission: String,
        for rawServerIdentifier: String
    ) throws -> Bool {
        let server = try Self.validatedServerIdentifier(rawServerIdentifier)
        let permission = try Self.validatedPermission(rawPermission)

        let removedTemporary = temporary[server]?.remove(permission) != nil
        removeEmptyGroup(server, from: &temporary)

        var replacement = permanent
        let removedPermanent = replacement[server]?.remove(permission) != nil
        removeEmptyGroup(server, from: &replacement)
        guard removedTemporary || removedPermanent else { return false }

        if removedPermanent {
            do {
                try persist(replacement)
            } catch {
                if removedTemporary {
                    temporary[server, default: []].insert(permission)
                }
                throw error
            }
            permanent = replacement
        }

        publishChange()
        return true
    }

    func isGranted(
        _ rawPermission: String,
        for rawServerIdentifier: String
    ) throws -> Bool {
        let server = try Self.validatedServerIdentifier(rawServerIdentifier)
        let permission = try Self.validatedPermission(rawPermission)
        return temporary[server]?.contains(permission) == true
            || permanent[server]?.contains(permission) == true
    }

    func getAll() -> GModPermissionCollection {
        collection
    }

    /// Temporary grants are process memory only. Calling this at a map/server
    /// session boundary removes them without touching permanent decisions.
    @discardableResult
    func clearTemporaryPermissions() -> Bool {
        guard !temporary.isEmpty else { return false }
        temporary.removeAll(keepingCapacity: true)
        publishChange()
        return true
    }

    /// Resolves Connect against the host paths which actually exist. The
    /// local identifier resumes the current single-player host through the
    /// MENU action queue; arbitrary addresses still require multiplayer
    /// transport and are rejected without changing permission state.
    func connect(
        to rawTarget: String
    ) throws -> GModPermissionConnectionResult {
        let target = try Self.validatedConnectTarget(rawTarget)
        guard target == Self.localServerIdentifier else {
            throw GModPermissionStoreError.multiplayerTransportUnavailable
        }
        return .localSession
    }

    /// Builds the native MENU bridge over this exact store. The bridge keeps
    /// the shipped implicit-current-server signatures while GetAll retains
    /// every server group for the stock PermissionViewer.
    func makeLuaPermissionsHost() -> GMLuaPermissionsHost {
        GMLuaPermissionsHost(
            currentServerIdentifier: {
                Self.localServerIdentifier
            },
            grant: { [weak self] permission, server, sessionOnly in
                guard let self else { return false }
                return try self.grant(
                    permission,
                    for: server,
                    lifetime: sessionOnly ? .temporary : .permanent
                )
            },
            revoke: { [weak self] permission, server in
                guard let self else { return false }
                return try self.revoke(permission, for: server)
            },
            isGranted: { [weak self] permission, server in
                guard let self else { return false }
                return try self.isGranted(permission, for: server)
            },
            getAll: { [weak self] in
                let collection = self?.getAll() ?? .empty
                return GMLuaPermissionSnapshot(
                    temporary: collection.temporary,
                    permanent: collection.permanent
                )
            },
            connect: { [weak self] target in
                guard let self else {
                    throw GModPermissionStoreError.multiplayerTransportUnavailable
                }
                switch try self.connect(to: target) {
                case .localSession:
                    return .localSession
                }
            }
        )
    }

    private func publishChange() {
        collection = Self.makeCollection(
            temporary: temporary,
            permanent: permanent
        )
        notificationCenter.post(
            name: Self.didChangeNotification,
            object: self
        )
    }

    private func persist(_ replacement: [String: Set<String>]) throws {
        let payload = PersistedPermissions(
            version: 1,
            permanent: replacement.mapValues { $0.sorted() }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        defaults.set(data, forKey: Self.permanentPermissionsKey)
        persistenceError = nil
    }

    private func removeEmptyGroup(
        _ server: String,
        from groups: inout [String: Set<String>]
    ) {
        if groups[server]?.isEmpty == true {
            groups.removeValue(forKey: server)
        }
    }

    private static func makeCollection(
        temporary: [String: Set<String>],
        permanent: [String: Set<String>]
    ) -> GModPermissionCollection {
        GModPermissionCollection(
            temporary: temporary.mapValues { $0.sorted() },
            permanent: permanent.mapValues { $0.sorted() }
        )
    }

    private static func loadPermanentPermissions(
        from defaults: UserDefaults
    ) -> (
        permissions: [String: Set<String>],
        error: GModPermissionStoreError?
    ) {
        guard defaults.object(forKey: permanentPermissionsKey) != nil else {
            return ([:], nil)
        }
        guard let data = defaults.data(forKey: permanentPermissionsKey) else {
            return ([:], .malformedPersistedPermissions)
        }
        do {
            let payload = try JSONDecoder().decode(
                PersistedPermissions.self,
                from: data
            )
            guard payload.version == 1 else {
                return ([:], .malformedPersistedPermissions)
            }
            var validated: [String: Set<String>] = [:]
            for (rawServer, rawPermissions) in payload.permanent {
                let server = try validatedServerIdentifier(rawServer)
                guard validated[server] == nil, !rawPermissions.isEmpty else {
                    throw GModPermissionStoreError.malformedPersistedPermissions
                }
                var permissions: Set<String> = []
                for rawPermission in rawPermissions {
                    let permission = try validatedPermission(rawPermission)
                    guard permissions.insert(permission).inserted else {
                        throw GModPermissionStoreError.malformedPersistedPermissions
                    }
                }
                validated[server] = permissions
            }
            return (validated, nil)
        } catch {
            return ([:], .malformedPersistedPermissions)
        }
    }

    private static func validatedServerIdentifier(
        _ rawValue: String
    ) throws -> String {
        try validatedValue(
            rawValue,
            maximumLength: 512,
            error: .malformedServerIdentifier
        )
    }

    private static func validatedPermission(_ rawValue: String) throws -> String {
        try validatedValue(
            rawValue,
            maximumLength: 2_048,
            error: .malformedPermission
        )
    }

    private static func validatedConnectTarget(
        _ rawValue: String
    ) throws -> String {
        try validatedValue(
            rawValue,
            maximumLength: 2_048,
            error: .malformedConnectTarget
        )
    }

    private static func validatedValue(
        _ rawValue: String,
        maximumLength: Int,
        error: GModPermissionStoreError
    ) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.count <= maximumLength,
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw error
        }
        return value
    }

    private struct PersistedPermissions: Codable {
        let version: Int
        let permanent: [String: [String]]
    }
}
