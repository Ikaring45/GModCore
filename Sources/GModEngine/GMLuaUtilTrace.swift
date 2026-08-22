import Foundation
import GModLua

/// Shape selected by the GLua entry point. A zero-sized hull remains a hull
/// request even though Source's `Ray_t` classifies its geometry as a ray.
public enum GMLuaTraceKind: String, Equatable, Sendable {
    case line
    case hull
}

/// State-free request passed from a realm-local Lua runtime to its host trace
/// provider. It contains scalar Source values and a packed Entity identity,
/// never Lua userdata from the calling realm.
public struct GMLuaTraceRequest: Equatable, Sendable {
    public let kind: GMLuaTraceKind
    public let ray: SourceRay
    public let mask: SourceContents
    public let worldIdentity: GMLuaSourceEntityIdentity
    /// Caller collision group passed to the host's real game-rules policy.
    /// The utility layer does not guess a collision matrix.
    public let collisionGroup: Int32
    /// Complete realm-local handles named by an Entity/table filter. The BSP
    /// provider has no dynamic candidates, so these do not alter its world
    /// result; a later dynamic provider can apply them without reparsing Lua.
    public let excludedEntityHandles: [SourceBaseHandle]
    /// Complete handles selected by an Entity/table whitelist. Empty means no
    /// whitelist, not an empty whitelist; the parsed filter retains that
    /// distinction inside the realm-local bridge.
    public let includedEntityHandles: [SourceBaseHandle]

    init(
        kind: GMLuaTraceKind,
        ray: SourceRay,
        mask: SourceContents,
        worldIdentity: GMLuaSourceEntityIdentity,
        collisionGroup: Int32 = 0,
        excludedEntityHandles: [SourceBaseHandle],
        includedEntityHandles: [SourceBaseHandle] = []
    ) {
        self.kind = kind
        self.ray = ray
        self.mask = mask
        self.worldIdentity = worldIdentity
        self.collisionGroup = collisionGroup
        self.excludedEntityHandles = excludedEntityHandles
        self.includedEntityHandles = includedEntityHandles
    }
}

/// Host boundary for `util.TraceLine` and `util.TraceHull`.
///
/// Existing implementations may remain world-only. A
/// ``GMLuaDynamicTraceCandidateProvider`` can be composed with one through
/// ``GMLuaCompositeTraceProvider`` without changing this BSP contract.
public protocol GMLuaTraceProvider: Sendable {
    var isWorldReady: Bool { get }
    func traceWorld(_ request: GMLuaTraceRequest) throws -> SourceGameTrace
}

public enum GMLuaTraceBridgeError: Error, Equatable, CustomStringConvertible {
    case providerUnavailable
    case worldNotReady
    case dynamicWorldNotReady
    case canonicalWorldUnavailable
    case staleWorldIdentity(expected: UInt32, actual: UInt32)
    case hitMissingWorldIdentity
    case unsupportedNonWorldIdentity(Int)
    case dynamicEntityUnavailable(UInt32)
    case inconsistentMissIdentity(UInt32)
    case nonFiniteProviderResult(String)

    public var description: String {
        switch self {
        case .providerUnavailable:
            return "no world trace provider is connected"
        case .worldNotReady:
            return "the trace provider's world is not ready"
        case .dynamicWorldNotReady:
            return "the dynamic trace provider is not ready"
        case .canonicalWorldUnavailable:
            return "canonical Source Entity(0) world mirror is unavailable"
        case let .staleWorldIdentity(expected, actual):
            return "trace returned stale Entity(0) generation \(actual); expected \(expected)"
        case .hitMissingWorldIdentity:
            return "world trace reported a hit without an Entity(0) identity"
        case let .unsupportedNonWorldIdentity(index):
            return "dynamic entity trace hit at index \(index) is not implemented"
        case let .dynamicEntityUnavailable(rawValue):
            return "dynamic trace returned unavailable EHANDLE \(rawValue)"
        case let .inconsistentMissIdentity(rawValue):
            return "trace miss unexpectedly carried entity handle \(rawValue)"
        case let .nonFiniteProviderResult(field):
            return "trace provider returned a non-finite \(field)"
        }
    }
}

/// Mutable runtime handoff for installing a map after Lua construction.
/// Provider replacement is synchronized; tracing itself runs outside the lock.
public final class GMLuaTraceBridge: @unchecked Sendable {
    /// Inputs that are rejected unless they retain the documented defaults.
    public static let unavailableInputCapabilities = [
        "string filter", "ignoreworld", "hitclientonly",
    ]

