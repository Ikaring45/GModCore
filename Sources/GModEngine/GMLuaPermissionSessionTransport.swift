import Foundation

/// The two gameplay realms which receive one single-player permission session.
/// MENU remains the sole owner of permission decisions and never appears as a
/// destination in this transport.
public enum GMLuaPermissionSessionDestination: String, Sendable, CaseIterable {
    case server
    case client
}

/// A monotonically increasing identity for one MENU-to-gameplay connection.
/// Values are never reused, including when queueing a connection fails.
public struct GMLuaPermissionSessionGeneration:
    RawRepresentable,
    Hashable,
    Comparable,
    Sendable
{
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (
        lhs: GMLuaPermissionSessionGeneration,
        rhs: GMLuaPermissionSessionGeneration
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Immutable payload placed in the host's existing net/console FIFO.
public struct GMLuaPermissionSessionDelivery: Sendable, Equatable {
    public enum Payload: Sendable, Equatable {
        case connected(
            target: String,
            permissions: GMLuaPermissionSnapshot
        )
        case permissionsChanged(GMLuaPermissionSnapshot)
        case disconnected
    }

    public let generation: GMLuaPermissionSessionGeneration
    public let revision: UInt64
    public let destination: GMLuaPermissionSessionDestination
    public let payload: Payload

    public init(
        generation: GMLuaPermissionSessionGeneration,
        revision: UInt64,
        destination: GMLuaPermissionSessionDestination,
        payload: Payload
    ) {
        self.generation = generation
        self.revision = revision
        self.destination = destination
        self.payload = payload
    }
}

/// Queue-only adapter supplied by the host shared session.
///
/// The closure must append the complete batch atomically to the same deferred
/// FIFO used by net, console and entity replication. It must not synchronously
/// invoke ``GMLuaPermissionSessionTransport/deliver(_:)``. Keeping sequencing
/// ownership in the existing host transport avoids inventing a second event
/// order for permissions.
public struct GMLuaPermissionSharedFIFO: @unchecked Sendable {
    private let enqueueBody: ([GMLuaPermissionSessionDelivery]) throws -> Void

    public init(
        enqueueBatch: @escaping (
            [GMLuaPermissionSessionDelivery]
        ) throws -> Void
    ) {
        enqueueBody = enqueueBatch
    }

    fileprivate func enqueue(
        _ deliveries: [GMLuaPermissionSessionDelivery]
    ) throws {
        try enqueueBody(deliveries)
    }
}

/// Realm-owned consumers for immutable permission deliveries.
public struct GMLuaPermissionSessionEndpoints: @unchecked Sendable {
    private let serverBody: (GMLuaPermissionSessionDelivery) throws -> Void
    private let clientBody: (GMLuaPermissionSessionDelivery) throws -> Void

    public init(
        server: @escaping (
            GMLuaPermissionSessionDelivery
        ) throws -> Void,
        client: @escaping (
            GMLuaPermissionSessionDelivery
        ) throws -> Void
    ) {
        serverBody = server
        clientBody = client
    }

    fileprivate func deliver(
        _ delivery: GMLuaPermissionSessionDelivery
    ) throws {
        switch delivery.destination {
        case .server:
            try serverBody(delivery)
        case .client:
            try clientBody(delivery)
        }
    }
}

public enum GMLuaPermissionSessionTransportError:
    Error,
    Equatable,
    Sendable
{
    case malformedTarget
    case malformedPermissionSnapshot
    case generationExhausted
    case revisionExhausted
}

extension GMLuaPermissionSessionTransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformedTarget:
            return "permission connection target failed validation"
        case .malformedPermissionSnapshot:
            return "permission snapshot failed validation"
        case .generationExhausted:
            return "permission session generation exhausted"
        case .revisionExhausted:
            return "permission session revision exhausted"
        }
    }
}

public enum GMLuaPermissionDeliveryDisposition: Sendable, Equatable {
    case delivered
    case stale
}

/// Generation-safe MENU permission projection for one local shared session.
///
/// Connection and permission mutations only enqueue immutable work. Gameplay
/// realms observe it later when the host pumps the shared transport FIFO. A
/// reconnect immediately invalidates deliveries captured for the previous
/// generation, so a delayed CLIENT or SERVER packet cannot mutate the new
/// session.
public final class GMLuaPermissionSessionTransport: @unchecked Sendable {
    private struct ActiveSession: Equatable {
        var generation: GMLuaPermissionSessionGeneration
        var target: String
        var revision: UInt64
        var permissions: GMLuaPermissionSnapshot
    }

