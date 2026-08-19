import SwiftUI
import Foundation
import GModEngine
import GModGameAssets
import GModMetal

public struct GModMainView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var console: GModConsoleModel
    @StateObject private var game: GModGameSessionModel
    @State private var stats = "Starting ARM engine..."
    @State private var isRunning = false
    @State private var resultLabel = "READY"
    @State private var showConsole = false

    public init() {
        let factory = GModAppRuntimeFactory()
        let consoleModel = GModConsoleModel(runtimeFactory: factory)
        _console = StateObject(
            wrappedValue: consoleModel
        )
        _game = StateObject(
            wrappedValue: GModGameSessionModel(
                runtimeFactory: factory,
                logSink: { [weak consoleModel] line in
                    consoleModel?.append(line)
                }
            )
        )
    }

    public var body: some View {
        // Read the MainActor-isolated StateObject once while constructing the
        // view. The Metal callback is Sendable and calls the model's explicitly
        // nonisolated mailbox entry point without reaching back through the
        // property wrapper from the render thread.
        let frameTarget = game

        return ZStack {
            Color(red: 0.105, green: 0.11, blue: 0.115)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                rendererHeader

                gameControls

                ZStack(alignment: .bottom) {
                    GModMetalView(
                        stats: $stats,
                        worldScene: game.worldScene,
                        surfaceScene: game.surfaceScene,
                        onFrame: { [frameTarget] request in
                            frameTarget.submitFrame(request)
                        }
                    )
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: .infinity)
                    .background(Color.black)
                    .overlay(
                        Rectangle()
                            .stroke(Color(red: 0.30, green: 0.31, blue: 0.32), lineWidth: 1)
                    )

                    if game.isSpawnMenuOpen && !game.isInputSuspended {
                        GModSpawnMenuPointerSurface {
                            x, y, width, height, phase, timestamp in
                            game.submitSpawnMenuPointer(
                                x: x,
                                y: y,
                                viewWidth: width,
                                viewHeight: height,
                                phase: phase,
                                timestamp: timestamp
                            )
                        }
                    }

                    if !game.isSpawnMenuOpen &&
                        !game.isSpawnMenuTransitioning &&
                        !game.isInputSuspended {
                        HStack(alignment: .bottom) {
                            GModTouchJoystick { forward, side in
                                game.setMovementAxes(
                                    forward: forward,
                                    side: side
                                )
                            }

                            Spacer(minLength: 40)

                            GModTouchLookPad { deltaX, deltaY in
                                game.adjustLook(deltaX: deltaX, deltaY: deltaY)
                            }
                        }
                        .padding(18)
                        .opacity(game.isReady ? 1 : 0.35)
                        .allowsHitTesting(game.isReady && !game.isInputSuspended)
                    }

                    VStack {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(game.surfaceStatus)
                                if game.isSpawnMenuOpen {
                                    Text(game.pointerCapability)
                                    Text(game.pointerStatus)
                                }
                            }
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundColor(Color.white.opacity(0.78))
                                .lineLimit(1)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(Color.black.opacity(0.55))
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(8)
                    .allowsHitTesting(false)
                }
                .frame(minHeight: 320)

                if showConsole {
                    consoleWindow
                        .frame(height: 310)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(14)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if scenePhase == .active {
                game.resumeInput()
            } else {
                game.suspendInput()
            }
        }
        .onDisappear {
            game.suspendInput()
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                game.resumeInput()
            case .inactive, .background:
                game.suspendInput()
            @unknown default:
                game.suspendInput()
            }
        }
    }

    private var consoleWindow: some View {
        VStack(spacing: 0) {
            consoleTitleBar
            consoleFilterBar
            consoleLog
            consoleInputBar
        }
        .background(Color(red: 0.145, green: 0.15, blue: 0.155))
        .overlay(
            Rectangle()
                .stroke(Color(red: 0.42, green: 0.43, blue: 0.44), lineWidth: 1)
        )
    }

    private var consoleTitleBar: some View {
        HStack(spacing: 8) {
            ZStack {
                Rectangle()
                    .fill(Color(red: 0.20, green: 0.43, blue: 0.68))
                    .frame(width: 20, height: 20)
                Text("g")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }

            Text("Garry's PAD Console")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color(white: 0.93))

            Text(game.isReady ? "ACTIVE SANDBOX / SERVER" : "Lua 5.1 CORE / SERVER")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color(white: 0.62))

            Spacer()

            Text(resultLabel)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(statusColor)

            Button(isRunning ? "Running…" : "Run Lua 5.1 Core Tests") {
                runOfficialTests()
            }
            .buttonStyle(GModButtonStyle())
            .disabled(isRunning)

            Button("Clear") {
                console.clear()
            }
            .buttonStyle(GModButtonStyle())
        }
        .padding(.horizontal, 8)
        .frame(height: 31)
        .background(Color(red: 0.21, green: 0.215, blue: 0.22))
    }

    private var consoleFilterBar: some View {
        HStack(spacing: 8) {
            Text("Remove new entries containing:")
                .font(.system(size: 10))
                .foregroundColor(Color(white: 0.76))

            TextField("", text: $console.removeContaining)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.black)
                .padding(.horizontal, 6)
                .frame(height: 23)
                .background(Color(white: 0.92))
                .overlay(Rectangle().stroke(Color(white: 0.35), lineWidth: 1))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(red: 0.18, green: 0.185, blue: 0.19))
    }

    private var consoleLog: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(console.visibleLines) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(color(for: line.kind))
                            .multilineTextAlignment(.leading)
                            .frame(
                                maxWidth: .infinity,
                                alignment: .leading
                            )
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )
                            .textSelection(.enabled)
                            .id(line.id)
                    }
                }
                .frame(
                    maxWidth: .infinity,
                    alignment: .leading
                )
                .padding(.horizontal, 7)
                .padding(.vertical, 6)
            }
            .background(Color(red: 0.105, green: 0.11, blue: 0.115))
            .onChange(of: console.lines.count) { _ in
                guard let last = console.visibleLines.last else { return }
                withAnimation(.none) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var consoleInputBar: some View {
        HStack(spacing: 7) {
            TextField("Lua / lua_run command", text: $console.input)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.black)
                .padding(.horizontal, 7)
                .frame(height: 27)
                .background(Color(white: 0.94))
                .overlay(Rectangle().stroke(Color(white: 0.34), lineWidth: 1))
                .onSubmit {
                    submitConsole()
                }

            Button("Submit") {
                submitConsole()
            }
            .buttonStyle(GModButtonStyle())
        }
        .padding(7)
        .background(Color(red: 0.19, green: 0.195, blue: 0.20))
    }

    private var rendererHeader: some View {
        HStack {
            Text("Render Preview")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(white: 0.82))

            Spacer()

            Text(stats.replacingOccurrences(of: "\n", with: "   "))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundColor(Color(white: 0.67))
                .lineLimit(1)
        }
        .padding(.horizontal, 4)
    }

    private var gameControls: some View {
        HStack(spacing: 8) {
            Button("gm_construct") {
                game.start(map: .construct)
            }
            .buttonStyle(GModButtonStyle())
            .disabled(game.isStarting)

            Button("gm_flatgrass") {
                game.start(map: .flatgrass)
            }
            .buttonStyle(GModButtonStyle())
            .disabled(game.isStarting)

            Text(game.status)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundColor(
                    game.isReady
                        ? Color(red: 0.48, green: 0.95, blue: 0.50)
                        : Color(white: 0.72)
                )
                .lineLimit(1)

            Button(showConsole ? "Hide Console" : "Console") {
                withAnimation(.easeInOut(duration: 0.16)) {
                    showConsole.toggle()
                }
            }
            .buttonStyle(GModButtonStyle())

            Button(
                game.isSpawnMenuOpen
                    ? "Close Spawn Menu"
                    : "Open Spawn Menu"
            ) {
                game.toggleSpawnMenu()
            }
            .buttonStyle(GModButtonStyle())
            .disabled(!game.isReady || game.isSpawnMenuTransitioning)

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 1) {
                Text("tick \(game.fixedTickCount) / net \(game.lastDeliveredMessages)")
                Text(game.movementStatus)
                    .foregroundColor(
                        game.movementStatus.hasPrefix("Movement blocked")
                            ? Color(red: 1.0, green: 0.72, blue: 0.24)
                            : Color(white: 0.66)
                    )
            }
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundColor(Color(white: 0.66))
            .lineLimit(1)

            Text(
                String(
                    format: "pos %.1f %.1f %.1f",
                    game.playerOrigin.x,
                    game.playerOrigin.y,
                    game.playerOrigin.z
                )
            )
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundColor(Color(white: 0.66))
        }
        .padding(.horizontal, 4)
    }

    private var statusColor: Color {
        switch resultLabel {
        case "PASS": return Color(red: 0.45, green: 0.95, blue: 0.48)
        case "FAIL": return Color(red: 1.0, green: 0.34, blue: 0.34)
        case "RUNNING": return Color(red: 1.0, green: 0.78, blue: 0.28)
        default: return Color(white: 0.78)
        }
    }

    private func color(for kind: GModConsoleModel.Line.Kind) -> Color {
        switch kind {
        case .normal:
            return Color(white: 0.86)
        case .command:
            return Color(red: 0.52, green: 0.73, blue: 1.0)
        case .info:
            return Color(red: 0.44, green: 0.78, blue: 1.0)
        case .success:
            return Color(red: 0.48, green: 0.95, blue: 0.50)
        case .warning:
            return Color(red: 1.0, green: 0.76, blue: 0.30)
        case .error:
            return Color(red: 1.0, green: 0.34, blue: 0.34)
        }
    }

    private func runOfficialTests() {
        guard !isRunning else { return }

        isRunning = true
        resultLabel = "RUNNING"
        console.append("[CONFORMANCE] Starting Lua 5.1 embedded-core suite (_U=true)")

        Task {
            let report = await Lua51ConformanceRunner.runBasicSuite { line in
                Task { @MainActor in
                    console.append(line)
                }
            }

            await MainActor.run {
                console.replaceWithReport(report)
                resultLabel = report.passed ? "PASS" : "FAIL"
                isRunning = false
            }
        }
    }

    private func submitConsole() {
        guard game.isReady else {
            console.submit()
            return
        }
        guard let submission = console.takeSubmission() else { return }
        if case let .source(source) = submission {
            game.executeActiveServer(source)
        }
    }
}