    /// BSP collision currently has no texture-name, surface-property-table, or
    /// material-type resolver. These fields are removed from output tables so
    /// a reused table cannot expose stale or fabricated metadata.
    public static let unavailableResultFields = [
        "HitTexture", "SurfaceProps", "MatType",
    ]

    private let lock = NSLock()
    private var provider: (any GMLuaTraceProvider)?

    public init(provider: (any GMLuaTraceProvider)? = nil) {
        self.provider = provider
    }

    public var hasProvider: Bool {
        lock.lock()
        defer { lock.unlock() }
        return provider != nil
    }

    public func connect(provider: any GMLuaTraceProvider) {
        lock.lock()
        self.provider = provider
        lock.unlock()
    }

    public func disconnectProvider() {
        lock.lock()
        provider = nil
        lock.unlock()
    }

    fileprivate func trace(
        _ request: GMLuaTraceRequest,
        shouldHitDynamicEntity: (GMLuaDynamicTraceCandidate) throws -> Bool
    ) throws -> SourceGameTrace {
        let current = try readyProvider()
        var result = try current.traceWorld(request)
        try validateWorldIdentity(result, request: request)
        guard let dynamic = current as? any GMLuaDynamicTraceCandidateProvider else {
            return result
        }
        guard dynamic.isDynamicTraceReady else {
            throw GMLuaTraceBridgeError.dynamicWorldNotReady
        }
        let candidates = try dynamic.dynamicTraceCandidates(for: request)
            .sorted {
                $0.identity.handle.rawValue < $1.identity.handle.rawValue
            }
        for candidate in candidates {
            guard dynamic.shouldCollide(
                queryCollisionGroup: request.collisionGroup,
                candidateCollisionGroup: candidate.collisionGroup
            ), try shouldHitDynamicEntity(candidate) else { continue }
            let candidateTrace = try GMLuaDynamicTraceEngine.trace(
                request,
                candidate: candidate
            )
            guard candidateTrace.didHit else { continue }
            GMLuaDynamicTraceEngine.merge(candidateTrace, into: &result)
        }
        return result
    }

    private func validateWorldIdentity(
        _ trace: SourceGameTrace,
        request: GMLuaTraceRequest
    ) throws {
        guard trace.fraction.isFinite else {
            throw GMLuaTraceBridgeError.nonFiniteProviderResult("Fraction")
        }
        if trace.didHit {
            guard let handle = trace.entityHandle else {
                throw GMLuaTraceBridgeError.hitMissingWorldIdentity
            }
            guard handle.entryIndex == 0 else {
                throw GMLuaTraceBridgeError
                    .unsupportedNonWorldIdentity(handle.entryIndex)
            }
            guard handle == request.worldIdentity.handle else {
                throw GMLuaTraceBridgeError.staleWorldIdentity(
                    expected: request.worldIdentity.handle.rawValue,
                    actual: handle.rawValue
                )
            }
        } else if let handle = trace.entityHandle {
            throw GMLuaTraceBridgeError
                .inconsistentMissIdentity(handle.rawValue)
        }
    }

    fileprivate func ensureWorldReady() throws {
        _ = try readyProvider()
    }

    private func readyProvider() throws -> any GMLuaTraceProvider {
        lock.lock()
        let current = provider
        lock.unlock()
        guard let current else {
            throw GMLuaTraceBridgeError.providerUnavailable
        }
        guard current.isWorldReady else {
            throw GMLuaTraceBridgeError.worldNotReady
        }
        return current
    }
}

/// Immutable Source BSP world provider. The BSP collision core labels brushes
/// with a placeholder index-zero handle; this boundary replaces that handle
/// with the exact adapter-owned Entity(0) generation supplied per call.
/// Dynamic entities and displacement collision meshes are not represented by
/// `SourceBSP.traceWorld`; `DispFlags` is only passed through when a provider
/// has real displacement data, and is therefore zero for this BSP provider.
public struct GMLuaSourceBSPTraceProvider: GMLuaTraceProvider, Sendable {
    public let bsp: SourceBSP
    public let tolerance: Float

    public init(
        bsp: SourceBSP,
        tolerance: Float = SourceCollisionConstants.distanceEpsilon
    ) {
        self.bsp = bsp
        self.tolerance = tolerance
    }

    public init(
        data: Data,
        versionPolicy: SourceBSPVersionPolicy = .verifiedSourceSDK2013,
        tolerance: Float = SourceCollisionConstants.distanceEpsilon
    ) throws {
        self.init(
            bsp: try SourceBSP(data: data, versionPolicy: versionPolicy),
            tolerance: tolerance
        )
    }

