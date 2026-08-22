import Foundation
import GModEngine
import GModGameSession

enum GModGameClientMenu: String, Sendable, Equatable {
    case spawn
    case context

    var statusName: String {
        switch self {
        case .spawn: return "Spawn Menu"
        case .context: return "Context Menu"
        }
    }

    var playableMenu: GModPlayableClientMenu {
        switch self {
        case .spawn: return .spawn
        case .context: return .context
        }
    }

    init(_ playableMenu: GModPlayableClientMenu) {
        switch playableMenu {
        case .spawn: self = .spawn
        case .context: self = .context
        }
    }
}

enum GModGameWorldInputPolicy {
    static func accepts(
        isReady: Bool,
        isInputSuspended: Bool,
        activeMenu: GModGameClientMenu?,
        transitioningMenu: GModGameClientMenu?,
        isHostPopupPresented: Bool = false
    ) -> Bool {
        isReady && !isInputSuspended && activeMenu == nil &&
            transitioningMenu == nil && !isHostPopupPresented
    }

    static func movementInput(
        acceptsWorldInput: Bool,
        viewAngles: SourceQAngle,
        forwardAxis: Float,
        sideAxis: Float,
        jumpPressed: Bool,
        heldActionButtons: SourceInputButtons = [],
        speed: Float = 250
    ) -> GModPlayableMovementInput {
        guard acceptsWorldInput else { return .idle }
        var buttons: SourceInputButtons = []
        if forwardAxis > 0 { buttons.insert(.forward) }
        if forwardAxis < 0 { buttons.insert(.back) }
        if sideAxis > 0 { buttons.insert(.moveRight) }
        if sideAxis < 0 { buttons.insert(.moveLeft) }
        if jumpPressed { buttons.insert(.jump) }
        buttons.formUnion(
            heldActionButtons.intersection([.attack, .attack2, .use])
        )
        return GModPlayableMovementInput(
            viewAngles: viewAngles,
            forwardMove: forwardAxis * speed,
            sideMove: sideAxis * speed,
            buttons: buttons
        )
    }
}

/// The native Surface scene currently represents the foreground Q/C panel
/// tree. CLIENT Lua continues to tick when neither menu is visible, but there
/// is no renderer-facing panel capture to rebuild in that state.
enum GModGameClientSurfaceCapturePolicy {
    static func shouldCapture(
        activeMenu: GModGameClientMenu?,
        transitioningMenu: GModGameClientMenu?
    ) -> Bool {
        activeMenu != nil && transitioningMenu == nil
    }
}

struct GModGameSurfaceRefreshRequest: Sendable, Equatable {
    let generation: GModGameSessionGenerationToken
}

/// One renderer refresh can be expensive while pointer callbacks must remain
/// ordered and low-latency. Keep only the newest generation request while a
/// prior Surface snapshot/build is in flight.
struct GModGameSurfaceRefreshPendingQueue: Sendable, Equatable {
    private(set) var pending: GModGameSurfaceRefreshRequest?

    mutating func submit(_ request: GModGameSurfaceRefreshRequest) {
        pending = request
    }

    mutating func takeLatest() -> GModGameSurfaceRefreshRequest? {
        defer { pending = nil }
        return pending
    }

    mutating func removeAll() {
        pending = nil
    }
}

enum GModGameWorldActionButton: Sendable, Equatable {
    case attack
    case attack2
    case use
    case reload

    var sourceButton: SourceInputButtons {
        switch self {
        case .attack: return .attack
        case .attack2: return .attack2
        case .use: return .use
        case .reload: return .reload
        }
    }
}

struct GModGameSessionGenerationToken: Sendable, Equatable {
    let application: UInt64
    let lane: UInt64

    func matches(application: UInt64, lane: UInt64?) -> Bool {
        self.application == application && lane == Optional(self.lane)
    }
}

/// Identifies one host-input admission interval within a live session. The
/// input epoch is deliberately independent of both application and lane
/// generations: suspension and UI input boundaries retire already-popped
/// frame batches without pretending that the whole session was replaced.
struct GModGameFrameToken: Sendable, Equatable {
    let generation: GModGameSessionGenerationToken
    let inputEpoch: UInt64