/// The UIKit bridge forwards one identified touch, including the native
/// touchesCancelled terminal phase, without synthesizing VGUI clicks. The
/// Engine owns stock DButton enabled-state and mouse-capture callbacks.
private struct GModSpawnMenuPointerSurface: View {
    typealias Handler = (
        _ x: Double,
        _ y: Double,
        _ viewWidth: Double,
        _ viewHeight: Double,
        _ phase: GMLuaPointerPhase,
        _ timestamp: TimeInterval
    ) -> Void

    let onPointer: Handler

    var body: some View {
        GModTouchInputBridge { sample in
            onPointer(
                sample.x,
                sample.y,
                sample.viewWidth,
                sample.viewHeight,
                sample.phase,
                sample.timestamp
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityLabel("Spawn Menu single-touch pointer surface")
    }
}

private struct GModButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .medium))
            .foregroundColor(Color(white: 0.12))
            .padding(.horizontal, 10)
            .frame(height: 25)
            .background(
                configuration.isPressed
                    ? Color(white: 0.70)
                    : Color(white: 0.84)
            )
            .overlay(Rectangle().stroke(Color(white: 0.35), lineWidth: 1))
    }
}

private struct GModTouchJoystick: View {
    let onChange: (_ forward: Float, _ side: Float) -> Void
    @State private var touchState = GModJoystickTouchState()