    public var isWorldReady: Bool { true }

    public func traceWorld(_ request: GMLuaTraceRequest) throws -> SourceGameTrace {
        var result = try bsp.traceWorld(
            request.ray,
            mask: request.mask,
            tolerance: tolerance
        )
        if result.didHit {
            result.entityHandle = request.worldIdentity.handle
        } else {
            result.entityHandle = nil
        }
        return result
    }
}

/// Installs the shared `util.TraceLine` / `util.TraceHull` surface. The binding
/// is available before a world is connected, but such calls fail explicitly;
/// the runtime does not manufacture a successful miss during map loading.
public enum GMLuaUtilTrace {
    private static let signedContentsConstants: [(String, SourceContents)] = [
        ("CONTENTS_EMPTY", .empty),
        ("CONTENTS_SOLID", .solid),
        ("CONTENTS_WINDOW", .window),
        ("CONTENTS_AUX", .auxiliary),
        ("CONTENTS_GRATE", .grate),
        ("CONTENTS_SLIME", .slime),
        ("CONTENTS_WATER", .water),
        ("CONTENTS_BLOCKLOS", .blockLineOfSight),
        ("CONTENTS_OPAQUE", .opaque),
        ("CONTENTS_TESTFOGVOLUME", .testFogVolume),
        ("CONTENTS_UNUSED", .unused),
        ("CONTENTS_UNUSED6", .unused6),
        ("CONTENTS_TEAM1", .team1),
        ("CONTENTS_TEAM2", .team2),
        ("CONTENTS_IGNORE_NODRAW_OPAQUE", .ignoreNoDrawOpaque),
        ("CONTENTS_MOVEABLE", .moveable),
        ("CONTENTS_AREAPORTAL", .areaPortal),
        ("CONTENTS_PLAYERCLIP", .playerClip),
        ("CONTENTS_MONSTERCLIP", .monsterClip),
        ("CONTENTS_CURRENT_0", .current0),
        ("CONTENTS_CURRENT_90", .current90),
        ("CONTENTS_CURRENT_180", .current180),
        ("CONTENTS_CURRENT_270", .current270),
        ("CONTENTS_CURRENT_UP", .currentUp),
        ("CONTENTS_CURRENT_DOWN", .currentDown),
        ("CONTENTS_ORIGIN", .origin),
        ("CONTENTS_MONSTER", .monster),
        ("CONTENTS_DEBRIS", .debris),
        ("CONTENTS_DETAIL", .detail),
        ("CONTENTS_TRANSLUCENT", .translucent),
        ("CONTENTS_LADDER", .ladder),
        ("CONTENTS_HITBOX", .hitbox),
    ]

    private static let signedMaskConstants: [(String, SourceContents)] = [
        ("MASK_ALL", SourceMasks.all),
        ("MASK_SOLID", SourceMasks.solid),
        ("MASK_PLAYERSOLID", SourceMasks.playerSolid),
        ("MASK_NPCSOLID", SourceMasks.npcSolid),
        ("MASK_WATER", SourceMasks.water),
        ("MASK_OPAQUE", SourceMasks.opaque),
        ("MASK_OPAQUE_AND_NPCS", SourceMasks.opaqueAndNPCs),
        ("MASK_BLOCKLOS", SourceMasks.blockLineOfSight),
        ("MASK_BLOCKLOS_AND_NPCS", SourceMasks.blockLineOfSightAndNPCs),
        ("MASK_VISIBLE", SourceMasks.visible),
        ("MASK_VISIBLE_AND_NPCS", SourceMasks.visibleAndNPCs),
        ("MASK_SHOT", SourceMasks.shot),
        ("MASK_SHOT_HULL", SourceMasks.shotHull),
        ("MASK_SHOT_PORTAL", SourceMasks.shotPortal),
        ("MASK_SOLID_BRUSHONLY", SourceMasks.solidBrushOnly),
        ("MASK_PLAYERSOLID_BRUSHONLY", SourceMasks.playerSolidBrushOnly),
        ("MASK_NPCSOLID_BRUSHONLY", SourceMasks.npcSolidBrushOnly),
        ("MASK_NPCWORLDSTATIC", SourceMasks.npcWorldStatic),
        ("MASK_SPLITAREAPORTAL", SourceMasks.splitAreaPortal),
        ("MASK_CURRENT", SourceMasks.current),
        ("MASK_DEADSOLID", SourceMasks.deadSolid),
    ]

