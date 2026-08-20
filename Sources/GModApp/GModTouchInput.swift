import Foundation
import GModEngine

#if canImport(SwiftUI)
import SwiftUI
#endif

#if canImport(SwiftUI) && canImport(UIKit)
import UIKit
#endif

struct GModTouchSample: Sendable, Equatable {
    let x: Double
    let y: Double
    let viewWidth: Double
    let viewHeight: Double
    let phase: GMLuaPointerPhase
    let timestamp: TimeInterval
}

/// A single-touch lifecycle shared by the UIKit bridge and the pure control
/// reducers. Closing the lifecycle before invoking a handler makes terminal
/// delivery idempotent even when that handler synchronously removes the view.
struct GModSingleTouchLifecycle: Sendable, Equatable {
    private(set) var isActive = false

    mutating func accept(_ phase: GMLuaPointerPhase) -> Bool {
        switch phase {
        case .began:
            guard !isActive else { return false }
            isActive = true
            return true
        case .moved:
            return isActive
        case .ended, .cancelled:
            guard isActive else { return false }
            isActive = false
            return true
        case .scroll:
            return false
        }
    }
}

struct GModJoystickTouchOutput: Sendable, Equatable {
    let offsetX: Double
    let offsetY: Double
    let forward: Float
    let side: Float

    static let zero = GModJoystickTouchOutput(
        offsetX: 0,
        offsetY: 0,
        forward: 0,
        side: 0
    )
}

/// Pure joystick state keeps visual and submitted axes on the same lifecycle.
/// A real UIKit cancellation therefore produces exactly one zero output.
struct GModJoystickTouchState: Sendable, Equatable {
    private var lifecycle = GModSingleTouchLifecycle()
    private(set) var output = GModJoystickTouchOutput.zero

    var isTracking: Bool { lifecycle.isActive }

    mutating func consume(
        _ sample: GModTouchSample,
        radius: Double
    ) -> GModJoystickTouchOutput? {
        switch sample.phase {
        case .began, .moved:
            guard sample.x.isFinite, sample.y.isFinite,
                  sample.viewWidth.isFinite, sample.viewHeight.isFinite,
                  radius.isFinite, radius > 0,
                  lifecycle.accept(sample.phase) else {
                return nil
            }
            var dx = sample.x - sample.viewWidth * 0.5
            var dy = sample.y - sample.viewHeight * 0.5
            let length = (dx * dx + dy * dy).squareRoot()
            if length > radius {
                let scale = radius / length
                dx *= scale
                dy *= scale
            }
            output = GModJoystickTouchOutput(
                offsetX: dx,
                offsetY: dy,
                forward: Float(-dy / radius),
                side: Float(dx / radius)
            )
            return output
        case .ended, .cancelled:
            guard lifecycle.accept(sample.phase) else { return nil }
            output = .zero
            return output
        case .scroll:
            return nil
        }
    }
}

struct GModLookTouchDelta: Sendable, Equatable {
    let x: Float
    let y: Float
}

/// Tracks the prior absolute touch point instead of relying on SwiftUI's drag
/// translation. Cancellation clears it, so the next gesture cannot inherit a
/// stale delta origin.
struct GModLookTouchState: Sendable, Equatable {
    private var lifecycle = GModSingleTouchLifecycle()
    private var priorX: Double?
    private var priorY: Double?

    var isTracking: Bool { lifecycle.isActive }
    var hasPriorLocation: Bool { priorX != nil && priorY != nil }

    mutating func consume(
        _ sample: GModTouchSample
    ) -> GModLookTouchDelta? {
        switch sample.phase {
        case .began:
            guard sample.x.isFinite, sample.y.isFinite,
                  lifecycle.accept(.began) else {
                return nil
            }
            priorX = sample.x
            priorY = sample.y
            return nil
        case .moved:
            guard sample.x.isFinite, sample.y.isFinite,
                  lifecycle.accept(.moved),
                  let priorX, let priorY else {
                return nil
            }
            let delta = GModLookTouchDelta(
                x: Float(sample.x - priorX),
                y: Float(sample.y - priorY)
            )
            self.priorX = sample.x
            self.priorY = sample.y
            return delta
        case .ended, .cancelled:
            guard lifecycle.accept(sample.phase) else { return nil }
            priorX = nil
            priorY = nil
            return nil
        case .scroll:
            return nil
        }
    }
}

#if canImport(UIKit)
@MainActor
struct GModTouchInputBridge: UIViewRepresentable {
    let onTouch: (GModTouchSample) -> Void

    func makeUIView(context: Context) -> GModSingleTouchCaptureView {
        let view = GModSingleTouchCaptureView()
        view.onTouch = onTouch
        return view
    }

    func updateUIView(
        _ uiView: GModSingleTouchCaptureView,
        context: Context
    ) {
        uiView.onTouch = onTouch
    }

