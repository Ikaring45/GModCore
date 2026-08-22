import Combine
import Foundation
import GModEngine
import GModGameAssets
import GModMetal
import SwiftUI

/// App-owned presentation adapter for the trusted MENU Lua realm. It owns no
/// menu layout: the shipped Derma panels are the sole source of pixels and
/// pointer behavior. The small host boundary below only turns immutable
/// Surface snapshots into Metal scenes and returns typed MENU requests.
@MainActor
final class GModDermaMenuModel: ObservableObject {
    @Published private(set) var surfaceScene: GModMetalSurfaceScene?
    @Published private(set) var failure: String?
    @Published private(set) var wantsTextInput = false

    private let runtimeFactory: GModAppRuntimeFactory
    private let permissionStore: GModPermissionStore
    private var session: GMLuaMenuSession?
    private var mountGeneration: UInt64?
    private var languageConfiguration: GMLuaLanguageConfiguration?
    private var permissionSessionTransportIdentity: ObjectIdentifier?
    private var viewport = GMLuaViewportSize(width: 1_024, height: 768)
    private var pendingFrame = false
    private var buildInFlight = false
    private var frameRevision: UInt64 = 0
    private var lastAdvanceTimestamp: TimeInterval?
    private var problemLines: [String] = []
    private var consoleLines: [String] = []

    init(
        runtimeFactory: GModAppRuntimeFactory,
        permissionStore: GModPermissionStore
    ) {
        self.runtimeFactory = runtimeFactory
        self.permissionStore = permissionStore
    }

    deinit {
        session?.close()
    }

    func activate(
        mountGeneration: UInt64,
        phrases: [String: String],
        problemLines: [String],
        consoleLines: [String],
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
            session?.close()
            session = nil
            surfaceScene = nil
            failure = nil
            wantsTextInput = false
            pendingFrame = false
            buildInFlight = false
            frameRevision &+= 1
            lastAdvanceTimestamp = nil
            self.problemLines = []
            self.consoleLines = []
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
                session = replacement
            } catch {
                failure = GMLuaRuntime.describe(error)
                return
            }
        }
        replaceProblems(problemLines, requestFrame: false)
        replaceConsoleLines(consoleLines, requestFrame: false)
        requestFrame()
    }

    func deactivate() {
        wantsTextInput = false
        lastAdvanceTimestamp = nil
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
        guard let session else { return }
        do {
            try session.updateProblems(bounded)
            if requestFrame { self.requestFrame() }
        } catch {
            fail(error)
        }
    }

    func replaceConsoleLines(_ lines: [String], requestFrame: Bool = true) {
        let bounded = Self.boundedConsoleLines(lines)
        guard bounded != consoleLines else { return }
        consoleLines = bounded
        guard let session else { return }
        do {
            try session.updateConsoleLines(bounded)
            if requestFrame { self.requestFrame() }
        } catch {
            fail(error)
        }
    }

    func submitPointer(_ sample: GModTouchSample) -> [GMLuaMenuAction] {
        guard let session else { return [] }
        updateViewport(width: sample.viewWidth, height: sample.viewHeight)
        do {
            _ = try session.dispatchPointerEvent(
                x: sample.x,
                y: sample.y,
                phase: sample.phase,
                timestamp: sample.timestamp,
                viewportWidth: viewport.width,
                viewportHeight: viewport.height
            )
            // The Engine returns a focused identifier from `insertText` even
            // when its payload is empty. This keeps keyboard ownership with
            // actual DTextEntry focus rather than treating every panel click
            // as a native text-field request.
            wantsTextInput = try session.insertText("") != nil
            advanceIfNeeded(timestamp: sample.timestamp)
            requestFrame()
            return session.drainActions()
        } catch {
            fail(error)
            return []
        }
    }

    func insertText(_ text: String) {
        guard !text.isEmpty, let session else { return }
        do {
            if text == "\n" || text == "\r" {
                _ = try session.submitFocusedTextEntry()
            } else {
                _ = try session.insertText(text)
            }
            requestFrame()
        } catch {
            fail(error)
        }
    }

    func deleteTextBackward() {
        guard let session else { return }
        do {
            _ = try session.deleteTextBackward()
            requestFrame()
        } catch {
            fail(error)
        }
    }

    func drainActions() -> [GMLuaMenuAction] {
        session?.drainActions() ?? []
    }

    private func advanceIfNeeded(timestamp: TimeInterval) {
        guard let session, timestamp.isFinite else { return }
        defer { lastAdvanceTimestamp = timestamp }
        guard let prior = lastAdvanceTimestamp else { return }
        let delta = min(0.25, max(0, timestamp - prior))
        guard delta > 0 else { return }
        do {
            _ = try session.advance(by: delta)
        } catch {
            fail(error)
        }
    }

    private func requestFrame() {
        pendingFrame = true
        guard !buildInFlight else { return }
        buildNextFrameIfNeeded()
    }

    private func buildNextFrameIfNeeded() {
        guard pendingFrame, !buildInFlight, let session else { return }
        pendingFrame = false
        let snapshot: GMLuaSurfaceFrameSnapshot
        do {
            snapshot = try session.renderFrame(
                viewportWidth: viewport.width,
                viewportHeight: viewport.height
            )
        } catch {
            fail(error)
            return
        }

        buildInFlight = true
        frameRevision &+= 1
        let revision = frameRevision
        let textureResolver = runtimeFactory.surfaceTextureResolver
        let textRasterizer = runtimeFactory.surfaceTextRasterizer
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try GModMetalSurfaceScene(
                        snapshot: snapshot,
                        textureResolver: textureResolver,
                        textRasterizer: textRasterizer
                    )
                }
            }.value
            guard let self, self.frameRevision == revision else { return }
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
                    let actions = model.submitPointer(sample)
                    if !actions.isEmpty {
                        onActions(actions)
                    }
                }
                .contentShape(Rectangle())
                .accessibilityLabel("Garry's PAD Derma menu pointer surface")

                GModDermaMenuTextInputBridge(
                    wantsFocus: model.wantsTextInput,
                    onText: model.insertText,
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