    @discardableResult
    public static func install(
        into state: LuaState,
        typeSystem: GMLuaTypeSystem,
        entityRegistry: GMLuaEntityRegistry,
        provider: (any GMLuaTraceProvider)? = nil
    ) throws -> GMLuaTraceBridge {
        let bridge = GMLuaTraceBridge(provider: provider)
        let utilTable: LuaTable
        if case let .table(existing) = state.getGlobal("util") {
            utilTable = existing
        } else {
            utilTable = LuaTable()
        }

        try installFunction(
            "TraceLine",
            kind: .line,
            into: utilTable,
            state: state,
            typeSystem: typeSystem,
            entityRegistry: entityRegistry,
            bridge: bridge
        )
        try installFunction(
            "TraceHull",
            kind: .hull,
            into: utilTable,
            state: state,
            typeSystem: typeSystem,
            entityRegistry: entityRegistry,
            bridge: bridge
        )
        state.setGlobal("util", value: .table(utilTable))

        for (name, mask) in signedContentsConstants + signedMaskConstants {
            state.setGlobal(
                name,
                value: .number(Double(Int32(bitPattern: mask.rawValue)))
            )
        }
        state.setGlobal("COLLISION_GROUP_NONE", value: .number(0))
        return bridge
    }

    private static func installFunction(
        _ shortName: String,
        kind: GMLuaTraceKind,
        into utilTable: LuaTable,
        state: LuaState,
        typeSystem: GMLuaTypeSystem,
        entityRegistry: GMLuaEntityRegistry,
        bridge: GMLuaTraceBridge
    ) throws {
        let functionName = "util.\(shortName)"
        let function = LuaNativeFunctionBox(
            { [unowned state, weak typeSystem, weak entityRegistry, bridge] arguments in
                guard let typeSystem, let entityRegistry else {
                    throw LuaError.runtime("\(functionName) runtime surface is unavailable")
                }
                let configuration = try tableArgument(arguments, function: functionName)
                let parsed = try parseConfiguration(
                    configuration,
                    kind: kind,
                    function: functionName,
                    state: state,
                    entityRegistry: entityRegistry
                )

                // Resolve Entity(0) only after validating the request and the
                // provider, then revalidate it after the host call. A stale
                // generation is never returned to Lua as a successful hit.
                do {
                    try bridge.ensureWorldReady()
                } catch {
                    throw LuaError.runtime(
                        "\(functionName) failed: \(String(describing: error))"
                    )
                }
                let worldValue = entityRegistry.entity(at: 0)
                guard let worldIdentity =
                        entityRegistry.canonicalIdentity(for: worldValue) ??
                        entityRegistry.sourceMirrorIdentity(for: worldValue) else {
                    throw LuaError.runtime(
                        "\(functionName) failed: \(GMLuaTraceBridgeError.canonicalWorldUnavailable)"
                    )
                }
                let request = GMLuaTraceRequest(
                    kind: kind,
                    ray: parsed.ray,
                    mask: parsed.mask,
                    worldIdentity: worldIdentity,
                    collisionGroup: parsed.collisionGroup,
                    excludedEntityHandles: parsed.filter.excludedHandles,
                    includedEntityHandles: parsed.filter.includedHandles
                )

                let trace: SourceGameTrace
                do {
                    trace = try bridge.trace(request) { candidate in
                        let entityValue = try GMLuaUtilTrace.dynamicEntityValue(
                            for: candidate.identity.handle,
                            registry: entityRegistry,
                            function: functionName
                        )
                        return try parsed.filter.shouldHit(
                            candidate: candidate,
                            entityValue: entityValue,
                            state: state,
                            function: functionName
                        )
                    }
                } catch {
                    throw LuaError.runtime("\(functionName) failed: \(String(describing: error))")
                }
                guard (entityRegistry.canonicalIdentity(for: worldValue) ??
                        entityRegistry.sourceMirrorIdentity(for: worldValue)) == worldIdentity else {
                    throw LuaError.runtime(
                        "\(functionName) failed: Entity(0) changed during the trace"
                    )
                }
                do {
                    try validateProviderResult(
                        trace,
                        request: request,
                        entityRegistry: entityRegistry
                    )
                } catch {
                    throw LuaError.runtime("\(functionName) failed: \(String(describing: error))")
                }

                let hitEntityValue: LuaValue
                if let handle = trace.entityHandle, trace.didHit {
                    if handle.entryIndex == 0 {
                        hitEntityValue = worldValue
                    } else {
                        hitEntityValue = try GMLuaUtilTrace.dynamicEntityValue(
                            for: handle,
                            registry: entityRegistry,
                            function: functionName
                        )
                    }
                } else {
                    hitEntityValue = state.getGlobal("NULL")
                }

                let result = parsed.output ?? LuaTable()
                try writeResult(
                    trace,
                    hitEntityValue: hitEntityValue,
                    result: result,
                    state: state,
                    typeSystem: typeSystem
                )
                guard (entityRegistry.canonicalIdentity(for: worldValue) ??
                        entityRegistry.sourceMirrorIdentity(for: worldValue)) == worldIdentity else {
                    throw LuaError.runtime(
                        "\(functionName) failed: Entity(0) changed while writing the trace result"
                    )
                }
                if let handle = trace.entityHandle,
                   handle.entryIndex != 0,
                   trace.didHit {
                    _ = try GMLuaUtilTrace.dynamicEntityValue(
                        for: handle,
                        registry: entityRegistry,
                        function: functionName
                    )
                }
                return [.table(result)]
            },
            debugName: functionName
        )
        try state.setRawTableValue(
            .nativeFunction(function),
            for: .string(LuaString(shortName)),
            in: utilTable
        )
    }

