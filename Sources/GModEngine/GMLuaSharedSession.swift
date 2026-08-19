import Foundation
import GModLua

public enum GMLuaSharedSessionError: Error, CustomStringConvertible {
    case invalidRealm(server: GMLuaRealm, client: GMLuaRealm)
    case closedRuntime(GMLuaRealm)
    case transportMismatch(GMLuaRealm)
    case missingRuntimeSurface(GMLuaRealm, String)
    case invalidPlayerIndex(Int)
    case invalidUserID(Int)
    case playerIndexInUse(Int)
    case userIDInUse(Int)
    case clientAlreadyConnected
    case clientNotConnected
    case differentServer
    case lifecycleDuringPump(String)

    public var description: String {
        switch self {
        case let .invalidRealm(server, client):
            return "shared session requires SERVER + CLIENT, got \(server.rawValue) + \(client.rawValue)"
        case let .closedRuntime(realm):
            return "cannot connect closed \(realm.rawValue) runtime"
        case let .transportMismatch(realm):
            return "\(realm.rawValue) runtime does not use this shared session transport"
        case let .missingRuntimeSurface(realm, surface):
            return "\(realm.rawValue) runtime has no \(surface)"
        case let .invalidPlayerIndex(index):
            return "shared session player index must be positive, got \(index)"
        case let .invalidUserID(userID):
            return "shared session player UserID must be positive, got \(userID)"
        case let .playerIndexInUse(index):
            return "shared session entity index \(index) is already registered or connected"
        case let .userIDInUse(userID):
            return "shared session Player UserID \(userID) is already registered or connected"
        case .clientAlreadyConnected:
            return "CLIENT runtime is already connected"
        case .clientNotConnected:
            return "CLIENT runtime is not connected"
        case .differentServer:
            return "shared session clients must connect to the same SERVER runtime"
        case let .lifecycleDuringPump(operation):
            return "shared session cannot \(operation) synchronously from a Lua delivery callback"
        }
    }
}

/// Host-owned SERVER/CLIENT gameplay session.
///
/// Both runtimes must be constructed with ``netTransport``. `connect` creates
/// realm-local canonical Player userdata for one shared engine player index,
/// activates CLIENT `LocalPlayer()`, and connects console forwarding. Net
/// packets and forwarded console commands share the transport's one FIFO and
/// enter Lua only when the host calls ``pump``.
public final class GMLuaSharedSession: @unchecked Sendable {
    public let netTransport: GMLuaNetTransport

    private final class ConnectionRecord: @unchecked Sendable {
        weak var server: GMLuaRuntime?
        weak var client: GMLuaRuntime?
        let clientEndpoint: GMLuaNetEndpoint
        let playerIndex: Int
        let userID: Int
        let generation: UInt64
        let className: String

        init(
            server: GMLuaRuntime,
            client: GMLuaRuntime,
            clientEndpoint: GMLuaNetEndpoint,
            playerIndex: Int,
            userID: Int,
            generation: UInt64,
            className: String
        ) {
            self.server = server
            self.client = client
            self.clientEndpoint = clientEndpoint
            self.playerIndex = playerIndex
            self.userID = userID
            self.generation = generation
            self.className = className
        }
    }

    private let connectionMutationLock = NSRecursiveLock()
    private let lock = NSLock()
    private weak var serverRuntime: GMLuaRuntime?
    private var nextGeneration: UInt64 = 0
    private var connectionsByClient: [ObjectIdentifier: ConnectionRecord] = [:]
    private var clientByPlayerIndex: [Int: ObjectIdentifier] = [:]
    private var clientByUserID: [Int: ObjectIdentifier] = [:]

    public init(netTransport: GMLuaNetTransport = GMLuaNetTransport()) {
        self.netTransport = netTransport
        netTransport.requireExplicitClientConnections()
    }

