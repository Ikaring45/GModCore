import Combine
import Foundation
import GModEngine
import GModGameAssets
import GModMetal
import SwiftUI

private struct GModDermaMenuPointerOutput: Sendable {
    let wantsTextInput: Bool
    let actions: [GMLuaMenuAction]
}

/// Serializes the mutable MENU Lua state off UIKit's MainActor. Surface
/// snapshot construction and stock panel callbacks can walk the full VGUI
/// tree, so running them inline from a touch callback made UIKit wait before it
/// could deliver the next sample.
private actor GModDermaMenuSessionLane {
    private var session: GMLuaMenuSession?
    private var generation: UInt64 = 0
    private var lastAdvanceTimestamp: TimeInterval?

    deinit {
        _ = session?.close()
    }

    func replace(with replacement: GMLuaMenuSession, generation: UInt64) {
        guard generation >= self.generation else {
            _ = replacement.close()
            return
        }
        _ = session?.close()
        session = replacement
        self.generation = generation
        lastAdvanceTimestamp = nil
    }

    func removeSession(generation: UInt64) {
        guard generation >= self.generation else { return }
        _ = session?.close()
        session = nil
        self.generation = generation
        lastAdvanceTimestamp = nil
    }

    func synchronize(
        problems: [String],
        consoleLines: [String],
        settings: GMLuaMenuSettingsSnapshot,
        expectedGeneration: UInt64
    ) throws {
        let session = try requiredSession(expectedGeneration: expectedGeneration)
        try session.updateProblems(problems)
        try session.updateConsoleLines(consoleLines)
        try session.updateSettings(settings)
    }

    func updateProblems(_ lines: [String], expectedGeneration: UInt64) throws {
        try requiredSession(expectedGeneration: expectedGeneration)
            .updateProblems(lines)
    }

    func updateConsoleLines(
        _ lines: [String],
        expectedGeneration: UInt64
    ) throws {
        try requiredSession(expectedGeneration: expectedGeneration)
            .updateConsoleLines(lines)
    }

    func updateSettings(
        _ settings: GMLuaMenuSettingsSnapshot,
        expectedGeneration: UInt64
    ) throws {
        try requiredSession(expectedGeneration: expectedGeneration)
            .updateSettings(settings)
    }

    func present(
        _ utility: GMLuaMenuUtility,
        expectedGeneration: UInt64
    ) throws {
        try requiredSession(expectedGeneration: expectedGeneration)
            .present(utility)
    }

    func dismissUtility(expectedGeneration: UInt64) throws {
        try requiredSession(expectedGeneration: expectedGeneration)
            .dismissUtility()
        lastAdvanceTimestamp = nil
    }

    func renderFrame(
        viewport: GMLuaViewportSize,
        expectedGeneration: UInt64
    ) throws -> GMLuaSurfaceFrameSnapshot {
        try requiredSession(expectedGeneration: expectedGeneration).renderFrame(
            viewportWidth: viewport.width,
            viewportHeight: viewport.height
        )
    }

    func submitPointer(
        _ sample: GModTouchSample,
        viewport: GMLuaViewportSize,
        expectedGeneration: UInt64
    ) throws -> GModDermaMenuPointerOutput {
        let session = try requiredSession(expectedGeneration: expectedGeneration)
        _ = try session.dispatchPointerEvent(
            x: sample.x,
            y: sample.y,
            phase: sample.phase,
            timestamp: sample.timestamp,
            viewportWidth: viewport.width,
            viewportHeight: viewport.height
        )
        let wantsTextInput = try session.insertText("") != nil
        if sample.timestamp.isFinite {
            if let prior = lastAdvanceTimestamp {
                let delta = min(0.25, max(0, sample.timestamp - prior))
                if delta > 0 { _ = try session.advance(by: delta) }
            }
            lastAdvanceTimestamp = sample.timestamp
        }
        return GModDermaMenuPointerOutput(
            wantsTextInput: wantsTextInput,
            actions: session.drainActions()
        )
    }

    func insertText(
        _ text: String,
        expectedGeneration: UInt64
    ) throws -> [GMLuaMenuAction] {
        let session = try requiredSession(expectedGeneration: expectedGeneration)
        if text == "\n" || text == "\r" {
            _ = try session.submitFocusedTextEntry()
        } else {
            _ = try session.insertText(text)
        }
        return session.drainActions()
    }

    func deleteTextBackward(expectedGeneration: UInt64) throws {
        _ = try requiredSession(expectedGeneration: expectedGeneration)
            .deleteTextBackward()
    }

    private func requiredSession(
        expectedGeneration: UInt64
    ) throws -> GMLuaMenuSession {
        guard expectedGeneration == generation, let session else {
            throw GMLuaMenuSessionError.notStarted
        }
        return session
    }
}

