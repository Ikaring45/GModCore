import Foundation

/// Engine-owned movement values exposed by Garry's Mod's Player speed ABI.
///
/// These values travel inside the canonical Player motion snapshot. They are
/// not a host-session mirror: SERVER mutations therefore retain the exact
/// Player EHANDLE and use the ordinary canonical Entity replication FIFO.
public struct SourceCanonicalPlayerMovementSettings: Equatable, Sendable {
    public var slowWalkSpeed: Float
    public var walkSpeed: Float
    public var runSpeed: Float
    public var crouchedWalkSpeed: Float
    /// Retained for original GLua round trips. The current world-walk slice
    /// has only fully-ducked endpoints and does not invent a timed transition.
    public var duckSpeed: Float
    /// Retained counterpart to `duckSpeed`; likewise not consumed until the
    /// Source duck-time interpolation contract is implemented.
    public var unDuckSpeed: Float
    public var jumpPower: Float

    public init(
        slowWalkSpeed: Float,
        walkSpeed: Float,
        runSpeed: Float,
        crouchedWalkSpeed: Float,
        duckSpeed: Float,
        unDuckSpeed: Float,
        jumpPower: Float
    ) {
        self.slowWalkSpeed = slowWalkSpeed
        self.walkSpeed = walkSpeed
        self.runSpeed = runSpeed
        self.crouchedWalkSpeed = crouchedWalkSpeed
        self.duckSpeed = duckSpeed
        self.unDuckSpeed = unDuckSpeed
        self.jumpPower = jumpPower
    }

    /// Preserves the movement slice's pre-Player-ABI behavior until original
    /// gamemode Lua authors the real class values through `OnPlayerSpawn`.
    /// Duck/unduck duration does not affect that legacy immediate-endpoint
    /// boundary, so both retained values begin at zero rather than implying a
    /// transition curve the movement core does not implement.
    public static let legacyWorldWalkDefaults = Self(
        slowWalkSpeed: 320,
        walkSpeed: 320,
        runSpeed: 320,
        crouchedWalkSpeed: 1 / 3,
        duckSpeed: 0,
        unDuckSpeed: 0,
        jumpPower: sqrt(2 * 800 * 21)
    )

    /// Maps the Player values to the command modes consumed by the fixed-tick
    /// host. `+walk` is checked first so a combined input word remains bounded
    /// by the explicit slow-walk request.
    public func maximumSpeed(for buttons: SourceInputButtons) -> Float {
        if buttons.contains(.walk) { return slowWalkSpeed }
        if buttons.contains(.speed) { return runSpeed }
        return walkSpeed
    }

    var isFiniteAndNonNegative: Bool {
        [
            slowWalkSpeed,
            walkSpeed,
            runSpeed,
            crouchedWalkSpeed,
            duckSpeed,
            unDuckSpeed,
            jumpPower,
        ].allSatisfy { $0.isFinite && $0 >= 0 }
    }
}

enum SourceCanonicalPlayerMovementField: CaseIterable, Sendable {
    case slowWalkSpeed
    case walkSpeed
    case runSpeed
    case crouchedWalkSpeed
    case duckSpeed
    case unDuckSpeed
    case jumpPower

    var getterName: String {
        switch self {
        case .slowWalkSpeed: "GetSlowWalkSpeed"
        case .walkSpeed: "GetWalkSpeed"
        case .runSpeed: "GetRunSpeed"
        case .crouchedWalkSpeed: "GetCrouchedWalkSpeed"
        case .duckSpeed: "GetDuckSpeed"
        case .unDuckSpeed: "GetUnDuckSpeed"
        case .jumpPower: "GetJumpPower"
        }
    }

    var setterName: String {
        switch self {
        case .slowWalkSpeed: "SetSlowWalkSpeed"
        case .walkSpeed: "SetWalkSpeed"
        case .runSpeed: "SetRunSpeed"
        case .crouchedWalkSpeed: "SetCrouchedWalkSpeed"
        case .duckSpeed: "SetDuckSpeed"
        case .unDuckSpeed: "SetUnDuckSpeed"
        case .jumpPower: "SetJumpPower"
        }
    }

    func value(in settings: SourceCanonicalPlayerMovementSettings) -> Float {
        switch self {
        case .slowWalkSpeed: settings.slowWalkSpeed
        case .walkSpeed: settings.walkSpeed
        case .runSpeed: settings.runSpeed
        case .crouchedWalkSpeed: settings.crouchedWalkSpeed
        case .duckSpeed: settings.duckSpeed
        case .unDuckSpeed: settings.unDuckSpeed
        case .jumpPower: settings.jumpPower
        }
    }

    func set(
        _ value: Float,
        in settings: inout SourceCanonicalPlayerMovementSettings
    ) {
        switch self {
        case .slowWalkSpeed: settings.slowWalkSpeed = value
        case .walkSpeed: settings.walkSpeed = value
        case .runSpeed: settings.runSpeed = value
        case .crouchedWalkSpeed: settings.crouchedWalkSpeed = value
        case .duckSpeed: settings.duckSpeed = value
        case .unDuckSpeed: settings.unDuckSpeed = value
        case .jumpPower: settings.jumpPower = value
        }
    }
}