    static func dismantleUIView(
        _ uiView: GModSingleTouchCaptureView,
        coordinator: Void
    ) {
        uiView.cancelActiveTouch(
            timestamp: ProcessInfo.processInfo.systemUptime
        )
        uiView.onTouch = nil
    }
}

@MainActor
final class GModSingleTouchCaptureView: UIView {
    var onTouch: ((GModTouchSample) -> Void)?

    private var lifecycle = GModSingleTouchLifecycle()
    private var activeTouch: UITouch?
    private var lastX: Double = 0
    private var lastY: Double = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isMultipleTouchEnabled = true
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isOpaque = false
        isMultipleTouchEnabled = true
        isAccessibilityElement = false
    }

    override func touchesBegan(
        _ touches: Set<UITouch>,
        with event: UIEvent?
    ) {
        guard activeTouch == nil,
              let touch = touches.first,
              lifecycle.accept(.began) else {
            return
        }
        activeTouch = touch
        emit(touch, phase: .began, event: event)
    }

    override func touchesMoved(
        _ touches: Set<UITouch>,
        with event: UIEvent?
    ) {
        guard let touch = matchingActiveTouch(in: touches),
              lifecycle.accept(.moved) else {
            return
        }
        emit(touch, phase: .moved, event: event)
    }

    override func touchesEnded(
        _ touches: Set<UITouch>,
        with event: UIEvent?
    ) {
        finishActiveTouch(in: touches, phase: .ended, event: event)
    }

    override func touchesCancelled(
        _ touches: Set<UITouch>,
        with event: UIEvent?
    ) {
        finishActiveTouch(in: touches, phase: .cancelled, event: event)
    }

    func cancelActiveTouch(timestamp: TimeInterval) {
        guard lifecycle.accept(.cancelled) else {
            activeTouch = nil
            return
        }
        activeTouch = nil
        let sample = GModTouchSample(
            x: lastX,
            y: lastY,
            viewWidth: Double(bounds.width),
            viewHeight: Double(bounds.height),
            phase: .cancelled,
            timestamp: timestamp
        )
        onTouch?(sample)
    }

    private func matchingActiveTouch(
        in touches: Set<UITouch>
    ) -> UITouch? {
        guard let activeTouch else { return nil }
        return touches.first(where: { $0 === activeTouch })
    }

    private func finishActiveTouch(
        in touches: Set<UITouch>,
        phase: GMLuaPointerPhase,
        event: UIEvent?
    ) {
        guard let touch = matchingActiveTouch(in: touches) else { return }
        let point = touch.location(in: self)
        lastX = Double(point.x)
        lastY = Double(point.y)

        // Clear before the callback: it may synchronously dismantle this view.
        activeTouch = nil
        guard lifecycle.accept(phase) else { return }
        onTouch?(GModTouchSample(
            x: lastX,
            y: lastY,
            viewWidth: Double(bounds.width),
            viewHeight: Double(bounds.height),
            phase: phase,
            timestamp: event?.timestamp ?? touch.timestamp
        ))
    }

    private func emit(
        _ touch: UITouch,
        phase: GMLuaPointerPhase,
        event: UIEvent?
    ) {
        let point = touch.location(in: self)
        lastX = Double(point.x)
        lastY = Double(point.y)
        onTouch?(GModTouchSample(
            x: lastX,
            y: lastY,
            viewWidth: Double(bounds.width),
            viewHeight: Double(bounds.height),
            phase: phase,
            timestamp: event?.timestamp ?? touch.timestamp
        ))
    }
}
#elseif canImport(SwiftUI)
/// Non-UIKit fallback keeps the Swift package usable on macOS. The shipped
/// iPad target always takes the native UIView path above.
@MainActor
struct GModTouchInputBridge: View {
    let onTouch: (GModTouchSample) -> Void
    @State private var lifecycle = GModSingleTouchLifecycle()

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            let timestamp = ProcessInfo.processInfo.systemUptime
                            if lifecycle.accept(.began) {
                                send(
                                    value.startLocation,
                                    size: geometry.size,
                                    phase: .began,
                                    timestamp: timestamp
                                )
                            }
                            if lifecycle.accept(.moved) {
                                send(
                                    value.location,
                                    size: geometry.size,
                                    phase: .moved,
                                    timestamp: timestamp
                                )
                            }
                        }
                        .onEnded { value in
                            guard lifecycle.accept(.ended) else { return }
                            send(
                                value.location,
                                size: geometry.size,
                                phase: .ended,
                                timestamp: ProcessInfo.processInfo.systemUptime
                            )
                        }
                )
        }
    }

    private func send(
        _ point: CGPoint,
        size: CGSize,
        phase: GMLuaPointerPhase,
        timestamp: TimeInterval
    ) {
        onTouch(GModTouchSample(
            x: Double(point.x),
            y: Double(point.y),
            viewWidth: Double(size.width),
            viewHeight: Double(size.height),
            phase: phase,
            timestamp: timestamp
        ))
    }
}
#endif