/// App-owned presentation adapter for the trusted MENU Lua utility realm. The
/// original Home remains DHTML; Settings, Problems, and Console pixels and
/// pointer behavior come from shipped Derma controls over the common Surface
/// bridge. The host only supplies immutable state and handles typed requests.
@MainActor
final class GModDermaMenuModel: ObservableObject {
    @Published private(set) var surfaceScene: GModMetalSurfaceScene?
    @Published private(set) var failure: String?
    @Published private(set) var wantsTextInput = false

    private let runtimeFactory: GModAppRuntimeFactory
    private let permissionStore: GModPermissionStore
    private let sessionLane = GModDermaMenuSessionLane()
    private var installationTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?
    private var hasSession = false
    private var sessionGeneration: UInt64 = 0
    private var mountGeneration: UInt64?
    private var languageConfiguration: GMLuaLanguageConfiguration?
    private var permissionSessionTransportIdentity: ObjectIdentifier?
    private var viewport = GMLuaViewportSize(width: 1_024, height: 768)
    private var pendingFrame = false
    private var buildInFlight = false
    private var frameRevision: UInt64 = 0
    private var problemLines: [String] = []
    private var consoleLines: [String] = []
    private var settings = GMLuaMenuSettingsSnapshot()
    private var presentedUtility: GMLuaMenuUtility?

    init(
        runtimeFactory: GModAppRuntimeFactory,
        permissionStore: GModPermissionStore
    ) {
        self.runtimeFactory = runtimeFactory
        self.permissionStore = permissionStore
    }

    func activate(
        mountGeneration: UInt64,
        phrases: [String: String],
        problemLines: [String],
        consoleLines: [String],
        settings: GMLuaMenuSettingsSnapshot,
        permissionSessionTransport: GMLuaPermissionSessionTransport?
    ) {
        let configuration = GMLuaLanguageConfiguration(phrases: phrases)
        let permissionIdentity = permissionSessionTransport.map(
            ObjectIdentifier.init
        )
        let requiresNewSession = self.mountGeneration != mountGeneration
            || languageConfiguration != configuration
            || permissionSessionTransportIdentity != permissionIdentity
        if requiresNewSession {
            sessionGeneration &+= 1
            hasSession = false
            installationTask = nil
            mutationTask = nil
            surfaceScene = nil
            failure = nil
            wantsTextInput = false
            pendingFrame = false
            buildInFlight = false
            frameRevision &+= 1
            self.problemLines = []
            self.consoleLines = []
            self.settings = GMLuaMenuSettingsSnapshot()
            presentedUtility = nil
            self.mountGeneration = mountGeneration
            languageConfiguration = configuration
            permissionSessionTransportIdentity = permissionIdentity

            do {
                let files = try GMLuaHostDirectoryFileSystem(
                    rootURL: GModGameAssets.clientContentRootURL(),
                    writable: false
                )
                let replacement = runtimeFactory.makeMenuSession(
                    fileSystem: files,
                    initialViewport: viewport,
                    languageConfiguration: configuration,
                    permissionsHost: permissionStore.makeLuaPermissionsHost(),
                    permissionSessionTransport: permissionSessionTransport,
                    logger: { _ in }
                )
                _ = try replacement.start()
                let lane = sessionLane
                let generation = sessionGeneration
                let task = Task {
                    await lane.replace(
                        with: replacement,
                        generation: generation
                    )
                }
                installationTask = task
                hasSession = true
            } catch {
                let lane = sessionLane
                let generation = sessionGeneration
                installationTask = Task {
                    await lane.removeSession(generation: generation)
                }
                failure = GMLuaRuntime.describe(error)
                return
            }
        }
        guard hasSession else { return }
        let boundedProblems = Self.boundedProblemLines(problemLines)
        let boundedConsole = Self.boundedConsoleLines(consoleLines)
        self.problemLines = boundedProblems
        self.consoleLines = boundedConsole
        self.settings = settings
        let generation = sessionGeneration
        let installation = installationTask
        let previousMutation = mutationTask
        let task = Task { [weak self] in
            guard let self else { return }
            await previousMutation?.value
            await installation?.value
            do {
                try await sessionLane.synchronize(
                    problems: boundedProblems,
                    consoleLines: boundedConsole,
                    settings: settings,
                    expectedGeneration: generation
                )
                guard generation == sessionGeneration else { return }
                requestFrame()
            } catch {
                guard generation == sessionGeneration else { return }
                fail(error)
            }
        }
        mutationTask = task
    }

