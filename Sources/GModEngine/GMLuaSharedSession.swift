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
        /// Transport connection lifetime. This is deliberately independent
        /// from an engine entity's packed EHANDLE generation.
        let connectionGeneration: SourceEntityReplicationConnectionGeneration
        /// Present only for the canonical replication path. Legacy `connect`
        /// remains temporarily available without inventing a Source EHANDLE
        /// for its direct Player mirror.
        let playerIdentity: SourceCanonicalEntityIdentity?
        let legacyPlayerGeneration: UInt64?
        let className: String
        let replicationLease: CanonicalReplicationLease?
        var replicationStream: SourceEntityReplicationServerStream?

        var playerGeneration: UInt64 {
            playerIdentity?.generation ?? legacyPlayerGeneration ?? 0
        }

        var usesCanonicalReplication: Bool { playerIdentity != nil }

        init(
            server: GMLuaRuntime,
            client: GMLuaRuntime,
            clientEndpoint: GMLuaNetEndpoint,
            playerIndex: Int,
            userID: Int,
            connectionGeneration: SourceEntityReplicationConnectionGeneration,
            playerIdentity: SourceCanonicalEntityIdentity? = nil,
            legacyPlayerGeneration: UInt64? = nil,
            className: String,
            replicationLease: CanonicalReplicationLease? = nil,
            replicationStream: SourceEntityReplicationServerStream? = nil
        ) {
            self.server = server
            self.client = client
            self.clientEndpoint = clientEndpoint
            self.playerIndex = playerIndex
            self.userID = userID
            self.connectionGeneration = connectionGeneration
            self.playerIdentity = playerIdentity
            self.legacyPlayerGeneration = legacyPlayerGeneration
            self.className = className
            self.replicationLease = replicationLease
            self.replicationStream = replicationStream
        }
    }

    /// Leaves the endpoint closure harmless after disconnect without adding a
    /// second transport queue or retaining CLIENT registry ownership here.
    private final class CanonicalReplicationLease: @unchecked Sendable {
        private let lock = NSLock()
        private var active = true

        func withActive<Result>(
            _ body: () throws -> Result
        ) throws -> Result {
            lock.lock()
            defer { lock.unlock() }
            guard active else { throw GMLuaSharedSessionError.clientNotConnected }
            return try body()
        }

        func disconnect() {
            lock.lock()
            active = false
            lock.unlock()
        }
    }

    private let connectionMutationLock = NSRecursiveLock()
    private let lock = NSLock()
    private weak var serverRuntime: GMLuaRuntime?
    private var nextConnectionGeneration: UInt64 = 0
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

    /// Publishes one connected player's current Source button word into every
    /// realm-local mirror. The caller supplies the already-decided digital
    /// buttons; this boundary never infers them from analog movement axes.
    public func updatePlayerInputButtons(
        for client: GMLuaRuntime,
        buttons: SourceInputButtons
    ) throws {
        connectionMutationLock.lock()
        defer { connectionMutationLock.unlock() }

        let clientIdentifier = ObjectIdentifier(client)
        let record: ConnectionRecord
        let connectedRecords: [ConnectionRecord]
        lock.lock()
        guard let connected = connectionsByClient[clientIdentifier] else {
            lock.unlock()
            throw GMLuaSharedSessionError.clientNotConnected
        }
        record = connected
        connectedRecords = Array(connectionsByClient.values)
        lock.unlock()

        guard let serverRegistry = record.server?.entityRegistry else {
            throw GMLuaSharedSessionError.missingRuntimeSurface(
                .server,
                "Entity registry for Player(\(record.userID)) input"
            )
        }
        guard serverRegistry.setPlayerInputButtons(
            index: record.playerIndex,
            generation: record.playerGeneration,
            buttons: buttons
        ) else {
            throw GMLuaSharedSessionError.missingRuntimeSurface(
                .server,
                "current Player(\(record.userID)) input mirror"
            )
        }

        // Input buttons are transient host input, not canonical transform,
        // motion, model, or lifecycle state. Keeping this narrow direct mirror
        // preserves KeyDown semantics without letting CLIENT overwrite its
        // replicated Source entity snapshot.
        for connected in connectedRecords {
            guard let registry = connected.client?.entityRegistry else {
                throw GMLuaSharedSessionError.missingRuntimeSurface(
                    .client,
                    "Entity registry for Player(\(record.userID)) input"
                )
            }
            guard registry.setPlayerInputButtons(
                index: record.playerIndex,
                generation: record.playerGeneration,
                buttons: buttons
            ) else {
                throw GMLuaSharedSessionError.missingRuntimeSurface(
                    .client,
                    "current Player(\(record.userID)) input mirror"
                )
            }
        }
    }

    /// Legacy direct-mirror connection retained until PlayableSession has moved
    /// to ``connectCanonical(server:client:playerIdentity:authoritativeSnapshots:)``.
    /// New gameplay integration must use the canonical FIFO path.
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

    /// Connects a CLIENT to an already-authoritative SERVER entity snapshot.
    ///
    /// The SERVER registry must already project the supplied canonical Player;
    /// this session never creates a second identity. The CLIENT replication
    /// state and endpoint handler are armed synchronously, but the snapshot is
    /// only enqueued into the existing net/console/entity FIFO. Therefore
    /// `Entity`, `Player`, and `LocalPlayer` remain unavailable until the host
    /// calls ``pump``. A startup host can perform that pump in its explicit
    /// player-connection stage before dispatching `InitPostEntity`.
    public func connectCanonical(
        server: GMLuaRuntime,
        client: GMLuaRuntime,
        playerIdentity: SourceCanonicalEntityIdentity,
        userID: Int? = nil,
        authoritativeSnapshots: [SourceCanonicalEntitySnapshot]
    ) throws {
        guard !netTransport.isPumpingOnCurrentThread() else {
            throw GMLuaSharedSessionError.lifecycleDuringPump("connect")
        }
        try netTransport.withExclusiveLifecycleBoundary {
            connectionMutationLock.lock()
            defer { connectionMutationLock.unlock() }
            try connectCanonicalWhileLifecycleExclusive(
                server: server,
                client: client,
                playerIdentity: playerIdentity,
                userID: userID ?? playerIdentity.entryIndex,
                authoritativeSnapshots: authoritativeSnapshots
            )
        }
    }

    private func connectCanonicalWhileLifecycleExclusive(
        server: GMLuaRuntime,
        client: GMLuaRuntime,
        playerIdentity: SourceCanonicalEntityIdentity,
        userID: Int,
        authoritativeSnapshots: [SourceCanonicalEntitySnapshot]
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
        let playerIndex = playerIdentity.entryIndex
        guard playerIndex > 0 else {
            throw GMLuaSharedSessionError.invalidPlayerIndex(playerIndex)
        }
        guard userID > 0 else {
            throw GMLuaSharedSessionError.invalidUserID(userID)
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
        guard let serverEndpoint = server.netEndpoint else {
            throw GMLuaSharedSessionError.missingRuntimeSurface(.server, "net endpoint")
        }
        guard let clientEndpoint = client.netEndpoint else {
            throw GMLuaSharedSessionError.missingRuntimeSurface(.client, "net endpoint")
        }
        guard let clientConsole = client.consoleCommandDispatcher else {
            throw GMLuaSharedSessionError.missingRuntimeSurface(.client, "console dispatcher")
        }
        guard authoritativeSnapshots.contains(where: {
            $0.identity == playerIdentity && $0.kind == .player
        }) else {
            throw GMLuaSharedSessionError.missingRuntimeSurface(
                .server,
                "canonical Player snapshot for EHANDLE \(playerIdentity.handle.rawValue)"
            )
        }
        guard serverRegistry.canonicalIdentity(at: playerIndex) == playerIdentity,
              Self.hasLiveEntity(serverRegistry.player(at: playerIndex)),
              serverRegistry.canonicalIdentity(
                  for: serverRegistry.player(forUserID: userID)
              ) == playerIdentity else {
            throw GMLuaSharedSessionError.missingRuntimeSurface(
                .server,
                "authoritative canonical Player EHANDLE \(playerIdentity.handle.rawValue)"
            )
        }

        let clientIdentifier = ObjectIdentifier(client)
        lock.lock()
        if connectionsByClient[clientIdentifier] != nil {
            lock.unlock()
            throw GMLuaSharedSessionError.clientAlreadyConnected
        }
        if clientByPlayerIndex[playerIndex] != nil {
            lock.unlock()
            throw GMLuaSharedSessionError.playerIndexInUse(playerIndex)
        }
        if clientByUserID[userID] != nil {
            lock.unlock()
            throw GMLuaSharedSessionError.userIDInUse(userID)
        }
        if let existingServer = serverRuntime, existingServer !== server {
            lock.unlock()
            throw GMLuaSharedSessionError.differentServer
        }
        lock.unlock()

        guard !Self.hasLiveEntity(clientRegistry.entity(at: playerIndex)),
              !Self.hasLiveEntity(clientRegistry.player(forUserID: userID)) else {
            throw GMLuaSharedSessionError.playerIndexInUse(playerIndex)
        }

        lock.lock()
        guard connectionsByClient[clientIdentifier] == nil,
              clientByPlayerIndex[playerIndex] == nil,
              clientByUserID[userID] == nil else {
            lock.unlock()
            throw GMLuaSharedSessionError.clientAlreadyConnected
        }
        nextConnectionGeneration &+= 1
        let connectionGeneration = SourceEntityReplicationConnectionGeneration(
            rawValue: nextConnectionGeneration
        )
        lock.unlock()

        var stream = try SourceEntityReplicationServerStream(
            connectionGeneration: connectionGeneration
        )
        let initialPacket = try stream.makeSnapshot(authoritativeSnapshots)
        let replicationLease = CanonicalReplicationLease()
        let record = ConnectionRecord(
            server: server,
            client: client,
            clientEndpoint: clientEndpoint,
            playerIndex: playerIndex,
            userID: userID,
            connectionGeneration: connectionGeneration,
            playerIdentity: playerIdentity,
            className: SourceCanonicalEntityKind.player.className,
            replicationLease: replicationLease,
            replicationStream: stream
        )

        lock.lock()
        guard connectionsByClient[clientIdentifier] == nil,
              clientByPlayerIndex[playerIndex] == nil,
              clientByUserID[userID] == nil else {
            lock.unlock()
            throw GMLuaSharedSessionError.clientAlreadyConnected
        }
        connectionsByClient[clientIdentifier] = record
        clientByPlayerIndex[playerIndex] = clientIdentifier
        clientByUserID[userID] = clientIdentifier
        serverRuntime = server
        lock.unlock()

        var transportConnected = false
        do {
            guard try clientRegistry.beginEntityReplication(
                generation: connectionGeneration,
                playerUserIDs: [playerIndex: userID]
            ) else {
                throw GMLuaSharedSessionError.missingRuntimeSurface(
                    .client,
                    "fresh canonical entity replication generation"
                )
            }
            try clientEndpoint.connectEntityReplicationHandler {
                [weak client, clientRegistry] packet in
                try replicationLease.withActive {
                    let identitiesBefore = Set(
                        clientRegistry.canonicalEntitySnapshots.map(\.identity)
                    )
                    let result = try clientRegistry.applyEntityReplicationPacket(
                        packet,
                        beforeRemoving: { entities in
                            guard let client else { return }
                            for entity in entities {
                                _ = client.dispatchContainedHostHook(
                                    named: "EntityRemoved",
                                    arguments: [entity, .boolean(false)]
                                )
                            }
                        }
                    )
                    if case .applied = result,
                       clientRegistry.canonicalIdentity(at: playerIndex) == playerIdentity {
                        try clientRegistry.setLocalPlayer(
                            index: playerIndex,
                            generation: playerIdentity.generation
                        )
                    }
                    if case .applied = result, let client {
                        let newlyNetworked = clientRegistry
                            .canonicalEntitySnapshots
                            .filter {
                                !identitiesBefore.contains($0.identity)
                            }
                        for snapshot in newlyNetworked {
                            let entity = clientRegistry.entity(
                                at: snapshot.identity.entryIndex
                            )
                            _ = client.dispatchContainedHostHook(
                                named: "NetworkEntityCreated",
                                arguments: [entity]
                            )
                        }
                    }
                    return result
                }
            }
            try netTransport.connectClientEndpoint(
                clientEndpoint,
                playerIndex: playerIndex,
                generation: connectionGeneration.rawValue,
                onDisconnect: { [weak self] in
                    self?.cleanupConnection(
                        clientIdentifier: clientIdentifier,
                        connectionGeneration: connectionGeneration
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
            try netTransport.enqueueEntityReplication(
                initialPacket,
                from: serverEndpoint,
                to: clientEndpoint
            )
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
                connectionGeneration: connectionGeneration
            )
            throw error
        }
    }

    /// Enqueues one ordered SERVER entity delta for every canonical CLIENT.
    /// Each connection keeps its own packet sequence while the existing
    /// transport remains the sole global net/console/entity FIFO.
    @discardableResult
    public func publishCanonicalEntityUpdates(
        _ operations: [SourceEntityReplicationOperation]
    ) throws -> Int {
        guard !operations.isEmpty else { return 0 }
        guard !netTransport.isPumpingOnCurrentThread() else {
            throw GMLuaSharedSessionError.lifecycleDuringPump(
                "publish canonical entity updates"
            )
        }
        return try netTransport.withExclusiveLifecycleBoundary {
            connectionMutationLock.lock()
            defer { connectionMutationLock.unlock() }

            let records: [ConnectionRecord]
            lock.lock()
            records = connectionsByClient.values
                .filter(\.usesCanonicalReplication)
                .sorted { $0.playerIndex < $1.playerIndex }
            lock.unlock()

            var sourceEndpoint: GMLuaNetEndpoint?
            var prepared: [(
                record: ConnectionRecord,
                stream: SourceEntityReplicationServerStream,
                request: GMLuaEntityReplicationEnqueueRequest
            )] = []
            prepared.reserveCapacity(records.count)
            for record in records {
                guard let server = record.server, !server.isClosed else {
                    throw GMLuaSharedSessionError.closedRuntime(.server)
                }
                guard let serverEndpoint = server.netEndpoint else {
                    throw GMLuaSharedSessionError.missingRuntimeSurface(
                        .server,
                        "net endpoint for canonical entity replication"
                    )
                }
                if let sourceEndpoint {
                    guard sourceEndpoint === serverEndpoint else {
                        throw GMLuaSharedSessionError.differentServer
                    }
                } else {
                    sourceEndpoint = serverEndpoint
                }
                guard var stream = record.replicationStream else {
                    throw GMLuaSharedSessionError.missingRuntimeSurface(
                        .server,
                        "canonical entity replication stream"
                    )
                }
                let packet = try stream.makeDelta(operations)
                prepared.append((
                    record: record,
                    stream: stream,
                    request: GMLuaEntityReplicationEnqueueRequest(
                        packet: packet,
                        destination: record.clientEndpoint
                    )
                ))
            }
            guard let sourceEndpoint else { return 0 }
            try netTransport.enqueueEntityReplications(
                prepared.map { $0.request },
                from: sourceEndpoint
            )
            for item in prepared {
                item.record.replicationStream = item.stream
            }
            return prepared.count
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
        nextConnectionGeneration &+= 1
        let connectionGeneration = SourceEntityReplicationConnectionGeneration(
            rawValue: nextConnectionGeneration
        )
        let legacyPlayerGeneration = connectionGeneration.rawValue
        let record = ConnectionRecord(
            server: server,
            client: client,
            clientEndpoint: clientEndpoint,
            playerIndex: playerIndex,
            userID: resolvedUserID,
            connectionGeneration: connectionGeneration,
            legacyPlayerGeneration: legacyPlayerGeneration,
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
                generation: legacyPlayerGeneration,
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
                    generation: existing.playerGeneration,
                    userID: existing.userID,
                    className: existing.className
                )
                _ = try existingRegistry.registerPlayerMirror(
                    index: playerIndex,
                    generation: legacyPlayerGeneration,
                    userID: resolvedUserID,
                    className: className
                )
            }
            _ = try clientRegistry.registerPlayerMirror(
                index: playerIndex,
                generation: legacyPlayerGeneration,
                userID: resolvedUserID,
                className: className
            )
            try clientRegistry.setLocalPlayer(
                index: playerIndex,
                generation: legacyPlayerGeneration
            )
            try netTransport.connectClientEndpoint(
                clientEndpoint,
                playerIndex: playerIndex,
                generation: connectionGeneration.rawValue,
                onDisconnect: { [weak self] in
                    self?.cleanupConnection(
                        clientIdentifier: clientIdentifier,
                        connectionGeneration: connectionGeneration
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
                connectionGeneration: connectionGeneration
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

    /// Interactive-host variant that preserves transport/lifecycle failures
    /// while reporting a forwarded SERVER console command body's failure as a
    /// value and continuing through the same deterministic FIFO.
    public func pumpReportingForwardedConsoleFailures(
        maxDeliveries: Int = .max
    ) throws -> GMLuaNetPumpReport {
        try netTransport.pumpReportingForwardedConsoleFailures(
            maxDeliveries: maxDeliveries
        )
    }

    private func cleanupConnection(
        clientIdentifier: ObjectIdentifier,
        connectionGeneration: SourceEntityReplicationConnectionGeneration
    ) {
        connectionMutationLock.lock()
        defer { connectionMutationLock.unlock() }
        lock.lock()
        guard let record = connectionsByClient[clientIdentifier],
              record.connectionGeneration == connectionGeneration else {
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
        record.replicationLease?.disconnect()
        if record.usesCanonicalReplication {
            if let departingRegistry = record.client?.entityRegistry {
                try? departingRegistry.disconnectEntityReplication()
            }
            return
        }

        let playerGeneration = record.playerGeneration
        if let departingRegistry = record.client?.entityRegistry {
            departingRegistry.clearLocalPlayer(
                index: record.playerIndex,
                generation: playerGeneration
            )
            departingRegistry.unregisterPlayerMirror(
                index: record.playerIndex,
                generation: playerGeneration
            )
            for remaining in remainingRecords {
                departingRegistry.unregisterPlayerMirror(
                    index: remaining.playerIndex,
                    generation: remaining.playerGeneration
                )
            }
        }
        for remaining in remainingRecords {
            remaining.client?.entityRegistry?.unregisterPlayerMirror(
                index: record.playerIndex,
                generation: playerGeneration
            )
        }
        record.server?.entityRegistry?.unregisterPlayerMirror(
            index: record.playerIndex,
            generation: playerGeneration
        )
    }

    private static func hasLiveEntity(_ value: LuaValue) -> Bool {
        GMLuaTypeSystem.typedObject(from: value)?.isValid == true
    }
}