    private struct ParsedConfiguration {
        let ray: SourceRay
        let mask: SourceContents
        let collisionGroup: Int32
        let filter: ParsedFilter
        let output: LuaTable?
    }

    private enum ParsedFilter {
        case none
        case entities(handles: Set<SourceBaseHandle>, whitelist: Bool)
        case function(LuaValue)

        var excludedHandles: [SourceBaseHandle] {
            guard case let .entities(handles, false) = self else { return [] }
            return handles.sorted { $0.rawValue < $1.rawValue }
        }

        var includedHandles: [SourceBaseHandle] {
            guard case let .entities(handles, true) = self else { return [] }
            return handles.sorted { $0.rawValue < $1.rawValue }
        }

        func shouldHit(
            candidate: GMLuaDynamicTraceCandidate,
            entityValue: LuaValue,
            state: LuaState,
            function: String
        ) throws -> Bool {
            switch self {
            case .none:
                return true
            case let .entities(handles, whitelist):
                let contains = handles.contains(candidate.identity.handle)
                return whitelist ? contains : !contains
            case let .function(callback):
                let values = try state.call(callback, arguments: [entityValue])
                return values.first?.isTruthy ?? false
            }
        }
    }

    private static func parseConfiguration(
        _ table: LuaTable,
        kind: GMLuaTraceKind,
        function: String,
        state: LuaState,
        entityRegistry: GMLuaEntityRegistry
    ) throws -> ParsedConfiguration {
        let start = try vectorField(
            "start",
            in: table,
            defaultValue: .zero,
            function: function,
            state: state
        )
        let end = try vectorField(
            "endpos",
            in: table,
            defaultValue: .zero,
            function: function,
            state: state
        )
        let ray: SourceRay
        switch kind {
        case .line:
            try validateLineGeometry(start: start, end: end, function: function)
            ray = SourceRay(start: start, end: end)
        case .hull:
            let mins = try requiredVectorField(
                "mins",
                in: table,
                function: function,
                state: state
            )
            let maxs = try requiredVectorField(
                "maxs",
                in: table,
                function: function,
                state: state
            )
            guard mins.x <= maxs.x, mins.y <= maxs.y, mins.z <= maxs.z else {
                throw LuaError.runtime(
                    "\(function) field 'mins' must not exceed 'maxs' on any axis"
                )
            }
            try validateHullGeometry(
                start: start,
                end: end,
                mins: mins,
                maxs: maxs,
                function: function
            )
            ray = SourceRay(start: start, end: end, mins: mins, maxs: maxs)
        }

        let mask = try maskField(in: table, function: function, state: state)
        let whitelist = try optionalBooleanField(
            "whitelist",
            defaultValue: false,
            in: table,
            function: function,
            state: state
        )
        let filter = try filterField(
            in: table,
            function: function,
            state: state,
            entityRegistry: entityRegistry,
            whitelist: whitelist
        )
        let collisionGroup = try parseSupportedInputs(
            in: table,
            function: function,
            state: state
        )
        return ParsedConfiguration(
            ray: ray,
            mask: mask,
            collisionGroup: collisionGroup,
            filter: filter,
            output: try outputField(in: table, function: function, state: state)
        )
    }