    func deactivate() {
        wantsTextInput = false
    }

    func updateViewport(width: Double, height: Double) {
        guard width.isFinite, height.isFinite,
              width >= 1, height >= 1 else { return }
        let replacement = GMLuaViewportSize(
            width: max(1, Int(width.rounded())),
            height: max(1, Int(height.rounded()))
        )
        guard replacement != viewport else { return }
        viewport = replacement
        requestFrame()
    }

    func replaceProblems(_ lines: [String], requestFrame: Bool = true) {
        let bounded = Self.boundedProblemLines(lines)
        guard bounded != problemLines else { return }
        problemLines = bounded
        guard hasSession else { return }
        let generation = sessionGeneration
        let installation = installationTask
        let previousMutation = mutationTask
        let task = Task { [weak self] in
            guard let self else { return }
            await previousMutation?.value
            await installation?.value
            do {
                try await sessionLane.updateProblems(
                    bounded,
                    expectedGeneration: generation
                )
                guard generation == sessionGeneration else { return }
                if requestFrame { self.requestFrame() }
            } catch {
                guard generation == sessionGeneration else { return }
                fail(error)
            }
        }
        mutationTask = task
    }

    func replaceConsoleLines(_ lines: [String], requestFrame: Bool = true) {
        let bounded = Self.boundedConsoleLines(lines)
        guard bounded != consoleLines else { return }
        consoleLines = bounded
        guard hasSession else { return }
        let generation = sessionGeneration
        let installation = installationTask
        let previousMutation = mutationTask
        let task = Task { [weak self] in
            guard let self else { return }
            await previousMutation?.value
            await installation?.value
            do {
                try await sessionLane.updateConsoleLines(
                    bounded,
                    expectedGeneration: generation
                )
                guard generation == sessionGeneration else { return }
                if requestFrame { self.requestFrame() }
            } catch {
                guard generation == sessionGeneration else { return }
                fail(error)
            }
        }
        mutationTask = task
    }

    func replaceSettings(
        _ replacement: GMLuaMenuSettingsSnapshot,
        requestFrame: Bool = true
    ) {
        guard replacement != settings else { return }
        settings = replacement
        guard hasSession else { return }
        let generation = sessionGeneration
        let installation = installationTask
        let previousMutation = mutationTask
        let task = Task { [weak self] in
            guard let self else { return }
            await previousMutation?.value
            await installation?.value
            do {
                try await sessionLane.updateSettings(
                    replacement,
                    expectedGeneration: generation
                )
                guard generation == sessionGeneration else { return }
                if requestFrame { self.requestFrame() }
            } catch {
                guard generation == sessionGeneration else { return }
                fail(error)
            }
        }
        mutationTask = task
    }

    func present(_ utility: GMLuaMenuUtility) {
        guard hasSession, utility != presentedUtility else { return }
        presentedUtility = utility
        let generation = sessionGeneration
        let installation = installationTask
        let previousMutation = mutationTask
        let task = Task { [weak self] in
            guard let self else { return }
            await previousMutation?.value
            await installation?.value
            do {
                try await sessionLane.present(
                    utility,
                    expectedGeneration: generation
                )
                guard generation == sessionGeneration else { return }
                requestFrame()
            } catch {
                guard generation == sessionGeneration else { return }
                fail(error)
            }
        }
        mutationTask = task
    }

