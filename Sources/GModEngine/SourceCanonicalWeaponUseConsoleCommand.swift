import Foundation

/// Expected user-input failures for Source's `use <weapon_class>` command.
/// These remain values so a console dispatcher can report them without
/// flattening host lifecycle or canonical-state failures into rejections.
public enum SourceCanonicalWeaponUseConsoleRejection:
    Equatable,
    Sendable,
    CustomStringConvertible
{
    case requiresExactlyOneArgument(actualCount: Int)
    case invalidWeaponClassName

    public var description: String {
        switch self {
        case let .requiresExactlyOneArgument(actualCount):
            return "use requires exactly one weapon class argument; " +
                "received \(actualCount)"
        case .invalidWeaponClassName:
            return "use requires a structurally valid weapon class name"
        }
    }
}

/// Typed command ownership result. Only ``rejected(_:)`` is an expected bad
/// command request; thrown errors remain host invariants.
public enum SourceCanonicalWeaponUseConsoleDisposition: Equatable, Sendable {
    case unhandled
    case handled
    case rejected(SourceCanonicalWeaponUseConsoleRejection)

    public var hostDisposition: GMLuaConsoleCommandHostDisposition {
        switch self {
        case .unhandled:
            return .unhandled
        case .handled:
            return .handled
        case let .rejected(rejection):
            return .rejected(reason: rejection.description)
        }
    }
}

/// Errors here describe an incorrectly connected or expired host boundary.
/// Canonical adapter errors intentionally propagate with their concrete type.
public enum SourceCanonicalWeaponUseConsoleHostError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible
{
    case serverRealmRequired(GMLuaRealm)
    case runtimeAdapterReleased

    public var description: String {
        switch self {
        case let .serverRealmRequired(realm):
            return "Source use console host requires SERVER, got \(realm.rawValue)"
        case .runtimeAdapterReleased:
            return "Source use console host lost its canonical runtime adapter"
        }
    }
}

/// Reusable engine-only implementation of Source's `use <weapon_class>`
/// console command. It forwards the exact validated class string to the
/// canonical adapter; it never runs Lua or invents a class fallback.
public enum SourceCanonicalWeaponUseConsoleCommand {
    public static let commandName = "use"

    public static func handle(
        _ invocation: GMLuaConsoleCommandInvocation,
        adapter: GMLuaSourceRuntimeAdapter,
        playerIdentity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalWeaponUseConsoleDisposition {
        guard owns(commandName: invocation.command) else {
            return .unhandled
        }
        guard invocation.realm == .server else {
            throw SourceCanonicalWeaponUseConsoleHostError
                .serverRealmRequired(invocation.realm)
        }
        guard invocation.arguments.count == 1 else {
            return .rejected(.requiresExactlyOneArgument(
                actualCount: invocation.arguments.count
            ))
        }

        let className = invocation.arguments[0]
        guard SourceCanonicalEntityKind
            .isStructurallyValidWeaponClassName(className) else {
            return .rejected(.invalidWeaponClassName)
        }

        // `selectCanonicalWeapon` owns both Source's unowned-class no-op and
        // the full-EHANDLE Player update appended to the replication journal.
        _ = try adapter.selectCanonicalWeapon(
            className: className,
            for: playerIdentity
        )
        return .handled
    }

    /// Produces the existing console dispatcher callback shape without
    /// retaining the adapter through runtime -> dispatcher -> handler.
    public static func makeHostHandler(
        adapter: GMLuaSourceRuntimeAdapter,
        playerIdentity: SourceCanonicalEntityIdentity
    ) -> GMLuaConsoleCommandHostHandler {
        { [weak adapter] invocation in
            guard owns(commandName: invocation.command) else {
                return .unhandled
            }
            guard let adapter else {
                throw SourceCanonicalWeaponUseConsoleHostError
                    .runtimeAdapterReleased
            }
            return try handle(
                invocation,
                adapter: adapter,
                playerIdentity: playerIdentity
            ).hostDisposition
        }
    }

    private static func owns(commandName candidate: String) -> Bool {
        candidate.caseInsensitiveCompare(commandName) == .orderedSame
    }
}
