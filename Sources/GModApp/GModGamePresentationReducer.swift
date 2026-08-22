import GModEngine
import GModGameAssets

/// Value-only evidence captured when the in-game Home menu is presented.
///
/// The snapshot is deliberately presentation state, not a second playable
/// session. Resume never feeds it back into the engine; the live lane remains
/// installed and therefore retains its exact world/player/tick state.
struct GModGameSessionContinuitySnapshot: Equatable, Sendable {
    let map: GModBundledMap
    let playerOrigin: SourceVector3
    let viewAngles: SourceQAngle
    let fixedTickCount: UInt64
}

enum GModGameStartFailureOrigin: Equatable, Sendable {
    case cpu
    case renderer(meshIdentifier: String)
}

/// Value-only failure presentation shared by the CPU startup lane and Metal.
/// Runtime detail remains verbatim; translated UI prose is resolved from the
/// active content/app language catalog at the SwiftUI boundary.
struct GModGameStartFailure: Equatable, Sendable {
    let map: GModBundledMap
    let origin: GModGameStartFailureOrigin
    let detail: String
}

enum GModGamePresentationEvent: Equatable, Sendable {
    case pauseRequested(GModGameSessionContinuitySnapshot?)
    case validatedMapSelected(GModBundledMap)
    case homeMenuAction(GModHomeMenuAction)
    case startFailed(GModGameStartFailure)
    case returnHomeAfterStartFailure
}

enum GModGamePresentationEffect: Equatable, Sendable {
    case suspendForPauseMenu
    case resumeExistingSession
    case startMap(GModBundledMap)
    case disconnectSession
    case abandonFailedStart
    case presentQuitUnavailable

    /// The stock menu reports its raw console command before its map callback
    /// validates that the requested BSP is one of this build's bundled maps.
    case awaitValidatedMapSelection(String)
}

struct GModGamePresentationState: Equatable, Sendable {
    private(set) var showsHomeMenu = true
    private(set) var pausedSession: GModGameSessionContinuitySnapshot?
    private(set) var startFailure: GModGameStartFailure?

    mutating func reduce(
        _ event: GModGamePresentationEvent
    ) -> [GModGamePresentationEffect] {
        switch event {
        case let .pauseRequested(snapshot):
            guard let snapshot else { return [] }
            pausedSession = snapshot
            showsHomeMenu = true
            return [.suspendForPauseMenu]

        case let .validatedMapSelected(map):
            pausedSession = nil
            startFailure = nil
            showsHomeMenu = false
            return [.startMap(map)]

        case let .startFailed(failure):
            startFailure = failure
            // Keep the opaque loading surface visible until the user makes an
            // explicit recovery choice. A failed frame never reveals the
            // incomplete world underneath it.
            showsHomeMenu = false
            return []

        case .returnHomeAfterStartFailure:
            guard startFailure != nil else { return [] }
            pausedSession = nil
            showsHomeMenu = true
            return [.abandonFailedStart]

        case let .homeMenuAction(action):
            switch action {
            case let .startMap(rawName):
                return [.awaitValidatedMapSelection(rawName)]

            case .setLanguage:
                // Home owns language validation/persistence and publishes the
                // accepted snapshot through the shared localization store.
                return []

            case .openOptions, .openProblems, .openConsole:
                // Utility windows are owned by MainView and layer above the
                // already-paused Home surface without mutating the live lane.
                return []

            case .hideGameUI:
                guard pausedSession != nil else { return [] }
                showsHomeMenu = false
                return [.resumeExistingSession]

            case .disconnect:
                pausedSession = nil
                showsHomeMenu = true
                return [.disconnectSession]

            case .quit:
                return [.presentQuitUnavailable]
            }
        }
    }
}