    public var connectedClientCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return connectionsByClient.count
    }

    public var connectedPlayerIndices: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return clientByPlayerIndex.keys.sorted()
    }

    public var connectedUserIDs: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return clientByUserID.keys.sorted()
    }

    /// Activates one client connection. Call this at a host lifecycle boundary,
    /// normally the StartupOrchestrator player-connection stage.
    public func connect(
        server: GMLuaRuntime,
        client: GMLuaRuntime,
        playerIndex: Int = 1,
        userID: Int? = nil,
        className: String = "player"
    ) throws {
        guard !netTransport.isPumpingOnCurrentThread() else {
            throw GMLuaSharedSessionError.lifecycleDuringPump("connect")
        }
        try netTransport.withExclusiveLifecycleBoundary {
            connectionMutationLock.lock()
            defer { connectionMutationLock.unlock() }
            try connectWhileLifecycleExclusive(
                server: server,
                client: client,
                playerIndex: playerIndex,
                userID: userID ?? playerIndex,
                className: className
            )
        }
    }

    private func connectWhileLifecycleExclusive(
        server: GMLuaRuntime,
        client: GMLuaRuntime,
        playerIndex: Int,
        userID resolvedUserID: Int,
        className: String
    ) throws {
        guard server.realm == .server, client.realm == .client else {
            throw GMLuaSharedSessionError.invalidRealm(
                server: server.realm,
                client: client.realm
            )
        }
        guard !server.isClosed else {
            throw GMLuaSharedSessionError.closedRuntime(.server)
        }
        guard !client.isClosed else {
            throw GMLuaSharedSessionError.closedRuntime(.client)
        }
        guard playerIndex > 0 else {
            throw GMLuaSharedSessionError.invalidPlayerIndex(playerIndex)
        }
        guard resolvedUserID > 0 else {
            throw GMLuaSharedSessionError.invalidUserID(resolvedUserID)
        }
        guard server.netTransport === netTransport else {
            throw GMLuaSharedSessionError.transportMismatch(.server)
        }
        guard client.netTransport === netTransport else {
            throw GMLuaSharedSessionError.transportMismatch(.client)
        }
        guard let serverRegistry = server.entityRegistry else {
            throw GMLuaSharedSessionError.missingRuntimeSurface(.server, "Entity registry")
        }
        guard let clientRegistry = client.entityRegistry else {
            throw GMLuaSharedSessionError.missingRuntimeSurface(.client, "Entity registry")
        }
        guard let clientEndpoint = client.netEndpoint else {
            throw GMLuaSharedSessionError.missingRuntimeSurface(.client, "net endpoint")
        }
        guard let clientConsole = client.consoleCommandDispatcher else {
            throw GMLuaSharedSessionError.missingRuntimeSurface(.client, "console dispatcher")
        }

        let clientIdentifier = ObjectIdentifier(client)
        let existingRecords: [ConnectionRecord]
        lock.lock()
        if connectionsByClient[clientIdentifier] != nil {
            lock.unlock()
            throw GMLuaSharedSessionError.clientAlreadyConnected
        }
        if clientByPlayerIndex[playerIndex] != nil {
            lock.unlock()
            throw GMLuaSharedSessionError.playerIndexInUse(playerIndex)
        }
        if clientByUserID[resolvedUserID] != nil {
            lock.unlock()
            throw GMLuaSharedSessionError.userIDInUse(resolvedUserID)
        }
        if let existingServer = serverRuntime, existingServer !== server {
            lock.unlock()
            throw GMLuaSharedSessionError.differentServer
        }
        existingRecords = Array(connectionsByClient.values)
        lock.unlock()

        guard !Self.hasLiveEntity(serverRegistry.entity(at: playerIndex)),
              !Self.hasLiveEntity(clientRegistry.entity(at: playerIndex)) else {
            throw GMLuaSharedSessionError.playerIndexInUse(playerIndex)
        }
        guard !Self.hasLiveEntity(serverRegistry.player(forUserID: resolvedUserID)),
              !Self.hasLiveEntity(clientRegistry.player(forUserID: resolvedUserID)) else {
            throw GMLuaSharedSessionError.userIDInUse(resolvedUserID)
        }
        for existing in existingRecords {
            guard let existingRegistry = existing.client?.entityRegistry else {
                throw GMLuaSharedSessionError.missingRuntimeSurface(
                    .client,
                    "Entity registry for Player(\(existing.playerIndex))"
                )
            }
            guard !Self.hasLiveEntity(existingRegistry.entity(at: playerIndex)) else {
                throw GMLuaSharedSessionError.playerIndexInUse(playerIndex)
            }
            guard !Self.hasLiveEntity(existingRegistry.player(forUserID: resolvedUserID)) else {
                throw GMLuaSharedSessionError.userIDInUse(resolvedUserID)
            }
            guard !Self.hasLiveEntity(clientRegistry.entity(at: existing.playerIndex)) else {
                throw GMLuaSharedSessionError.playerIndexInUse(existing.playerIndex)
            }
            guard !Self.hasLiveEntity(clientRegistry.player(forUserID: existing.userID)) else {
                throw GMLuaSharedSessionError.userIDInUse(existing.userID)
            }
        }

        lock.lock()
        // connectionMutationLock serializes lifecycle mutations, so this is a
        // defensive recheck rather than an optimistic race window.
        guard connectionsByClient[clientIdentifier] == nil,
              clientByPlayerIndex[playerIndex] == nil,
              clientByUserID[resolvedUserID] == nil else {
            lock.unlock()
            throw GMLuaSharedSessionError.clientAlreadyConnected
        }
        nextGeneration &+= 1
        let generation = nextGeneration
        let record = ConnectionRecord(
            server: server,
            client: client,
            clientEndpoint: clientEndpoint,
            playerIndex: playerIndex,
            userID: resolvedUserID,
            generation: generation,
            className: className
        )
        connectionsByClient[clientIdentifier] = record
        clientByPlayerIndex[playerIndex] = clientIdentifier
        clientByUserID[resolvedUserID] = clientIdentifier
        serverRuntime = server
        lock.unlock()

        var transportConnected = false
        do {
            _ = try serverRegistry.registerPlayerMirror(
                index: playerIndex,
                generation: generation,
                userID: resolvedUserID,
                className: className
            )
            for existing in existingRecords {
                guard let existingRegistry = existing.client?.entityRegistry else {
                    throw GMLuaSharedSessionError.missingRuntimeSurface(
                        .client,
                        "Entity registry for Player(\(existing.playerIndex))"
                    )
                }
                _ = try clientRegistry.registerPlayerMirror(
                    index: existing.playerIndex,
                    generation: existing.generation,
                    userID: existing.userID,
                    className: existing.className
                )
                _ = try existingRegistry.registerPlayerMirror(
                    index: playerIndex,
                    generation: generation,
                    userID: resolvedUserID,
                    className: className
                )
            }
            _ = try clientRegistry.registerPlayerMirror(
                index: playerIndex,
                generation: generation,
                userID: resolvedUserID,
                className: className
            )
            try clientRegistry.setLocalPlayer(
                index: playerIndex,
                generation: generation
            )
            try netTransport.connectClientEndpoint(
                clientEndpoint,
                playerIndex: playerIndex,
                generation: generation,
                onDisconnect: { [weak self] in
                    self?.cleanupConnection(
                        clientIdentifier: clientIdentifier,
                        generation: generation
                    )
                }
            )
            transportConnected = true
            clientConsole.connectRemoteServer { [weak self, weak clientEndpoint] invocation in
                guard let self, let clientEndpoint else {
                    return .rejected(reason: "shared session is unavailable")
                }
                try self.netTransport.enqueueConsoleCommand(
                    from: clientEndpoint,
                    command: invocation.command,
                    arguments: invocation.arguments
                )
                return .handled
            }
            guard !server.isClosed else {
                throw GMLuaSharedSessionError.closedRuntime(.server)
            }
            guard !client.isClosed else {
                throw GMLuaSharedSessionError.closedRuntime(.client)
            }
        } catch {
            if transportConnected {
                netTransport.disconnectClientEndpoint(clientEndpoint)
            }
            cleanupConnection(
                clientIdentifier: clientIdentifier,
                generation: generation
            )
            throw error
        }
    }

    public func disconnect(client: GMLuaRuntime) throws {
        guard !netTransport.isPumpingOnCurrentThread() else {
            throw GMLuaSharedSessionError.lifecycleDuringPump("disconnect")
        }
        try netTransport.withExclusiveLifecycleBoundary {
            connectionMutationLock.lock()
            defer { connectionMutationLock.unlock() }
            let identifier = ObjectIdentifier(client)
            lock.lock()
            let record = connectionsByClient[identifier]
            lock.unlock()
            guard let record else {
                throw GMLuaSharedSessionError.clientNotConnected
            }
            netTransport.disconnectClientEndpoint(record.clientEndpoint)
        }
    }

    /// Pumps net packets and forwarded console commands in one global FIFO.
    @discardableResult
    public func pump(maxDeliveries: Int = .max) throws -> Int {
        try netTransport.pump(maxDeliveries: maxDeliveries)
    }

    private func cleanupConnection(
        clientIdentifier: ObjectIdentifier,
        generation: UInt64
    ) {
        connectionMutationLock.lock()
        defer { connectionMutationLock.unlock() }
        lock.lock()
        guard let record = connectionsByClient[clientIdentifier],
              record.generation == generation else {
            lock.unlock()
            return
        }
        connectionsByClient.removeValue(forKey: clientIdentifier)
        clientByPlayerIndex.removeValue(forKey: record.playerIndex)
        clientByUserID.removeValue(forKey: record.userID)
        let remainingRecords = Array(connectionsByClient.values)
        let hasConnections = !connectionsByClient.isEmpty
        if !hasConnections { serverRuntime = nil }
        lock.unlock()

        record.client?.consoleCommandDispatcher?.disconnectRemoteServer()
        if let departingRegistry = record.client?.entityRegistry {
            departingRegistry.clearLocalPlayer(
                index: record.playerIndex,
                generation: generation
            )
            departingRegistry.unregisterPlayerMirror(
                index: record.playerIndex,
                generation: generation
            )
            for remaining in remainingRecords {
                departingRegistry.unregisterPlayerMirror(
                    index: remaining.playerIndex,
                    generation: remaining.generation
                )
            }
        }
        for remaining in remainingRecords {
            remaining.client?.entityRegistry?.unregisterPlayerMirror(
                index: record.playerIndex,
                generation: generation
            )
        }
        record.server?.entityRegistry?.unregisterPlayerMirror(
            index: record.playerIndex,
            generation: generation
        )
    }

    private static func hasLiveEntity(_ value: LuaValue) -> Bool {
        GMLuaTypeSystem.typedObject(from: value)?.isValid == true
    }
}
