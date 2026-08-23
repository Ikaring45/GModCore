import Foundation
import GModEngine

/// Why the App is asking CLIENT VGUI for a foreground Q/C frame. Lifecycle
/// and pointer captures are user-visible boundaries and must supersede older
/// work. Ordinary MTK host frames are passive sampling and must never build a
/// permanent backlog on the same serial lane as input.
enum GModGameForegroundSurfaceCaptureCause: Sendable, Equatable {
    case menuTransition
    case pointerMutation
    case hostFrame
}

enum GModGameForegroundSurfaceCapturePolicy {
    /// A completed foreground frame gets a short idle window before passive
    /// animation sampling resumes. Pointer and lifecycle work bypass it.
    static let defaultMinimumPassiveInterval: TimeInterval = 0.25

    static func shouldAdmit(
        scope: GMLuaVGUIRenderScope,
        cause: GModGameForegroundSurfaceCaptureCause,
        now: TimeInterval,
        lastCompletionTime: TimeInterval?,
        captureOrBuildInFlight: Bool,
        minimumPassiveInterval: TimeInterval = defaultMinimumPassiveInterval
    ) -> Bool {
        guard scope == .all, cause == .hostFrame else { return true }
        guard now.isFinite, now >= 0,
              minimumPassiveInterval.isFinite,
              minimumPassiveInterval >= 0,
              !captureOrBuildInFlight else {
            return false
        }
        guard let lastCompletionTime else { return true }
        guard lastCompletionTime.isFinite, lastCompletionTime >= 0 else {
            return true
        }
        // A replaced host clock admits the first sample instead of suppressing
        // it for the lifetime of the session.
        guard now >= lastCompletionTime else { return true }
        return now - lastCompletionTime >= minimumPassiveInterval
    }

    /// A request captured under OverlayPanel ownership cannot clear or replace
    /// a Q/C scene after the active owner changes while its actor call awaits.
    static func requestOwnsCurrentSurface(
        scope: GMLuaVGUIRenderScope,
        activeMenu: GModGameClientMenu?
    ) -> Bool {
        (scope == .overlay) == (activeMenu == nil)
    }

    /// The resolver-free scene is only an initial visibility bridge. Once a
    /// foreground scene exists, pointer/host refreshes retain it until the
    /// next fully resolved immutable replacement is ready.
    static func shouldPublishStructuralScene(
        activeMenu: GModGameClientMenu?,
        hasPublishedScene: Bool
    ) -> Bool {
        activeMenu != nil && !hasPublishedScene
    }
}