    private struct DestinationState {
        var generation: GMLuaPermissionSessionGeneration?
        var revision: UInt64 = 0
    }

    private let operationLock = NSLock()
    private let stateLock = NSLock()
    private let fifo: GMLuaPermissionSharedFIFO
    private let endpoints: GMLuaPermissionSessionEndpoints

    private var nextGenerationRawValue: UInt64 = 0
    private var activeSession: ActiveSession?
    private var pendingDisconnects:
        [GMLuaPermissionSessionGeneration: Set<GMLuaPermissionSessionDestination>] = [:]
    private var destinationState: [
        GMLuaPermissionSessionDestination: DestinationState
    ] = [
        .server: DestinationState(),
        .client: DestinationState(),
    ]

    public init(
        fifo: GMLuaPermissionSharedFIFO,
        endpoints: GMLuaPermissionSessionEndpoints
    ) {
        self.fifo = fifo
        self.endpoints = endpoints
    }

    public var activeGeneration: GMLuaPermissionSessionGeneration? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeSession?.generation
    }

    public var activeTarget: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeSession?.target
    }

    /// Starts or replaces the local permission projection. SERVER is queued
    /// before CLIENT, matching host construction order, and the two envelopes
    /// enter the shared FIFO as one atomic batch.
    @discardableResult
    public func connect(
        to rawTarget: String,
        permissions rawPermissions: GMLuaPermissionSnapshot
    ) throws -> GMLuaPermissionSessionGeneration {
        operationLock.lock()
        defer { operationLock.unlock() }

        let target = try Self.validatedValue(
            rawTarget,
            maximumLength: 2_048,
            error: .malformedTarget
        )
        let permissions = try Self.validatedSnapshot(rawPermissions)

        stateLock.lock()
        guard nextGenerationRawValue < UInt64.max else {
            stateLock.unlock()
            throw GMLuaPermissionSessionTransportError.generationExhausted
        }
        nextGenerationRawValue += 1
        let generation = GMLuaPermissionSessionGeneration(
            rawValue: nextGenerationRawValue
        )
        let previous = activeSession
        activeSession = ActiveSession(
            generation: generation,
            target: target,
            revision: 0,
            permissions: permissions
        )
        stateLock.unlock()

        let deliveries = Self.destinations.map { destination in
            GMLuaPermissionSessionDelivery(
                generation: generation,
                revision: 0,
                destination: destination,
                payload: .connected(
                    target: target,
                    permissions: permissions
                )
            )
        }
        do {
            try fifo.enqueue(deliveries)
        } catch {
            stateLock.lock()
            if activeSession?.generation == generation {
                activeSession = previous
            }
            stateLock.unlock()
            throw error
        }
        return generation
    }

    /// Queues one new immutable snapshot for both gameplay realms. Mutations
    /// made while no local session is active remain MENU-owned and are carried
    /// by the next connection's initial snapshot.
    @discardableResult
    public func permissionsDidChange(
        to rawPermissions: GMLuaPermissionSnapshot
    ) throws -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }

        let permissions = try Self.validatedSnapshot(rawPermissions)
        stateLock.lock()
        guard var session = activeSession else {
            stateLock.unlock()
            return false
        }
        guard session.revision < UInt64.max else {
            stateLock.unlock()
            throw GMLuaPermissionSessionTransportError.revisionExhausted
        }
        let previousRevision = session.revision
        let previousPermissions = session.permissions
        session.revision += 1
        session.permissions = permissions
        activeSession = session
        stateLock.unlock()

        let deliveries = Self.destinations.map { destination in
            GMLuaPermissionSessionDelivery(
                generation: session.generation,
                revision: session.revision,
                destination: destination,
                payload: .permissionsChanged(permissions)
            )
        }
        do {
            try fifo.enqueue(deliveries)
        } catch {
            stateLock.lock()
            if activeSession?.generation == session.generation,
               activeSession?.revision == session.revision {
                activeSession?.revision = previousRevision
                activeSession?.permissions = previousPermissions
            }
            stateLock.unlock()
            throw error
        }
        return true
    }

    /// Ends the current projection. The generation becomes inactive before
    /// the terminal packet is visible, invalidating any older queued changes.
    @discardableResult
    public func disconnect() throws -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }

        stateLock.lock()
        guard let session = activeSession else {
            stateLock.unlock()
            return false
        }
        activeSession = nil
        pendingDisconnects[session.generation] = []
        stateLock.unlock()

        let deliveries = Self.destinations.map { destination in
            GMLuaPermissionSessionDelivery(
                generation: session.generation,
                revision: session.revision,
                destination: destination,
                payload: .disconnected
            )
        }
        do {
            try fifo.enqueue(deliveries)
        } catch {
            stateLock.lock()
            if activeSession == nil {
                activeSession = session
                pendingDisconnects.removeValue(forKey: session.generation)
            }
            stateLock.unlock()
            throw error
        }
        return true
    }

    /// Called only by the host's FIFO pump. Returns ``stale`` without invoking
    /// a realm when connection generation or permission revision no longer
    /// matches the currently valid session.
    @discardableResult
    public func deliver(
        _ delivery: GMLuaPermissionSessionDelivery
    ) throws -> GMLuaPermissionDeliveryDisposition {
        stateLock.lock()
        let accepted: Bool
        switch delivery.payload {
        case let .connected(target, permissions):
            accepted = acceptConnectionLocked(
                delivery,
                target: target,
                permissions: permissions
            )

        case let .permissionsChanged(permissions):
            accepted = acceptChangeLocked(
                delivery,
                permissions: permissions
            )

        case .disconnected:
            accepted = acceptDisconnectLocked(delivery)
        }
        stateLock.unlock()

        guard accepted else { return .stale }
        try endpoints.deliver(delivery)
        return .delivered
    }

    private func acceptConnectionLocked(
        _ delivery: GMLuaPermissionSessionDelivery,
        target: String,
        permissions: GMLuaPermissionSnapshot
    ) -> Bool {
        guard delivery.revision == 0,
              let session = activeSession,
              session.generation == delivery.generation,
              session.target == target,
              session.permissions == permissions else {
            return false
        }
        destinationState[delivery.destination] = DestinationState(
            generation: delivery.generation,
            revision: 0
        )
        return true
    }

    private func acceptChangeLocked(
        _ delivery: GMLuaPermissionSessionDelivery,
        permissions: GMLuaPermissionSnapshot
    ) -> Bool {
        guard let session = activeSession,
              session.generation == delivery.generation,
              session.revision >= delivery.revision,
              var destination = destinationState[delivery.destination],
              destination.generation == delivery.generation,
              destination.revision < UInt64.max,
              delivery.revision == destination.revision + 1 else {
            return false
        }
        if delivery.revision == session.revision,
           session.permissions != permissions {
            return false
        }
        destination.revision = delivery.revision
        destinationState[delivery.destination] = destination
        return true
    }

    private func acceptDisconnectLocked(
        _ delivery: GMLuaPermissionSessionDelivery
    ) -> Bool {
        guard activeSession == nil,
              pendingDisconnects[delivery.generation] != nil,
              let destination = destinationState[delivery.destination],
              destination.generation == delivery.generation,
              delivery.revision >= destination.revision else {
            return false
        }
        destinationState[delivery.destination] = DestinationState()
        pendingDisconnects[delivery.generation, default: []].insert(
            delivery.destination
        )
        if pendingDisconnects[delivery.generation]?.count
            == Self.destinations.count {
            pendingDisconnects.removeValue(forKey: delivery.generation)
        }
        return true
    }

    private static let destinations: [GMLuaPermissionSessionDestination] = [
        .server,
        .client,
    ]

    private static func validatedSnapshot(
        _ snapshot: GMLuaPermissionSnapshot
    ) throws -> GMLuaPermissionSnapshot {
        GMLuaPermissionSnapshot(
            temporary: try validatedGroup(snapshot.temporary),
            permanent: try validatedGroup(snapshot.permanent)
        )
    }

    private static func validatedGroup(
        _ group: [String: [String]]
    ) throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        for rawServer in group.keys.sorted() {
            let server = try validatedValue(
                rawServer,
                maximumLength: 512,
                error: .malformedPermissionSnapshot
            )
            guard result[server] == nil,
                  let rawPermissions = group[rawServer],
                  !rawPermissions.isEmpty else {
                throw GMLuaPermissionSessionTransportError
                    .malformedPermissionSnapshot
            }
            var seen: Set<String> = []
            var permissions: [String] = []
            for rawPermission in rawPermissions {
                let permission = try validatedValue(
                    rawPermission,
                    maximumLength: 2_048,
                    error: .malformedPermissionSnapshot
                )
                guard seen.insert(permission).inserted else {
                    throw GMLuaPermissionSessionTransportError
                        .malformedPermissionSnapshot
                }
                permissions.append(permission)
            }
            result[server] = permissions.sorted()
        }
        return result
    }

    private static func validatedValue(
        _ rawValue: String,
        maximumLength: Int,
        error: GMLuaPermissionSessionTransportError
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
}