    func matches(
        application: UInt64,
        lane: UInt64?,
        inputEpoch: UInt64?
    ) -> Bool {
        generation.matches(application: application, lane: lane)
            && self.inputEpoch == inputEpoch
    }
}

struct GModSurfacePublicationToken: Sendable, Equatable {
    let generation: GModGameSessionGenerationToken
    let requestRevision: UInt64
    let activeMenu: GModGameClientMenu?

    func matches(
        application: UInt64,
        lane: UInt64?,
        requestRevision: UInt64,
        activeMenu: GModGameClientMenu?
    ) -> Bool {
        generation.matches(application: application, lane: lane)
            && self.requestRevision == requestRevision
            && self.activeMenu == activeMenu
    }
}

struct GModGamePointerSample: Sendable, Equatable {
    let generation: GModGameSessionGenerationToken
    let pointerEpoch: UInt64
    let x: Double
    let y: Double
    let phase: GMLuaPointerPhase
    let timestamp: TimeInterval
}

struct GModGamePointerLocation: Sendable, Equatable {
    let x: Double
    let y: Double
}

/// Maps SwiftUI gesture coordinates (logical points) into the logical VGUI
/// viewport. Metal drawable pixels intentionally never enter this boundary.
enum GModGamePointerCoordinateMapper {
    static func map(
        x: Double,
        y: Double,
        viewWidth: Double,
        viewHeight: Double,
        viewportWidth: Int,
        viewportHeight: Int
    ) -> GModGamePointerLocation? {
        guard x.isFinite, y.isFinite,
              viewWidth.isFinite, viewHeight.isFinite,
              viewWidth > 0, viewHeight > 0,
              viewportWidth > 0, viewportHeight > 0 else {
            return nil
        }
        let mapped = GModGamePointerLocation(
            x: x / viewWidth * Double(viewportWidth),
            y: y / viewHeight * Double(viewportHeight)
        )
        guard mapped.x.isFinite, mapped.y.isFinite else { return nil }
        return mapped
    }
}

struct GModGamePointerQueueSubmission: Sendable, Equatable {
    let acceptedSample: Bool
    let droppedSampleCount: Int
    let coalescedMoveCount: Int
}

/// Pure bounded queue kept separate from the Task scheduler so capacity,
/// coalescing, and critical phase ordering have deterministic unit tests.
struct GModGamePointerPendingQueue: Sendable {
    private enum InputGestureState: Sendable {
        case idle
        case admitted
        case rejected
    }

    let capacity: Int
    private(set) var samples: [GModGamePointerSample] = []
    private var inputGestureState = InputGestureState.idle

    init(capacity: Int = 32) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    mutating func enqueue(
        _ sample: GModGamePointerSample
    ) -> GModGamePointerQueueSubmission {
        switch sample.phase {
        case .began:
            return enqueueGestureBegan(sample)
        case .ended, .cancelled:
            return enqueueGestureClosure(sample)
        case .moved:
            return enqueueMove(sample)
        case .scroll:
            return enqueueStandalone(sample)
        }
    }

    mutating func popFirst() -> GModGamePointerSample? {
        guard !samples.isEmpty else { return nil }
        return samples.removeFirst()
    }

    private mutating func enqueueGestureBegan(
        _ sample: GModGamePointerSample
    ) -> GModGamePointerQueueSubmission {
        guard inputGestureState == .idle else {
            return Self.droppedIncoming
        }
        guard capacity >= 2 else {
            inputGestureState = .rejected
            return Self.droppedIncoming
        }

        // Reserve one slot for this gesture's eventual ended/cancelled sample.
        // Space is recovered only by removing noncritical samples or a whole
        // completed gesture whose begin and closure are both still pending.
        let evicted = evictSafely(untilCountIsAtMost: capacity - 2)
        guard samples.count <= capacity - 2 else {
            inputGestureState = .rejected
            return GModGamePointerQueueSubmission(
                acceptedSample: false,
                droppedSampleCount: evicted + 1,
                coalescedMoveCount: 0
            )
        }
        samples.append(sample)
        inputGestureState = .admitted
        return GModGamePointerQueueSubmission(
            acceptedSample: true,
            droppedSampleCount: evicted,
            coalescedMoveCount: 0
        )
    }