    private static func tableArgument(
        _ arguments: [LuaValue],
        function: String
    ) throws -> LuaTable {
        guard let first = arguments.first, case let .table(table) = first else {
            throw LuaError.runtime(
                "bad argument #1 to '\(function)' (table expected, got \(arguments.first?.typeName ?? "no value"))"
            )
        }
        return table
    }

    private static func rawField(
        _ name: String,
        in table: LuaTable,
        state: LuaState
    ) throws -> LuaValue {
        try state.rawTableValue(for: .string(LuaString(name)), in: table)
    }

    private static func vectorField(
        _ name: String,
        in table: LuaTable,
        defaultValue: SourceVector3,
        function: String,
        state: LuaState
    ) throws -> SourceVector3 {
        let value = try rawField(name, in: table, state: state)
        if case .nilValue = value { return defaultValue }
        return try sourceVector(value, field: name, function: function)
    }

    private static func requiredVectorField(
        _ name: String,
        in table: LuaTable,
        function: String,
        state: LuaState
    ) throws -> SourceVector3 {
        let value = try rawField(name, in: table, state: state)
        guard case .nilValue = value else {
            return try sourceVector(value, field: name, function: function)
        }
        throw LuaError.runtime("\(function) requires Vector field '\(name)'")
    }

    private static func sourceVector(
        _ value: LuaValue,
        field: String,
        function: String
    ) throws -> SourceVector3 {
        let components: (Double, Double, Double)
        do {
            components = try GMLuaVectorAngle.networkVectorComponents(
                from: value,
                function: "\(function) field '\(field)'"
            )
        } catch {
            throw error
        }
        return SourceVector3(
            try sourceFloat(components.0, field: "\(field).x", function: function),
            try sourceFloat(components.1, field: "\(field).y", function: function),
            try sourceFloat(components.2, field: "\(field).z", function: function)
        )
    }

    private static func sourceFloat(
        _ number: Double,
        field: String,
        function: String
    ) throws -> Float {
        let limit = Double(Float.greatestFiniteMagnitude)
        guard number.isFinite, number >= -limit, number <= limit else {
            throw LuaError.runtime(
                "\(function) field '\(field)' must be a finite Source Float"
            )
        }
        let value = Float(number)
        guard value.isFinite else {
            throw LuaError.runtime(
                "\(function) field '\(field)' is outside Source Float range"
            )
        }
        return value
    }

    private static func validateLineGeometry(
        start: SourceVector3,
        end: SourceVector3,
        function: String
    ) throws {
        let delta = end - start
        guard finite(delta), delta.lengthSquared.isFinite else {
            throw LuaError.runtime("\(function) start/end delta exceeds Source Float range")
        }
    }

    private static func validateHullGeometry(
        start: SourceVector3,
        end: SourceVector3,
        mins: SourceVector3,
        maxs: SourceVector3,
        function: String
    ) throws {
        let delta = end - start
        let extents = (maxs - mins) * Float(0.5)
        let center = (mins + maxs) * Float(0.5)
        guard finite(delta), delta.lengthSquared.isFinite,
              finite(extents), extents.lengthSquared.isFinite,
              finite(center), finite(start + center), finite(end + center) else {
            throw LuaError.runtime("\(function) hull geometry exceeds Source Float range")
        }
    }