    func dismissUtility() {
        presentedUtility = nil
        wantsTextInput = false
        guard hasSession else { return }
        let generation = sessionGeneration
        let installation = installationTask
        let previousMutation = mutationTask
        let task = Task { [weak self] in
            guard let self else { return }
            await previousMutation?.value
            await installation?.value
            do {
                try await sessionLane.dismissUtility(
                    expectedGeneration: generation
                )
                guard generation == sessionGeneration else { return }
                requestFrame()
            } catch {
                guard generation == sessionGeneration else { return }
                fail(error)
            }
        }
        mutationTask = task
    }

    func submitPointer(
        _ sample: GModTouchSample,
        onActions: @escaping ([GMLuaMenuAction]) -> Void
    ) {
        guard hasSession else { return }
        if sample.viewWidth.isFinite, sample.viewHeight.isFinite,
           sample.viewWidth >= 1, sample.viewHeight >= 1 {
            viewport = GMLuaViewportSize(
                width: max(1, Int(sample.viewWidth.rounded())),
                height: max(1, Int(sample.viewHeight.rounded()))
            )
        }
        let activeViewport = viewport
        let generation = sessionGeneration
        let installation = installationTask
        let previousMutation = mutationTask
        let task = Task { [weak self] in
            guard let self else { return }
            await previousMutation?.value
            await installation?.value
            do {
                let output = try await sessionLane.submitPointer(
                    sample,
                    viewport: activeViewport,
                    expectedGeneration: generation
                )
                guard generation == sessionGeneration else { return }
                wantsTextInput = output.wantsTextInput
                if !output.actions.isEmpty { onActions(output.actions) }
                requestFrame()
            } catch {
                guard generation == sessionGeneration else { return }
                fail(error)
            }
        }
        mutationTask = task
    }

    func insertText(
        _ text: String,
        onActions: @escaping ([GMLuaMenuAction]) -> Void
    ) {
        guard !text.isEmpty, hasSession else { return }
        let generation = sessionGeneration
        let installation = installationTask
        let previousMutation = mutationTask
        let task = Task { [weak self] in
            guard let self else { return }
            await previousMutation?.value
            await installation?.value
            do {
                let actions = try await sessionLane.insertText(
                    text,
                    expectedGeneration: generation
                )
                guard generation == sessionGeneration else { return }
                if !actions.isEmpty { onActions(actions) }
                requestFrame()
            } catch {
                guard generation == sessionGeneration else { return }
                fail(error)
            }
        }
        mutationTask = task
    }

    func deleteTextBackward() {
        guard hasSession else { return }
        let generation = sessionGeneration
        let installation = installationTask
        let previousMutation = mutationTask
        let task = Task { [weak self] in
            guard let self else { return }
            await previousMutation?.value
            await installation?.value
            do {
                try await sessionLane.deleteTextBackward(
                    expectedGeneration: generation
                )
                guard generation == sessionGeneration else { return }
                requestFrame()
            } catch {
                guard generation == sessionGeneration else { return }
                fail(error)
            }
        }
        mutationTask = task
    }

    private func requestFrame() {
        pendingFrame = true
        guard !buildInFlight else { return }
        buildNextFrameIfNeeded()
    }