    var body: some View {
        GeometryReader { geometry in
            let radius = Double(Swift.max(
                1,
                Swift.min(geometry.size.width, geometry.size.height) * 0.5 - 18
            ))
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.34))
                    .overlay(Circle().stroke(Color.white.opacity(0.55), lineWidth: 1.5))
                Circle()
                    .fill(Color.white.opacity(0.62))
                    .frame(width: 38, height: 38)
                    .offset(
                        x: CGFloat(touchState.output.offsetX),
                        y: CGFloat(touchState.output.offsetY)
                    )
                GModTouchInputBridge { sample in
                    handleTouch(sample, radius: radius)
                }
                .contentShape(Circle())
            }
            .contentShape(Circle())
        }
        .frame(width: 122, height: 122)
        .accessibilityLabel("Movement joystick")
    }

    private func handleTouch(
        _ sample: GModTouchSample,
        radius: Double
    ) {
        var replacement = touchState
        guard let output = replacement.consume(sample, radius: radius) else {
            return
        }
        touchState = replacement
        onChange(output.forward, output.side)
    }
}

private struct GModTouchLookPad: View {
    let onDelta: (_ deltaX: Float, _ deltaY: Float) -> Void
    @State private var touchState = GModLookTouchState()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black.opacity(0.24))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.42), lineWidth: 1.5)
                )
            Image(systemName: "viewfinder")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(Color.white.opacity(0.62))
            GModTouchInputBridge { sample in
                handleTouch(sample)
            }
        }
        .frame(width: 150, height: 112)
        .contentShape(Rectangle())
        .accessibilityLabel("Look control")
    }

    private func handleTouch(_ sample: GModTouchSample) {
        var replacement = touchState
        let delta = replacement.consume(sample)
        touchState = replacement
        if let delta {
            onDelta(delta.x, delta.y)
        }
    }
}