    private static func finite(_ value: SourceVector3) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }

    private static func maskField(
        in table: LuaTable,
        function: String,
        state: LuaState
    ) throws -> SourceContents {
        let value = try rawField("mask", in: table, state: state)
        if case .nilValue = value { return SourceMasks.solid }
        guard case let .number(number) = value,
              number.isFinite,
              number.rounded(.towardZero) == number,
              number >= Double(Int32.min),
              number <= Double(UInt32.max) else {
            throw LuaError.runtime(
                "\(function) field 'mask' must be an exact signed/unsigned 32-bit integer"
            )
        }
        let rawValue: UInt32
        if number <= Double(Int32.max) {
            rawValue = UInt32(bitPattern: Int32(number))
        } else {
            rawValue = UInt32(number)
        }
        return SourceContents(rawValue: rawValue)
    }

    private static func parseSupportedInputs(
        in table: LuaTable,
        function: String,
        state: LuaState
    ) throws -> Int32 {
        let collisionGroup = try optionalInt32Field(
            "collisiongroup",
            defaultValue: 0,
            in: table,
            function: function,
            state: state
        )
        for name in ["ignoreworld", "hitclientonly"] {
            let enabled = try optionalBooleanField(
                name,
                defaultValue: false,
                in: table,
                function: function,
                state: state
            )
            guard !enabled else {
                throw LuaError.runtime(
                    "\(function) field '\(name)' is not supported by world-only tracing"
                )
            }
        }
        return collisionGroup
    }

    /// Entity/table filters keep complete EHANDLE generations. Function filters
    /// stay realm-local and are invoked only for live dynamic candidates; Lua
    /// userdata never enters the provider request.
    private static func filterField(
        in table: LuaTable,
        function: String,
        state: LuaState,
        entityRegistry: GMLuaEntityRegistry,
        whitelist: Bool
    ) throws -> ParsedFilter {
        let value = try rawField("filter", in: table, state: state)
        if case .nilValue = value {
            return whitelist
                ? .entities(handles: [], whitelist: true)
                : .none
        }

        switch value {
        case .luaFunction, .nativeFunction:
            guard !whitelist else {
                throw LuaError.runtime(
                    "\(function) field 'whitelist' is only valid with Entity/table filters"
                )
            }
            return .function(value)
        default:
            break
        }

        let values: [LuaValue]
        if case let .table(filterTable) = value {
            let pairs = try state.rawTablePairs(in: filterTable)
            guard pairs.count <= 4_096 else {
                throw LuaError.runtime(
                    "\(function) field 'filter' exceeds 4096 Entity entries"
                )
            }
            values = pairs.map(\.1)
        } else {
            values = [value]
        }

        var handles = Set<SourceBaseHandle>()
        for filteredValue in values {
            guard let object = GMLuaTypeSystem.typedObject(from: filteredValue) else {
                throw LuaError.runtime(
                    "\(function) field 'filter' supports only an Entity, table of Entities, " +
                        "or function"
                )
            }
            // `NULL` and stale invalid Entity userdata are valid filter values
            // but cannot name a current collision candidate.
            guard object.isValid else { continue }
            if let identity = entityRegistry.canonicalIdentity(for: filteredValue) {
                handles.insert(identity.handle)
            } else if let identity = entityRegistry.sourceMirrorIdentity(for: filteredValue) {
                handles.insert(identity.handle)
            } else {
                throw LuaError.runtime(
                    "\(function) field 'filter' contains an Entity outside the current registry"
                )
            }
        }
        return .entities(handles: handles, whitelist: whitelist)
    }

    private static func optionalInt32Field(
        _ name: String,
        defaultValue: Int32,
        in table: LuaTable,
        function: String,
        state: LuaState
    ) throws -> Int32 {
        let value = try rawField(name, in: table, state: state)
        if case .nilValue = value { return defaultValue }
        guard case let .number(number) = value,
              number.isFinite,
              number.rounded(.towardZero) == number,
              number >= Double(Int32.min), number <= Double(Int32.max) else {
            throw LuaError.runtime("\(function) field '\(name)' must be a 32-bit integer")
        }
        return Int32(number)
    }

    private static func optionalBooleanField(
        _ name: String,
        defaultValue: Bool,
        in table: LuaTable,
        function: String,
        state: LuaState
    ) throws -> Bool {
        let value = try rawField(name, in: table, state: state)
        if case .nilValue = value { return defaultValue }
        guard case let .boolean(boolean) = value else {
            throw LuaError.runtime("\(function) field '\(name)' must be a boolean")
        }
        return boolean
    }

    private static func outputField(
        in table: LuaTable,
        function: String,
        state: LuaState
    ) throws -> LuaTable? {
        let value = try rawField("output", in: table, state: state)
        if case .nilValue = value { return nil }
        guard case let .table(output) = value else {
            throw LuaError.runtime("\(function) field 'output' must be a table")
        }
        return output
    }

    private static func dynamicEntityValue(
        for handle: SourceBaseHandle,
        registry: GMLuaEntityRegistry,
        function: String
    ) throws -> LuaValue {
        guard handle.isValid, handle.entryIndex != 0 else {
            throw LuaError.runtime(
                "\(function) received an invalid dynamic EHANDLE"
            )
        }
        let value = registry.entity(at: handle.entryIndex)
        let identity = registry.canonicalIdentity(for: value) ??
            registry.sourceMirrorIdentity(for: value)
        guard identity?.handle == handle else {
            throw GMLuaTraceBridgeError
                .dynamicEntityUnavailable(handle.rawValue)
        }
        return value
    }

    private static func validateProviderResult(
        _ trace: SourceGameTrace,
        request: GMLuaTraceRequest,
        entityRegistry: GMLuaEntityRegistry
    ) throws {
        for (name, value) in [
            ("StartPos", trace.startPosition),
            ("HitPos", trace.endPosition),
            ("HitNormal", trace.plane.normal),
        ] where !finite(value) {
            throw GMLuaTraceBridgeError.nonFiniteProviderResult(name)
        }
        let resultDelta = trace.endPosition - trace.startPosition
        guard finite(resultDelta), resultDelta.lengthSquared.isFinite else {
            throw GMLuaTraceBridgeError.nonFiniteProviderResult("Normal")
        }
        for (name, value) in [
            ("Fraction", trace.fraction),
            ("FractionLeftSolid", trace.fractionLeftSolid),
        ] where !value.isFinite {
            throw GMLuaTraceBridgeError.nonFiniteProviderResult(name)
        }

        if trace.didHit {
            guard let handle = trace.entityHandle else {
                throw GMLuaTraceBridgeError.hitMissingWorldIdentity
            }
            if handle.entryIndex == 0 {
                guard handle == request.worldIdentity.handle else {
                    throw GMLuaTraceBridgeError.staleWorldIdentity(
                        expected: request.worldIdentity.handle.rawValue,
                        actual: handle.rawValue
                    )
                }
            } else {
                let value = entityRegistry.entity(at: handle.entryIndex)
                let identity = entityRegistry.canonicalIdentity(for: value) ??
                    entityRegistry.sourceMirrorIdentity(for: value)
                guard identity?.handle == handle else {
                    throw GMLuaTraceBridgeError
                        .dynamicEntityUnavailable(handle.rawValue)
                }
            }
        } else if let handle = trace.entityHandle {
            throw GMLuaTraceBridgeError.inconsistentMissIdentity(handle.rawValue)
        }
    }

    private static func writeResult(
        _ trace: SourceGameTrace,
        hitEntityValue: LuaValue,
        result: LuaTable,
        state: LuaState,
        typeSystem: GMLuaTypeSystem
    ) throws {
        let hit = trace.didHit
        let nullValue = state.getGlobal("NULL")
        let values: [(String, LuaValue)] = [
            ("StartPos", try vector(trace.startPosition, typeSystem: typeSystem)),
            ("HitPos", try vector(trace.endPosition, typeSystem: typeSystem)),
            ("HitNormal", try vector(trace.plane.normal, typeSystem: typeSystem)),
            // GMod documents this as (HitPos - StartPos):GetNormalized().
            // The distinction matters for start-solid traces whose Source
            // result can move StartPos to the solid-leave position.
            ("Normal", try vector(
                normalized(trace.endPosition - trace.startPosition),
                typeSystem: typeSystem
            )),
            ("Fraction", .number(Double(trace.fraction))),
            ("FractionLeftSolid", .number(Double(trace.fractionLeftSolid))),
            ("Hit", .boolean(hit)),
            ("HitWorld", .boolean(trace.didHitWorld)),
            ("HitNonWorld", .boolean(trace.didHitNonWorldEntity)),
            ("StartSolid", .boolean(trace.startSolid)),
            ("AllSolid", .boolean(trace.allSolid)),
            ("Contents", .number(Double(Int32(bitPattern: trace.contents.rawValue)))),
            ("Entity", hit ? hitEntityValue : nullValue),
            ("SurfaceFlags", .number(Double(trace.surface.flags))),
            ("DispFlags", .number(Double(trace.displacementFlags))),
            ("HitBox", .number(Double(trace.hitBox))),
            ("HitGroup", .number(Double(trace.hitGroup))),
            ("PhysicsBone", .number(Double(trace.physicsBone))),
        ]
        for (name, value) in values {
            try state.setRawTableValue(
                value,
                for: .string(LuaString(name)),
                in: result
            )
        }
        for name in GMLuaTraceBridge.unavailableResultFields {
            try state.setRawTableValue(
                .nilValue,
                for: .string(LuaString(name)),
                in: result
            )
        }
    }

    private static func vector(
        _ value: SourceVector3,
        typeSystem: GMLuaTypeSystem
    ) throws -> LuaValue {
        try GMLuaVectorAngle.makeNetworkVector(
            Double(value.x),
            Double(value.y),
            Double(value.z),
            typeSystem: typeSystem
        )
    }

    private static func normalized(_ value: SourceVector3) -> SourceVector3 {
        let length = value.length
        guard length != 0, length.isFinite else { return .zero }
        return value / length
    }
}
