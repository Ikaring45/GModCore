/// Public Garry's Mod `OBS_MODE` values. The numeric contract is part of the
/// original Player ABI and is replicated as engine-owned canonical state.
public enum SourceCanonicalPlayerObserverMode:
    Int32, CaseIterable, Equatable, Sendable
{
    case none = 0
    case deathCam = 1
    case freezeCam = 2
    case fixed = 3
    case inEye = 4
    case chase = 5
    case roaming = 6

    /// Source `CBasePlayer::SetObserverMode` selects one of these two movement
    /// paths. Target/FOV behavior remains unavailable until an authoritative
    /// observer-target and field-of-view system exists.
    var sourceMoveType: SourceMoveType {
        switch self {
        case .none, .deathCam, .fixed:
            return .none
        case .freezeCam, .inEye, .chase, .roaming:
            return .observer
        }
    }
}

/// Player-only observer state corresponding to Source's current and last
/// observer modes. This is not a Lua side table: it is carried by the same
/// full-EHANDLE snapshot and FIFO as the rest of the canonical Player.
public struct SourceCanonicalPlayerObserverState: Equatable, Sendable {
    public var mode: SourceCanonicalPlayerObserverMode
    public var lastMode: SourceCanonicalPlayerObserverMode

    public init(
        mode: SourceCanonicalPlayerObserverMode = .none,
        lastMode: SourceCanonicalPlayerObserverMode = .roaming
    ) {
        self.mode = mode
        self.lastMode = lastMode
    }

    public static let notObserving = SourceCanonicalPlayerObserverState()

    mutating func setMode(_ nextMode: SourceCanonicalPlayerObserverMode) {
        if mode.rawValue > SourceCanonicalPlayerObserverMode.deathCam.rawValue {
            lastMode = mode
        }
        mode = nextMode
    }

    mutating func stop() {
        guard mode != .none else { return }
        setMode(.none)
    }
}

extension SourceCanonicalEntityState {
    /// Source `StartObserverMode` state that can be represented by the current
    /// canonical Player contract. UI panels, FOV, observer targets, and weapon
    /// holstering are intentionally not fabricated here.
    mutating func startCanonicalSpectating(
        in mode: SourceCanonicalPlayerObserverMode
    ) throws {
        guard mode != .none else {
            stopCanonicalSpectating()
            return
        }
        guard var observer = motion.playerObserverState else {
            throw SourceCanonicalEntityError.invalidMotion
        }

        if observer.mode == .none {
            transform.origin = transform.origin + viewOffset
            viewOffset = .zero
        }
        motion.isOnGround = false
        motion.isDucked = false
        isNotSolid = true
        isNoDraw = true
        combat.takeDamageMode = 0
        combat.health = 1
        motion.isAlive = false
        observer.setMode(mode)
        motion.playerObserverState = observer
        moveType = mode.sourceMoveType
    }

    /// Source `SetObserverMode`: update the current mode and the movement/view
    /// state owned by that method. Callers that need to enter observer state
    /// must first use `startCanonicalSpectating`, matching the public GLua API.
    mutating func setCanonicalObserverMode(
        _ mode: SourceCanonicalPlayerObserverMode
    ) throws {
        guard var observer = motion.playerObserverState else {
            throw SourceCanonicalEntityError.invalidMotion
        }
        observer.setMode(mode)
        motion.playerObserverState = observer
        viewOffset = .zero
        moveType = mode.sourceMoveType
    }

    /// Source `StopObserverMode` clears observer bookkeeping only. Respawn is
    /// responsible for restoring solidity, visibility, damage, health, view
    /// offset, and normal movement; silently restoring guessed values here
    /// would diverge from the original lifecycle contract.
    mutating func stopCanonicalSpectating() {
        guard var observer = motion.playerObserverState else { return }
        observer.stop()
        motion.playerObserverState = observer
    }
}
