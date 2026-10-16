import Combine
import Foundation
import GModEngine
import GModGameAssets
import GModGameSession
import GModMetal
import SwiftUI

struct GModDermaMenuPointerOutput: Sendable {
    let wantsTextInput: Bool
    let focusedTextEntry: Int?
    let actions: [GMLuaMenuAction]
}

/// Serializes the mutable MENU Lua state off UIKit's MainActor. Surface
/// snapshot construction and stock panel callbacks can walk the full VGUI
/// tree, so running them inline from a touch callback made UIKit wait before it
/// could deliver the next sample.
actor GModDermaMenuSessionLane {
    private nonisolated let dedicatedThread = GModMenuSessionThread()
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        dedicatedThread.unownedExecutor
    }
    private var session: GMLuaMenuSession?
    private var generation: UInt64 = 0
    private var lastAdvanceTimestamp: TimeInterval?

    func replace(with replacement: GMLuaMenuSession, generation: UInt64) throws {
        dedicatedThread.preconditionIsCurrentWorker()
        guard generation >= self.generation else {
            _ = replacement.close()
            return
        }
        do {
            _ = try replacement.start()
        } catch {
            _ = replacement.close()
            throw error
        }
        _ = session?.close()
        session = replacement
        dedicatedThread.retainForShutdown(replacement)
        self.generation = generation
        lastAdvanceTimestamp = nil
    }

    func removeSession(generation: UInt64) {
        dedicatedThread.preconditionIsCurrentWorker()
        guard generation >= self.generation else { return }
        _ = session?.close()
        session = nil
        dedicatedThread.clearShutdownCleanup()
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

    func updatePermissions(_ snapshot: GMLuaPermissionSnapshot, expectedGeneration: UInt64) throws {
        try requiredSession(expectedGeneration: expectedGeneration).updatePermissions(snapshot)
    }

    func updateLuaErrors(_ errors: [GMLuaMenuLuaError], expectedGeneration: UInt64) throws {
        try requiredSession(expectedGeneration: expectedGeneration).updateLuaErrors(errors)
    }

    func present(
        _ utility: GMLuaMenuUtility,
        viewport: GMLuaViewportSize,
        expectedGeneration: UInt64
    ) throws {
        let session = try requiredSession(expectedGeneration: expectedGeneration)
        _ = try session.updateViewport(width: viewport.width, height: viewport.height)
        try session.present(utility)
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
        let session = try requiredSession(expectedGeneration: expectedGeneration)
        let now = ProcessInfo.processInfo.systemUptime
        if let prior = lastAdvanceTimestamp {
            _ = try session.advance(by: min(0.25, max(0, now - prior)))
        }
        lastAdvanceTimestamp = now
        return try session.renderFrame(
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
        let focusedTextEntry = try session.insertText("")
        return GModDermaMenuPointerOutput(
            wantsTextInput: focusedTextEntry != nil,
            focusedTextEntry: focusedTextEntry,
            actions: session.drainActions()
        )
    }

    func insertText(
        _ text: String,
        focusedTextEntry: Int,
        expectedGeneration: UInt64
    ) throws -> [GMLuaMenuAction] {
        let session = try requiredSession(expectedGeneration: expectedGeneration)
        guard try session.insertText("") == focusedTextEntry else { return [] }
        if text == "\n" || text == "\r" {
            _ = try session.submitFocusedTextEntry()
        } else {
            _ = try session.insertText(text)
        }
        return session.drainActions()
    }

    func deleteTextBackward(focusedTextEntry: Int, expectedGeneration: UInt64) throws {
        let session = try requiredSession(expectedGeneration: expectedGeneration)
        guard try session.insertText("") == focusedTextEntry else { return }
        _ = try session.deleteTextBackward()
    }

    private func requiredSession(
        expectedGeneration: UInt64
    ) throws -> GMLuaMenuSession {
        dedicatedThread.preconditionIsCurrentWorker()
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
    @Published private(set) var focusedTextEntry: Int?

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
        luaErrors: [GMLuaMenuLuaError] = [],
        permissionSessionTransport: GMLuaPermissionSessionTransport?
    ) {
        let configuration = GMLuaLanguageConfiguration(phrases: phrases)
        let permissionIdentity = permissionSessionTransport.map(
            ObjectIdentifier.init
        )
        let requiresNewSession = !hasSession
            || self.mountGeneration != mountGeneration
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
                let diagnosticGeneration = sessionGeneration
                let replacement = runtimeFactory.makeMenuSession(
                    fileSystem: files,
                    initialViewport: viewport,
                    languageConfiguration: configuration,
                    permissionsHost: permissionStore.makeLuaPermissionsHost(),
                    permissionSessionTransport: permissionSessionTransport,
                    logger: { [weak self] line in
                        guard line.contains("[VGUI]"), line.contains("failed:") else { return }
                        Task { @MainActor [weak self] in
                            guard let self, sessionGeneration == diagnosticGeneration else { return }
                            GModAppDiagnosticsStore.shared.record(
                                kind: .luaError,
                                severity: .error,
                                title: "#garryspad.problem.menu",
                                detail: line,
                                source: "MENU VGUI"
                            )
                        }
                    }
                )
                let permissionSnapshot = GMLuaPermissionSnapshot(
                    temporary: permissionStore.collection.temporary,
                    permanent: permissionStore.collection.permanent
                )
                let lane = sessionLane
                let generation = sessionGeneration
                let task = Task { [weak self] in
                    do {
                        try await lane.replace(with: replacement, generation: generation)
                        try await lane.updatePermissions(permissionSnapshot, expectedGeneration: generation)
                        try await lane.updateLuaErrors(luaErrors, expectedGeneration: generation)
                    } catch {
                        guard let self, generation == sessionGeneration else { return }
                        hasSession = false
                        fail(error)
                    }
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
        replaceLuaErrors(luaErrors)
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

    func replacePermissions() {
        guard hasSession else { return }
        let snapshot = GMLuaPermissionSnapshot(
            temporary: permissionStore.collection.temporary,
            permanent: permissionStore.collection.permanent
        )
        let generation = sessionGeneration
        let installation = installationTask
        let previous = mutationTask
        mutationTask = Task { [weak self] in
            await previous?.value
            await installation?.value
            guard let self, generation == sessionGeneration else { return }
            do {
                try await sessionLane.updatePermissions(snapshot, expectedGeneration: generation)
                guard generation == sessionGeneration else { return }
                requestFrame()
            } catch {
                guard generation == sessionGeneration else { return }
                fail(error)
            }
        }
    }

    func replaceLuaErrors(_ errors: [GMLuaMenuLuaError]) {
        guard hasSession else { return }
        let generation = sessionGeneration
        let previous = mutationTask
        let installation = installationTask
        mutationTask = Task { [weak self] in
            await previous?.value
            await installation?.value
            guard let self, generation == sessionGeneration else { return }
            do {
                try await sessionLane.updateLuaErrors(errors, expectedGeneration: generation)
                guard generation == sessionGeneration else { return }
                requestFrame()
            } catch {
                guard generation == sessionGeneration else { return }
                fail(error)
            }
        }
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
        failure = nil
        presentedUtility = utility
        let generation = sessionGeneration
        let activeViewport = viewport
        let installation = installationTask
        let previousMutation = mutationTask
        let task = Task { [weak self] in
            guard let self else { return }
            await previousMutation?.value
            await installation?.value
            do {
                try await sessionLane.present(
                    utility,
                    viewport: activeViewport,
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
                focusedTextEntry = output.focusedTextEntry
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
        guard !text.isEmpty, hasSession, let focus = focusedTextEntry else { return }
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
                    focusedTextEntry: focus,
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
        guard hasSession, let focus = focusedTextEntry else { return }
        let generation = sessionGeneration
        let installation = installationTask
        let previousMutation = mutationTask
        let task = Task { [weak self] in
            guard let self else { return }
            await previousMutation?.value
            await installation?.value
            do {
                try await sessionLane.deleteTextBackward(
                    focusedTextEntry: focus,
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

    func advancePresentationFrame() {
        // No queued passive backlog: a slow Lua/texture frame must finish
        // before the next idle animation capture can be requested.
        guard hasSession, presentedUtility != nil, !buildInFlight else { return }
        requestFrame()
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
        let mutation = mutationTask
        let textRasterizer = runtimeFactory.surfaceTextRasterizer
        Task { [weak self] in
            guard let self else { return }
            await installation?.value
            await mutation?.value
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

    nonisolated static func boundedProblemLines(_ lines: [String]) -> [String] {
        var result: [String] = []
        var remainingBytes = 64 * 1_024
        for line in lines.prefix(256) {
            let separatorBytes = result.isEmpty ? 0 : 1
            guard remainingBytes > separatorBytes else { break }
            let bounded = boundedUTF8Prefix(
                line,
                maximumByteCount: min(1_024, remainingBytes - separatorBytes)
            )
            result.append(bounded)
            remainingBytes -= bounded.utf8.count + separatorBytes
        }
        return result
    }

    nonisolated static func boundedConsoleLines(_ lines: [String]) -> [String] {
        var result: [String] = []
        var remainingBytes = 128 * 1_024
        for line in lines.suffix(512).reversed() {
            let separatorBytes = result.isEmpty ? 0 : 1
            guard remainingBytes > separatorBytes else { break }
            let bounded = boundedUTF8Prefix(
                line,
                maximumByteCount: min(2 * 1_024, remainingBytes - separatorBytes)
            )
            result.append(bounded)
            remainingBytes -= bounded.utf8.count + separatorBytes
        }
        return Array(result.reversed())
    }

    /// Keeps retained MENU text inside its byte budget without cutting a
    /// decoded Unicode scalar in half. The host boundary therefore never
    /// manufactures a replacement glyph (or additional UTF-8 bytes).
    nonisolated private static func boundedUTF8Prefix(
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
                    focusIdentifier: model.focusedTextEntry,
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
            .task {
                // Derma cross-fades and timers must advance without another
                // touch. Stop with the utility view, and keep this capture
                // cadence separate from Metal's display refresh rate.
                while !Task.isCancelled {
                    model.advancePresentationFrame()
                    try? await Task.sleep(nanoseconds: 33_333_333)
                }
            }
        }
        .accessibilityIdentifier("garryspad.derma-menu")
    }
}

#if canImport(UIKit)
import UIKit

@MainActor
struct GModDermaMenuTextInputBridge: UIViewRepresentable {
    let wantsFocus: Bool
    let focusIdentifier: Int?
    let onText: (String) -> Void
    let onDeleteBackward: () -> Void

    func makeUIView(context: Context) -> GModDermaMenuKeyInputView {
        let view = GModDermaMenuKeyInputView(frame: .zero, textContainer: nil)
        view.onText = onText
        view.onDeleteBackward = onDeleteBackward
        return view
    }

    func updateUIView(_ uiView: GModDermaMenuKeyInputView, context: Context) {
        uiView.onText = onText
        uiView.onDeleteBackward = onDeleteBackward
        uiView.updateFocus(wantsFocus: wantsFocus, identifier: focusIdentifier)
        if wantsFocus {
            if !uiView.isFirstResponder {
                DispatchQueue.main.async { [weak uiView] in
                    guard let uiView, uiView.wantsKeyboardFocus else { return }
                    _ = uiView.becomeFirstResponder()
                }
            }
        } else if uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }
}

@MainActor
final class GModDermaMenuKeyInputView: UITextView, UITextViewDelegate {
    var onText: ((String) -> Void)?
    var onDeleteBackward: (() -> Void)?
    private(set) var wantsKeyboardFocus = false
    private var focusIdentifier: Int?
    private var editingNativeBuffer = false

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        delegate = self
        backgroundColor = .clear
        textColor = .clear
        tintColor = .clear
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        isScrollEnabled = false
        textContainerInset = .zero
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func updateFocus(wantsFocus: Bool, identifier: Int?) {
        wantsKeyboardFocus = wantsFocus
        if !wantsFocus || identifier != focusIdentifier {
            editingNativeBuffer = true
            super.unmarkText()
            text = ""
            editingNativeBuffer = false
        }
        focusIdentifier = identifier
    }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        editingNativeBuffer = true
        super.setMarkedText(markedText, selectedRange: selectedRange)
        editingNativeBuffer = false
    }

    override func unmarkText() {
        editingNativeBuffer = true
        super.unmarkText()
        editingNativeBuffer = false
        flushCommittedText()
    }

    override func insertText(_ text: String) {
        editingNativeBuffer = true
        super.insertText(text)
        editingNativeBuffer = false
        flushCommittedText()
    }

    override func deleteBackward() {
        if markedTextRange != nil || hasText {
            editingNativeBuffer = true
            super.deleteBackward()
            editingNativeBuffer = false
        } else if wantsKeyboardFocus {
            onDeleteBackward?()
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        flushCommittedText()
    }

    private func flushCommittedText() {
        guard !editingNativeBuffer, wantsKeyboardFocus,
              markedTextRange == nil, !text.isEmpty else { return }
        let committed = text ?? ""
        editingNativeBuffer = true
        text = ""
        editingNativeBuffer = false
        onText?(committed)
    }
}
#else
@MainActor
struct GModDermaMenuTextInputBridge: View {
    let wantsFocus: Bool
    let focusIdentifier: Int?
    let onText: (String) -> Void
    let onDeleteBackward: () -> Void

    var body: some View { Color.clear }
}
#endif
