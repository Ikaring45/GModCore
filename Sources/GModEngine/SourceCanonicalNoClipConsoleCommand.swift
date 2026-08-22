import Foundation
import GModLua

public enum SourceCanonicalNoClipConsoleRejection:
    Equatable,
    Sendable,
    CustomStringConvertible
{
    case requiresNoArguments(actualCount: Int)

    public var description: String {
        switch self {
        case let .requiresNoArguments(actualCount):
            return "noclip accepts no arguments; received \(actualCount)"
        }
    }
}

/// A false/nil PlayerNoClip result still owns and handles the console command,
/// but deliberately leaves the canonical Player unchanged.
public enum SourceCanonicalNoClipConsoleDisposition: Equatable, Sendable {
    case unhandled
    case handled(didChange: Bool)
    case rejected(SourceCanonicalNoClipConsoleRejection)

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

/// Engine/lifecycle failures remain typed and distinct from the ordinary Lua
/// permission result. Canonical adapter errors intentionally retain their own
/// concrete types when the final mutation is attempted.
public enum SourceCanonicalNoClipConsoleHostError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible
{
    case serverInvocationRequired(GMLuaRealm)
    case serverRuntimeRequired(GMLuaRealm)
    case runtimeClosed
    case runtimeAdapterReleased
    case canonicalPlayerUnavailable(SourceCanonicalEntityIdentity)
    case canonicalPlayerKindRequired(
        identity: SourceCanonicalEntityIdentity,
        actualKind: SourceCanonicalEntityKind
    )
    case entityRegistryUnavailable
    case canonicalPlayerMirrorUnavailable(SourceCanonicalEntityIdentity)
    case hookTableUnavailable(actualType: String)
    case hookCallUnavailable(actualType: String)
    case gamemodeUnavailable(actualType: String)
    case hookDispatchFailed(reason: String)
    case hookExecutionFailed(reason: String)
    case invalidPermissionResult(actualType: String)

    public var description: String {
        switch self {
        case let .serverInvocationRequired(realm):
            return "Source noclip console invocation requires SERVER, got " +
                realm.rawValue
        case let .serverRuntimeRequired(realm):
            return "Source noclip console host requires SERVER, got " +
                realm.rawValue
        case .runtimeClosed:
            return "Source noclip console host runtime is closed"
        case .runtimeAdapterReleased:
            return "Source noclip console host lost its canonical runtime adapter"
        case let .canonicalPlayerUnavailable(identity):
            return "Source noclip canonical Player EHANDLE " +
                "\(identity.handle.rawValue) is unavailable"
        case let .canonicalPlayerKindRequired(identity, actualKind):
            return "Source noclip EHANDLE \(identity.handle.rawValue) is " +
                "\(actualKind.rawValue), expected player"
        case .entityRegistryUnavailable:
            return "Source noclip SERVER Entity registry is unavailable"
        case let .canonicalPlayerMirrorUnavailable(identity):
            return "Source noclip SERVER Player mirror does not match EHANDLE " +
                "\(identity.handle.rawValue)"
        case let .hookTableUnavailable(actualType):
            return "Source noclip global hook is \(actualType), expected table"
        case let .hookCallUnavailable(actualType):
            return "Source noclip hook.Call is \(actualType), expected function"
        case let .gamemodeUnavailable(actualType):
            return "Source noclip GAMEMODE is \(actualType), expected table"
        case let .hookDispatchFailed(reason):
            return "Source noclip could not resolve hook.Call: \(reason)"
        case let .hookExecutionFailed(reason):
            return "Source noclip PlayerNoClip hook failed: \(reason)"
        case let .invalidPermissionResult(actualType):
            return "Source noclip PlayerNoClip returned \(actualType), " +
                "expected boolean or nil"
        }
    }
}

/// Source-owned `noclip` command. Permission remains owned by the loaded
/// SERVER hook chain and active gamemode; the host only applies the approved
/// walk/noClip transition to the exact canonical Player generation.
public enum SourceCanonicalNoClipConsoleCommand {
    public static let commandName = "noclip"

