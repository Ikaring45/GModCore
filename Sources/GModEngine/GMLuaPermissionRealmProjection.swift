import Foundation

/// Immutable gameplay-realm view of the MENU-owned permission connection.
/// SERVER and CLIENT receive separate copies at their normal host-pump
/// boundary; neither realm can mutate the native permission store.
public struct GMLuaPermissionRealmSnapshot: Sendable, Equatable {
    public let target: String
    public let generation: GMLuaPermissionSessionGeneration
    public let revision: UInt64
    public let permissions: GMLuaPermissionSnapshot

    public init(
        target: String,
        generation: GMLuaPermissionSessionGeneration,
        revision: UInt64,
        permissions: GMLuaPermissionSnapshot
    ) {
        self.target = target
        self.generation = generation
        self.revision = revision
        self.permissions = permissions
    }
}

public enum GMLuaPermissionRealmProjectionError:
    Error,
    Equatable,
    Sendable
{
    case wrongDestination(
        expected: GMLuaPermissionSessionDestination,
        received: GMLuaPermissionSessionDestination
    )
    case staleConnection
    case revisionDiscontinuity(expected: UInt64, received: UInt64)
}

/// Realm-owned, read-mostly permission state. All mutations originate from a
/// validated ``GMLuaPermissionSessionTransport`` delivery.
public final class GMLuaPermissionRealmProjection: @unchecked Sendable {
    public let destination: GMLuaPermissionSessionDestination

    private let lock = NSLock()
    private var state: GMLuaPermissionRealmSnapshot?

    public init(destination: GMLuaPermissionSessionDestination) {
        self.destination = destination
    }

    public var snapshot: GMLuaPermissionRealmSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func apply(_ delivery: GMLuaPermissionSessionDelivery) throws {
        guard delivery.destination == destination else {
            throw GMLuaPermissionRealmProjectionError.wrongDestination(
                expected: destination,
                received: delivery.destination
            )
        }
        lock.lock()
        defer { lock.unlock() }
        switch delivery.payload {
        case let .connected(target, permissions):
            guard delivery.revision == 0 else {
                throw GMLuaPermissionRealmProjectionError
                    .revisionDiscontinuity(
                        expected: 0,
                        received: delivery.revision
                    )
            }
            state = GMLuaPermissionRealmSnapshot(
                target: target,
                generation: delivery.generation,
                revision: 0,
                permissions: permissions
            )

        case let .permissionsChanged(permissions):
            guard let current = state,
                  current.generation == delivery.generation else {
                throw GMLuaPermissionRealmProjectionError.staleConnection
            }
            guard current.revision < UInt64.max else {
                throw GMLuaPermissionRealmProjectionError
                    .revisionDiscontinuity(
                        expected: UInt64.max,
                        received: delivery.revision
                    )
            }
            let expected = current.revision + 1
            guard delivery.revision == expected else {
                throw GMLuaPermissionRealmProjectionError
                    .revisionDiscontinuity(
                        expected: expected,
                        received: delivery.revision
                    )
            }
            state = GMLuaPermissionRealmSnapshot(
                target: current.target,
                generation: current.generation,
                revision: delivery.revision,
                permissions: permissions
            )

        case .disconnected:
            guard let current = state,
                  current.generation == delivery.generation else {
                throw GMLuaPermissionRealmProjectionError.staleConnection
            }
            state = nil
        }
    }
}