    private func buildNextFrameIfNeeded() {
        guard pendingFrame, !buildInFlight, hasSession else { return }
        pendingFrame = false
        buildInFlight = true
        frameRevision &+= 1
        let revision = frameRevision
        let generation = sessionGeneration
        let activeViewport = viewport
        let installation = installationTask
        let textureResolver = runtimeFactory.surfaceTextureResolver
        let textRasterizer = runtimeFactory.surfaceTextRasterizer
        Task { [weak self] in
            guard let self else { return }
            await installation?.value
            let snapshot: GMLuaSurfaceFrameSnapshot
            do {
                snapshot = try await sessionLane.renderFrame(
                    viewport: activeViewport,
                    expectedGeneration: generation
                )
            } catch {
                guard generation == sessionGeneration,
                      frameRevision == revision else { return }
                buildInFlight = false
                fail(error)
                return
            }
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try GModMetalSurfaceScene(
                        snapshot: snapshot,
                        textureResolver: textureResolver,
                        textRasterizer: textRasterizer
                    )
                }
            }.value
            guard generation == sessionGeneration,
                  frameRevision == revision else { return }
            self.buildInFlight = false
            switch result {
            case let .success(scene):
                self.surfaceScene = scene
                self.failure = nil
            case let .failure(error):
                self.failure = GMLuaRuntime.describe(error)
            }
            self.buildNextFrameIfNeeded()
        }
    }

    private func fail(_ error: Error) {
        failure = GMLuaRuntime.describe(error)
        wantsTextInput = false
    }

    private static func boundedProblemLines(_ lines: [String]) -> [String] {
        Array(lines.prefix(256)).map { line in
            boundedUTF8Prefix(line, maximumByteCount: 1_024)
        }
    }

    private static func boundedConsoleLines(_ lines: [String]) -> [String] {
        Array(lines.suffix(512)).map { line in
            boundedUTF8Prefix(line, maximumByteCount: 2 * 1_024)
        }
    }

    /// Keeps retained MENU text inside its byte budget without cutting a
    /// decoded Unicode scalar in half. The host boundary therefore never
    /// manufactures a replacement glyph (or additional UTF-8 bytes).
    private static func boundedUTF8Prefix(
        _ value: String,
        maximumByteCount: Int
    ) -> String {
        let bytes = Array(value.utf8)
        guard bytes.count > maximumByteCount else { return value }
        var end = maximumByteCount
        while end > 0 {
            if let prefix = String(bytes: bytes[..<end], encoding: .utf8) {
                return prefix
            }
            end -= 1
        }
        return ""
    }
}

/// The real Metal Surface scene and a UIKit keyboard proxy are overlaid in
/// one coordinate space, so DFrame hit-testing and touch resize remain in
/// logical VGUI pixels on Retina iPad displays.
@MainActor
struct GModDermaMenuSurface: View {
    @ObservedObject var model: GModDermaMenuModel
    let preferredFramesPerSecond: Int
    let onActions: ([GMLuaMenuAction]) -> Void
    @State private var rendererStats = "MENU Derma"

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                GModMetalView(
                    stats: $rendererStats,
                    surfaceScene: model.surfaceScene,
                    preferredFramesPerSecond: preferredFramesPerSecond
                )
                .background(Color.black)

                GModTouchInputBridge { sample in
                    model.submitPointer(sample) { actions in
                        if !actions.isEmpty {
                            onActions(actions)
                        }
                    }
                }
                .contentShape(Rectangle())
                .accessibilityLabel("Garry's PAD Derma menu pointer surface")

                GModDermaMenuTextInputBridge(
                    wantsFocus: model.wantsTextInput,
                    onText: { text in
                        model.insertText(text) { actions in
                            if !actions.isEmpty {
                                onActions(actions)
                            }
                        }
                    },
                    onDeleteBackward: model.deleteTextBackward
                )
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
            }
            .onAppear {
                model.updateViewport(
                    width: Double(geometry.size.width),
                    height: Double(geometry.size.height)
                )
            }
            .onChange(of: geometry.size) { size in
                model.updateViewport(
                    width: Double(size.width),
                    height: Double(size.height)
                )
            }
        }
        .accessibilityIdentifier("garryspad.derma-menu")
    }
}

#if canImport(UIKit)
import UIKit

@MainActor
private struct GModDermaMenuTextInputBridge: UIViewRepresentable {
    let wantsFocus: Bool
    let onText: (String) -> Void
    let onDeleteBackward: () -> Void

    func makeUIView(context: Context) -> GModDermaMenuKeyInputView {
        let view = GModDermaMenuKeyInputView()
        view.onText = onText
        view.onDeleteBackward = onDeleteBackward
        return view
    }

    func updateUIView(_ uiView: GModDermaMenuKeyInputView, context: Context) {
        uiView.onText = onText
        uiView.onDeleteBackward = onDeleteBackward
        if wantsFocus {
            if !uiView.isFirstResponder {
                DispatchQueue.main.async { _ = uiView.becomeFirstResponder() }
            }
        } else if uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }
}

@MainActor
private final class GModDermaMenuKeyInputView: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onDeleteBackward: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { false }

    func insertText(_ text: String) {
        onText?(text)
    }

    func deleteBackward() {
        onDeleteBackward?()
    }
}
#else
@MainActor
private struct GModDermaMenuTextInputBridge: View {
    let wantsFocus: Bool
    let onText: (String) -> Void
    let onDeleteBackward: () -> Void

    var body: some View { Color.clear }
}
#endif