    public static func handle(
        _ invocation: GMLuaConsoleCommandInvocation,
        adapter: GMLuaSourceRuntimeAdapter,
        playerIdentity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalNoClipConsoleDisposition {
        guard owns(commandName: invocation.command) else {
            return .unhandled
        }
        guard invocation.realm == .server else {
            throw SourceCanonicalNoClipConsoleHostError
                .serverInvocationRequired(invocation.realm)
        }
        guard invocation.arguments.isEmpty else {
            return .rejected(.requiresNoArguments(
                actualCount: invocation.arguments.count
            ))
        }

        let runtime = adapter.serverRuntime
        guard runtime.realm == .server else {
            throw SourceCanonicalNoClipConsoleHostError
                .serverRuntimeRequired(runtime.realm)
        }
        guard !runtime.isClosed else {
            throw SourceCanonicalNoClipConsoleHostError.runtimeClosed
        }
        guard let player = adapter.canonicalSnapshot(for: playerIdentity) else {
            throw SourceCanonicalNoClipConsoleHostError
                .canonicalPlayerUnavailable(playerIdentity)
        }
        guard player.kind == .player else {
            throw SourceCanonicalNoClipConsoleHostError
                .canonicalPlayerKindRequired(
                    identity: player.identity,
                    actualKind: player.kind
                )
        }

        let requestedOn = player.moveType != .noClip
        guard try permission(
            runtime: runtime,
            playerIdentity: playerIdentity,
            requestedOn: requestedOn
        ) else {
            return .handled(didChange: false)
        }

        _ = try adapter.updateCanonicalEntity(playerIdentity) { candidate in
            candidate.moveType = requestedOn ? .noClip : .walk
        }
        return .handled(didChange: true)
    }

    public static func makeHostHandler(
        adapter: GMLuaSourceRuntimeAdapter,
        playerIdentity: SourceCanonicalEntityIdentity
    ) -> GMLuaConsoleCommandHostHandler {
        { [weak adapter] invocation in
            guard owns(commandName: invocation.command) else {
                return .unhandled
            }
            guard let adapter else {
                throw SourceCanonicalNoClipConsoleHostError
                    .runtimeAdapterReleased
            }
            return try handle(
                invocation,
                adapter: adapter,
                playerIdentity: playerIdentity
            ).hostDisposition
        }
    }

    private static func permission(
        runtime: GMLuaRuntime,
        playerIdentity: SourceCanonicalEntityIdentity,
        requestedOn: Bool
    ) throws -> Bool {
        guard let registry = runtime.entityRegistry else {
            throw SourceCanonicalNoClipConsoleHostError
                .entityRegistryUnavailable
        }
        let player = registry.player(at: playerIdentity.entryIndex)
        guard registry.canonicalIdentity(for: player) == playerIdentity else {
            throw SourceCanonicalNoClipConsoleHostError
                .canonicalPlayerMirrorUnavailable(playerIdentity)
        }
        let state = runtime.state
        let rawHook = state.getGlobal("hook")
        guard case let .table(hook) = rawHook else {
            throw SourceCanonicalNoClipConsoleHostError
                .hookTableUnavailable(actualType: rawHook.typeName)
        }

        let call: LuaValue
        do {
            call = try state.rawTableValue(for: .string("Call"), in: hook)
        } catch {
            throw SourceCanonicalNoClipConsoleHostError.hookDispatchFailed(
                reason: GMLuaRuntime.describe(error)
            )
        }
        switch call {
        case .luaFunction, .nativeFunction:
            break
        default:
            throw SourceCanonicalNoClipConsoleHostError
                .hookCallUnavailable(actualType: call.typeName)
        }

        let gamemode = state.getGlobal("GAMEMODE")
        guard case .table = gamemode else {
            throw SourceCanonicalNoClipConsoleHostError
                .gamemodeUnavailable(actualType: gamemode.typeName)
        }
        let values: [LuaValue]
        do {
            values = try state.call(
                call,
                arguments: [
                    .string(LuaString("PlayerNoClip")),
                    gamemode,
                    player,
                    .boolean(requestedOn),
                ]
            )
        } catch {
            throw SourceCanonicalNoClipConsoleHostError.hookExecutionFailed(
                reason: GMLuaRuntime.describe(error)
            )
        }

        switch values.first ?? .nilValue {
        case let .boolean(allowed):
            return allowed
        case .nilValue:
            return false
        default:
            throw SourceCanonicalNoClipConsoleHostError
                .invalidPermissionResult(
                    actualType: (values.first ?? .nilValue).typeName
                )
        }
    }

    private static func owns(commandName candidate: String) -> Bool {
        candidate.caseInsensitiveCompare(commandName) == .orderedSame
    }
}