    private mutating func enqueueGestureClosure(
        _ sample: GModGamePointerSample
    ) -> GModGamePointerQueueSubmission {
        switch inputGestureState {
        case .idle:
            // Never create an orphan closure in the pending stream.
            return Self.droppedIncoming
        case .rejected:
            // The matching begin was rejected, so reject the whole gesture.
            inputGestureState = .idle
            return Self.droppedIncoming
        case .admitted:
            // enqueueGestureBegan reserved this slot, and move/scroll paths
            // preserve it until the gesture closes.
            samples.append(sample)
            inputGestureState = .idle
            return GModGamePointerQueueSubmission(
                acceptedSample: true,
                droppedSampleCount: 0,
                coalescedMoveCount: 0
            )
        }
    }

    private mutating func enqueueMove(
        _ sample: GModGamePointerSample
    ) -> GModGamePointerQueueSubmission {
        guard inputGestureState != .rejected else {
            return Self.droppedIncoming
        }
        if let last = samples.indices.last,
           Self.isMove(samples[last].phase) {
            samples[last] = sample
            return GModGamePointerQueueSubmission(
                acceptedSample: true,
                droppedSampleCount: 0,
                coalescedMoveCount: 1
            )
        }

        let limit = inputGestureState == .admitted
            ? capacity - 1
            : capacity
        guard samples.count < limit else {
            return Self.droppedIncoming
        }
        samples.append(sample)
        return GModGamePointerQueueSubmission(
            acceptedSample: true,
            droppedSampleCount: 0,
            coalescedMoveCount: 0
        )
    }

    private mutating func enqueueStandalone(
        _ sample: GModGamePointerSample
    ) -> GModGamePointerQueueSubmission {
        guard inputGestureState != .rejected else {
            return Self.droppedIncoming
        }
        let limit = inputGestureState == .admitted
            ? capacity - 1
            : capacity
        guard samples.count < limit else {
            return Self.droppedIncoming
        }
        samples.append(sample)
        return GModGamePointerQueueSubmission(
            acceptedSample: true,
            droppedSampleCount: 0,
            coalescedMoveCount: 0
        )
    }

    private mutating func evictSafely(
        untilCountIsAtMost targetCount: Int
    ) -> Int {
        var evicted = 0
        while samples.count > targetCount {
            if let noncritical = samples.firstIndex(where: {
                Self.isMove($0.phase) || Self.isScroll($0.phase)
            }) {
                samples.remove(at: noncritical)
                evicted += 1
                continue
            }
            guard let range = oldestCompleteGestureRange() else { break }
            evicted += range.count
            samples.removeSubrange(range)
        }
        return evicted
    }

    /// Returns only a gesture whose begin and closure are both pending. A
    /// leading closure may correspond to a begin already delivered to the
    /// consumer and therefore must never be evicted by itself.
    private func oldestCompleteGestureRange() -> Range<Int>? {
        var pendingBegin: Int?
        for index in samples.indices {
            switch samples[index].phase {
            case .began:
                if pendingBegin == nil { pendingBegin = index }
            case .ended, .cancelled:
                if let pendingBegin {
                    return pendingBegin..<(index + 1)
                }
            case .moved, .scroll:
                break
            }
        }
        return nil
    }

    private static func isMove(_ phase: GMLuaPointerPhase) -> Bool {
        if case .moved = phase { return true }
        return false
    }

    private static func isScroll(_ phase: GMLuaPointerPhase) -> Bool {
        if case .scroll = phase { return true }
        return false
    }

    private static let droppedIncoming = GModGamePointerQueueSubmission(
        acceptedSample: false,
        droppedSampleCount: 1,
        coalescedMoveCount: 0
    )
}
