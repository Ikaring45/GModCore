import SwiftUI
import Foundation
import GModEngine
import GModGameAssets
import GModMetal
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

struct GModMainViewChromePolicy: Equatable, Sendable {
    let developerDiagnosticsEnabled: Bool

    init(developerDiagnosticsEnabled: Bool = false) {
        self.developerDiagnosticsEnabled = developerDiagnosticsEnabled
    }

    var showsDeveloperChrome: Bool { developerDiagnosticsEnabled }
    var showsRendererHeader: Bool { developerDiagnosticsEnabled }
    var showsDebugMapControls: Bool { developerDiagnosticsEnabled }
    var showsRuntimeStatistics: Bool { developerDiagnosticsEnabled }
    var showsConsole: Bool { developerDiagnosticsEnabled }
    var showsPlayfieldDebugBorder: Bool { developerDiagnosticsEnabled }
    /// Keep incomplete renderer geometry behind an opaque loading surface.
    /// The game model clears `isStarting` only after Metal reports the first
    /// completed world frame, so ordinary play never exposes a bootstrap
    /// triangle or other diagnostic fallback.
    var hidesWorldUntilFirstFrame: Bool { true }
}

/// Deterministic iPad overlay metrics in logical points. Keeping this separate
/// from SwiftUI makes the portrait/landscape and safe-area contract testable
/// without guessing from a single screenshot size.
struct GModInGameOverlayLayout: Equatable, Sendable {
    let isPortrait: Bool
    let leadingInset: Double
    let trailingInset: Double
    let topInset: Double
    let bottomInset: Double
    let joystickDiameter: Double
    let joystickKnobDiameter: Double
    let lookPadWidth: Double
    let lookPadHeight: Double
    let jumpDiameter: Double
    let heldActionDiameter: Double
    let utilityButtonSize: Double
    let utilitySpacing: Double
    let actionSpacing: Double

    init(
        width: Double,
        height: Double,
        safeTop: Double = 0,
        safeLeading: Double = 0,
        safeBottom: Double = 0,
        safeTrailing: Double = 0
    ) {
        let resolvedWidth = Swift.max(1, width)
        let resolvedHeight = Swift.max(1, height)
        let shortSide = Swift.min(resolvedWidth, resolvedHeight)
        isPortrait = resolvedHeight > resolvedWidth

        let edge = Self.clamp(shortSide * 0.020, minimum: 14, maximum: 24)
        leadingInset = Swift.max(0, safeLeading) + edge
        trailingInset = Swift.max(0, safeTrailing) + edge
        topInset = Swift.max(0, safeTop) + edge
        bottomInset = Swift.max(0, safeBottom) + edge

        joystickDiameter = Self.clamp(
            shortSide * (isPortrait ? 0.125 : 0.105),
            minimum: 96,
            maximum: 116
        )
        joystickKnobDiameter = Self.clamp(
            joystickDiameter * 0.31,
            minimum: 32,
            maximum: 37
        )
        lookPadWidth = Self.clamp(
            resolvedWidth * (isPortrait ? 0.240 : 0.150),
            minimum: 168,
            maximum: 210
        )
        lookPadHeight = Self.clamp(
            lookPadWidth * 0.54,
            minimum: 98,
            maximum: 118
        )
        jumpDiameter = Self.clamp(
            shortSide * 0.064,
            minimum: 60,
            maximum: 68
        )
        heldActionDiameter = Self.clamp(
            shortSide * 0.050,
            minimum: 44,
            maximum: 52
        )
        utilityButtonSize = Self.clamp(
            shortSide * 0.047,
            minimum: 46,
            maximum: 50
        )
        utilitySpacing = Self.clamp(shortSide * 0.008, minimum: 8, maximum: 12)
        actionSpacing = Self.clamp(shortSide * 0.012, minimum: 10, maximum: 14)
    }

    private static func clamp(
        _ value: Double,
        minimum: Double,
        maximum: Double
    ) -> Double {
        Swift.max(minimum, Swift.min(maximum, value))
    }
}

private enum GModPendingContentManagementAction: Equatable, Sendable {
    case chooseZIP
    case unmountZIP
    case revalidateZIP
}

@MainActor
public struct GModMainView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var console: GModConsoleModel
    @StateObject private var game: GModGameSessionModel
    @StateObject private var content: GModPlaygroundContentModel
    @StateObject private var developerDiagnostics:
        GModDeveloperDiagnosticsSettingsStore
    @StateObject private var localizationSelection:
        GModMenuLocalizationSelectionStore
    @StateObject private var menuAudio: GModMenuAudioSettingsStore
    @StateObject private var inputVideoSettings: GModInputVideoSettingsStore
    @StateObject private var contentSettings: GModContentSettingsStore
    @StateObject private var diagnostics: GModAppDiagnosticsStore
    @StateObject private var permissions: GModPermissionStore
    @State private var stats = "Starting ARM engine..."
    @State private var isRunning = false
    @State private var resultLabel = "READY"
    @State private var showConsole = false
    @State private var presentation = GModGamePresentationState()
    @State private var showingQuitUnavailable = false
    @State private var isChoosingContentPack = false
    @State private var activeUtilityWindow: GModUtilityWindowKind?
    @State private var pendingContentManagementAction:
        GModPendingContentManagementAction?
    @State private var contentActionAfterDisconnect:
        GModPendingContentManagementAction?
    @State private var showingContentChangeConfirmation = false

    private var chromePolicy: GModMainViewChromePolicy {
        GModMainViewChromePolicy(
            developerDiagnosticsEnabled: developerDiagnostics.isEnabled
        )
    }

    private var localizedLoadingTask: String {
        if game.startFailure != nil {
            return localizationSelection.snapshot.appText(.loadingFailed)
        }
        return localizationSelection.snapshot.loadingStageText(
            game.loadingProgress.stage
        )
    }

    private var localizedSandboxTitle: String {
        localizationSelection.snapshot.phrase("sandbox")
    }

    private var localizedSpawnMenuButton: String {
        localizationSelection.snapshot.appText(
            game.isSpawnMenuOpen
                ? .closeSpawnMenuButton
                : .spawnMenuButton
        )
    }

    private var localizedPauseButton: String {
        localizationSelection.snapshot.appText(.pauseButton)
    }

    private var localizedJumpButton: String {
        localizationSelection.snapshot.appText(.jumpButton)
    }

    private var localizedFireButton: String {
        localizationSelection.snapshot.appText(.fireButton)
    }

    private var localizedAlternateFireButton: String {
        localizationSelection.snapshot.appText(.alternateFireButton)
    }

    private var localizedUseButton: String {
        localizationSelection.snapshot.appText(.useButton)
    }

    private var localizedContextMenuButton: String {
        localizationSelection.snapshot.appText(
            game.isContextMenuOpen
                ? .closeContextMenuButton
                : .contextMenuButton
        )
    }

    public init() {
        let factory = GModAppRuntimeFactory()
        let contentSettingsStore = GModContentSettingsStore.shared
        let audioSettingsStore = GModMenuAudioSettingsStore.shared
        let inputVideoSettingsStore = GModInputVideoSettingsStore.shared
        let diagnosticsStore = GModAppDiagnosticsStore.shared
        let permissionStore = GModPermissionStore.shared
        let consoleModel = GModConsoleModel(runtimeFactory: factory)
        _console = StateObject(
            wrappedValue: consoleModel
        )
        _game = StateObject(
            wrappedValue: GModGameSessionModel(
                runtimeFactory: factory,
                audioSettingsStore: audioSettingsStore,
                inputVideoSettings: inputVideoSettingsStore,
                diagnosticsStore: diagnosticsStore,
                logSink: { [weak consoleModel] line in
                    consoleModel?.append(line)
                }
            )
        )
        _content = StateObject(
            wrappedValue: GModPlaygroundContentModel(
                runtimeFactory: factory,
                settingsStore: contentSettingsStore
            )
        )
        _developerDiagnostics = StateObject(
            wrappedValue: GModDeveloperDiagnosticsSettingsStore.shared
        )
        _localizationSelection = StateObject(
            wrappedValue: GModMenuLocalizationSelectionStore.shared
        )
        _menuAudio = StateObject(
            wrappedValue: audioSettingsStore
        )
        _inputVideoSettings = StateObject(
            wrappedValue: inputVideoSettingsStore
        )
        _contentSettings = StateObject(
            wrappedValue: contentSettingsStore
        )
        _diagnostics = StateObject(
            wrappedValue: diagnosticsStore
        )
        _permissions = StateObject(
            wrappedValue: permissionStore
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
                if chromePolicy.showsRendererHeader {
                    rendererHeader
                }
                if chromePolicy.showsDebugMapControls {
                    gameControls
                }

                ZStack(alignment: .bottom) {
                    GModMetalView(
                        stats: $stats,
                        worldScene: game.worldScene,
                        surfaceScene: game.surfaceScene,
                        preferredFramesPerSecond:
                            inputVideoSettings.preferredFramesPerSecond,
                        onFrame: { [frameTarget] request in
                            frameTarget.submitFrame(request)
                        },
                        onWorldFrameEvent: { [frameTarget] event in
                            frameTarget.submitWorldFrameEvent(event)
                        }
                    )
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: .infinity)
                    .background(Color.black)
                    // Rendering continues at alpha zero so the first-frame
                    // completion gate can advance, while incomplete bootstrap
                    // geometry can never flash through the loading document.
                    .opacity(
                        chromePolicy.hidesWorldUntilFirstFrame && game.isStarting
                            ? 0
                            : 1
                    )
                    .overlay {
                        if chromePolicy.showsPlayfieldDebugBorder {
                            Rectangle().stroke(
                                Color(red: 0.30, green: 0.31, blue: 0.32),
                                lineWidth: 1
                            )
                        }
                    }

                    if game.isClientMenuOpen && !game.isInputSuspended {
                        GModSpawnMenuPointerSurface {
                            x, y, width, height, phase, timestamp in
                            game.submitClientMenuPointer(
                                x: x,
                                y: y,
                                viewWidth: width,
                                viewHeight: height,
                                phase: phase,
                                timestamp: timestamp
                            )
                        }
                    }

                    GeometryReader { geometry in
                        let safeArea = geometry.safeAreaInsets
                        let layout = GModInGameOverlayLayout(
                            width: Double(geometry.size.width),
                            height: Double(geometry.size.height),
                            safeTop: Double(safeArea.top),
                            safeLeading: Double(safeArea.leading),
                            safeBottom: Double(safeArea.bottom),
                            safeTrailing: Double(safeArea.trailing)
                        )

                        ZStack {
                            if game.acceptsWorldInput {
                                VStack {
                                    Spacer(minLength: 0)
                                    HStack(alignment: .bottom) {
                                        GModTouchJoystick(
                                            diameter: layout.joystickDiameter,
                                            knobDiameter: layout.joystickKnobDiameter
                                        ) { forward, side in
                                            game.setMovementAxes(
                                                forward: forward,
                                                side: side
                                            )
                                        }

                                        Spacer(minLength: 44)

                                        VStack(spacing: CGFloat(layout.actionSpacing)) {
                                            HStack(spacing: 8) {
                                                GModTouchActionButton(
                                                    label: localizedFireButton,
                                                    diameter: layout.heldActionDiameter,
                                                    accessibilityIdentifier:
                                                        "garryspad.control.attack"
                                                ) { pressed in
                                                    game.setWorldActionButton(
                                                        .attack,
                                                        pressed: pressed
                                                    )
                                                }
                                                GModTouchActionButton(
                                                    label: localizedAlternateFireButton,
                                                    diameter: layout.heldActionDiameter,
                                                    accessibilityIdentifier:
                                                        "garryspad.control.attack2"
                                                ) { pressed in
                                                    game.setWorldActionButton(
                                                        .attack2,
                                                        pressed: pressed
                                                    )
                                                }
                                                GModTouchActionButton(
                                                    label: localizedUseButton,
                                                    diameter: layout.heldActionDiameter,
                                                    accessibilityIdentifier:
                                                        "garryspad.control.use"
                                                ) { pressed in
                                                    game.setWorldActionButton(
                                                        .use,
                                                        pressed: pressed
                                                    )
                                                }
                                            }

                                            GModTouchActionButton(
                                                label: localizedJumpButton,
                                                diameter: layout.jumpDiameter,
                                                accessibilityIdentifier:
                                                    "garryspad.control.jump"
                                            ) { pressed in
                                                game.setJumpPressed(pressed)
                                            }

                                            GModTouchLookPad(
                                                width: layout.lookPadWidth,
                                                height: layout.lookPadHeight
                                            ) { deltaX, deltaY in
                                                game.adjustLook(
                                                    deltaX: deltaX,
                                                    deltaY: deltaY
                                                )
                                            }
                                        }
                                    }
                                    .padding(.leading, CGFloat(layout.leadingInset))
                                    .padding(.trailing, CGFloat(layout.trailingInset))
                                    .padding(.bottom, CGFloat(layout.bottomInset))
                                }
                                .opacity(game.isReady ? 1 : 0)
                                .allowsHitTesting(game.acceptsWorldInput)
                            }

                            VStack {
                                HStack(spacing: CGFloat(layout.utilitySpacing)) {
                                    Spacer(minLength: 0)

                                    Button("Q") {
                                        game.toggleSpawnMenu()
                                    }
                                    .buttonStyle(GModInGameButtonStyle(
                                        size: layout.utilityButtonSize,
                                        isActive: game.isSpawnMenuOpen
                                    ))
                                    .disabled(
                                        !game.isReady ||
                                            game.isClientMenuTransitioning ||
                                            game.isInputSuspended
                                    )
                                    .accessibilityLabel(
                                        Text(localizedSpawnMenuButton)
                                    )
                                    .accessibilityIdentifier(
                                        "garryspad.control.spawn-menu"
                                    )

                                    Button("C") {
                                        game.toggleContextMenu()
                                    }
                                    .buttonStyle(GModInGameButtonStyle(
                                        size: layout.utilityButtonSize,
                                        isActive: game.isContextMenuOpen
                                    ))
                                    .disabled(
                                        !game.isReady ||
                                            game.isClientMenuTransitioning ||
                                            game.isInputSuspended
                                    )
                                    .accessibilityLabel(
                                        Text(localizedContextMenuButton)
                                    )
                                    .accessibilityIdentifier(
                                        "garryspad.control.context-menu"
                                    )

                                    Button {
                                        handlePresentationEvent(
                                            .pauseRequested(
                                                game.continuitySnapshot
                                            )
                                        )
                                    } label: {
                                        Image(systemName: "pause.fill")
                                    }
                                    .buttonStyle(GModInGameButtonStyle(
                                        size: layout.utilityButtonSize,
                                        isActive: false
                                    ))
                                    .disabled(
                                        !game.isReady ||
                                            game.isClientMenuTransitioning ||
                                            game.isInputSuspended
                                    )
                                    .accessibilityLabel(
                                        Text(localizedPauseButton)
                                    )
                                    .accessibilityIdentifier(
                                        "garryspad.control.pause"
                                    )
                                }
                                .padding(.top, CGFloat(layout.topInset))
                                .padding(.trailing, CGFloat(layout.trailingInset))
                                Spacer(minLength: 0)
                            }
                            .opacity(game.isReady ? 1 : 0)
                            .allowsHitTesting(
                                game.isReady && !game.isInputSuspended
                            )
                        }
                    }

                    if chromePolicy.showsRuntimeStatistics {
                        VStack {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(game.surfaceStatus)
                                if game.isClientMenuOpen {
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
                }
                .frame(minHeight: 320)

                if chromePolicy.showsConsole && showConsole {
                    consoleWindow
                        .frame(height: 310)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(chromePolicy.showsDeveloperChrome ? 14 : 0)

            contentOverlay

            utilityOverlay

            if game.isStarting {
                loadingOverlay
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            game.setHostPopupPresented(activeUtilityWindow != nil)
            if scenePhase == .active && !presentation.showsHomeMenu {
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
                if presentation.showsHomeMenu {
                    game.suspendInput()
                } else {
                    game.resumeInput()
                }
            case .inactive, .background:
                game.suspendInput()
            @unknown default:
                game.suspendInput()
            }
        }
        .onChange(of: activeUtilityWindow) { window in
            game.setHostPopupPresented(window != nil)
        }
        .alert(
            localizationSelection.snapshot.phrase("quit"),
            isPresented: $showingQuitUnavailable
        ) {
            Button(
                localizationSelection.snapshot.appText(.okayButton),
                role: .cancel
            ) {}
        } message: {
            Text(
                localizationSelection.snapshot.appText(
                    .quitUnavailableMessage
                )
            )
        }
        .confirmationDialog(
            localizationSelection.snapshot.phrase(
                "garryspad.content.change-confirm-title"
            ),
            isPresented: $showingContentChangeConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                localizationSelection.snapshot.phrase(
                    "garryspad.content.change-confirm"
                ),
                role: .destructive
            ) {
                confirmContentManagementAction()
            }
            Button(
                localizationSelection.snapshot.phrase(
                    "garryspad.control.cancel"
                ),
                role: .cancel
            ) {
                pendingContentManagementAction = nil
            }
        } message: {
            Text(localizationSelection.snapshot.phrase(
                "garryspad.content.change-confirm-detail"
            ))
        }
        .fileImporter(
            isPresented: $isChoosingContentPack,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                content.selectContentPack(url: url)
            case let .failure(error):
                content.reportSelectionFailure(error)
            }
        }
        .onChange(of: game.startFailure) { failure in
            guard let failure else { return }
            handlePresentationEvent(.startFailed(failure))
        }
        .onChange(of: game.isDisconnecting) { isDisconnecting in
            guard !isDisconnecting,
                  let action = contentActionAfterDisconnect else {
                return
            }
            contentActionAfterDisconnect = nil
            performContentManagementAction(action)
        }
    }

    @ViewBuilder
    private var loadingOverlay: some View {
        ZStack {
            if case let .ready(pack, _, _) = content.state,
               let map = game.loadingMap {
                GModStockLoadingView(
                    pack: pack,
                    assetSource: content.assetSource,
                    map: map,
                    languageCode: localizationSelection.snapshot.code,
                    gameModeTitle: localizedSandboxTitle,
                    status: localizedLoadingTask,
                    task: localizedLoadingTask,
                    progress: game.loadingProgress
                )
                .ignoresSafeArea()
                .transition(.opacity)
            } else {
                ZStack {
                    Color.black.ignoresSafeArea()
#if canImport(UIKit)
                    if case let .ready(_, background, _) = content.state,
                       let image = UIImage(data: background) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .ignoresSafeArea()
                            .overlay(Color.black.opacity(0.34))
                    }
#endif
                    VStack {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Garry's PAD")
                                    .font(.system(size: 24, weight: .bold))
                                Text(game.loadingMap?.rawValue ?? "")
                                Text(localizedSandboxTitle)
                            }
                            .foregroundColor(.white)
                            Spacer()
                        }
                        .padding(28)

                        Spacer()

                        Text("g")
                            .font(.system(size: 88, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .frame(width: 132, height: 132)
                            .background(Color.black.opacity(0.48))
                            .clipShape(RoundedRectangle(cornerRadius: 24))

                        Spacer()
                        VStack(alignment: .trailing, spacing: 7) {
                            HStack {
                                Text(localizedLoadingTask)
                                Spacer()
                                Text("\(game.loadingProgress.percentComplete)%")
                                    .monospacedDigit()
                            }
                            ProgressView(
                                value: game.loadingProgress.fractionCompleted
                            )
                            .tint(.white)
                        }
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 18)
                        .background(Color.black.opacity(0.68))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .transition(.opacity)
            }

            if let failure = game.startFailure {
                startFailureRecoveryOverlay(failure)
            }
        }
        .accessibilityIdentifier("garryspad.loading")
    }

    private func startFailureRecoveryOverlay(
        _ failure: GModGameStartFailure
    ) -> some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()
            VStack(spacing: 14) {
                Text(localizationSelection.snapshot.appText(.loadingFailed))
                    .font(.title2.weight(.semibold))
                    .foregroundColor(.white)
                Text(failure.detail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white.opacity(0.78))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 620)
                Button(
                    localizationSelection.snapshot.appText(
                        .returnHomeAfterFailure
                    )
                ) {
                    handlePresentationEvent(.returnHomeAfterStartFailure)
                }
                .buttonStyle(GModButtonStyle())
                .accessibilityIdentifier("garryspad.loading.return-home")
            }
            .padding(28)
            .background(Color(red: 0.10, green: 0.11, blue: 0.12))
            .overlay(
                Rectangle().stroke(Color.white.opacity(0.30), lineWidth: 1)
            )
            .padding(32)
        }
        .zIndex(1_000)
    }

    @ViewBuilder
    private var contentOverlay: some View {
        switch content.state {
        case .loading:
            contentPackNotice(
                title: localizationSelection.snapshot.phrase(
                    "garryspad.content.opening-title"
                ),
                detail: localizationSelection.snapshot.phrase(
                    "garryspad.content.opening-detail"
                ),
                primaryActionTitle: nil,
                showsForgetAction: false
            )
        case .missing:
            contentPackNotice(
                title: localizationSelection.snapshot.phrase(
                    "garryspad.content.choose-title"
                ),
                detail: localizationSelection.snapshot.phrase(
                    "garryspad.content.choose-detail"
                ),
                primaryActionTitle: localizationSelection.snapshot.phrase(
                    "garryspad.content.choose-action"
                ),
                showsForgetAction: false
            )
        case let .failed(message):
            contentPackNotice(
                title: localizationSelection.snapshot.phrase(
                    "garryspad.content.failed-title"
                ),
                detail: message,
                primaryActionTitle: localizationSelection.snapshot.phrase(
                    "garryspad.content.choose-another"
                ),
                showsForgetAction: true
            )
        case let .ready(pack, background, logo):
            if presentation.showsHomeMenu {
                GModHomeMenuView(
                    pack: pack,
                    assetSource: content.assetSource,
                    backgroundJPEG: background,
                    logoPNG: logo,
                    onSelectMap: { map in
                        handlePresentationEvent(
                            .validatedMapSelected(map),
                            contentPackURL: pack.archiveURL
                        )
                    },
                    isInGame: game.hasActiveSession,
                    preferredLanguageCode: localizationSelection.snapshot.code,
                    menuBackgroundsEnabled: contentSettings.menuBackgroundsEnabled,
                    problemCount: currentProblemSnapshot.problems.count,
                    problemSeverity: currentProblemSeverity,
                    onMenuAction: { action in
                        handlePresentationEvent(
                            .homeMenuAction(action),
                            contentPackURL: pack.archiveURL
                        )
                    },
                    onLanguageChange: { snapshot in
                        publishHomeLanguageSelection(snapshot, from: pack)
                    },
                    onDiagnostic: { record in diagnostics.record(record) },
                    audioController: game.audioController
                )
                // The coordinator owns an immutable WKURLSchemeHandler,
                // language catalog and audio resolver for exactly one
                // validated mount. Recreate that complete boundary only after
                // ContentModel commits a successful candidate; failed
                // replacements intentionally preserve the current identity.
                .id(content.activeMountGeneration)
                .ignoresSafeArea()
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var utilityOverlay: some View {
        switch activeUtilityWindow {
        case .options:
            GModOptionsWindow(
                localization: localizationSelection.snapshot,
                audio: menuAudio,
                inputVideo: inputVideoSettings,
                developerDiagnostics: developerDiagnostics,
                contentSettings: contentSettings,
                content: content,
                permissions: permissions,
                currentMap: game.activeMap?.rawValue,
                onClose: { activeUtilityWindow = nil },
                onLanguageChange: { @MainActor languageCode in
                    selectLanguageFromOptions(languageCode)
                },
                onChooseZIP: {
                    requestContentManagementAction(.chooseZIP)
                },
                onUnmountZIP: {
                    requestContentManagementAction(.unmountZIP)
                },
                onRevalidateZIP: {
                    requestContentManagementAction(.revalidateZIP)
                },
                onClearCaches: { content.clearCaches() },
                onDumpDiagnostics: dumpContentDiagnostics
            )
            .zIndex(500)

        case .problems:
            GModProblemsWindow(
                localization: localizationSelection.snapshot,
                snapshot: currentProblemSnapshot,
                onClose: { activeUtilityWindow = nil },
                onRevokePermission: revokePermission
            )
            .zIndex(500)

        case nil:
            EmptyView()
        }
    }

    private func contentPackNotice(
        title: String,
        detail: String,
        primaryActionTitle: String?,
        showsForgetAction: Bool
    ) -> some View {
        ZStack {
            Color(red: 0.07, green: 0.08, blue: 0.09).ignoresSafeArea()
            VStack(spacing: 16) {
                Text("Garry's PAD")
                    .font(.system(size: 46, weight: .black, design: .rounded))
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(detail)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 620)
                    .accessibilityIdentifier("garryspad.content.status")
                if let warning = content.persistenceWarning {
                    Text(warning)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color(red: 1.0, green: 0.76, blue: 0.30))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 620)
                }
                if let primaryActionTitle {
                    Button(primaryActionTitle) {
                        isChoosingContentPack = true
                    }
                    .buttonStyle(GModButtonStyle())
                    .accessibilityIdentifier("garryspad.content.choose")
                } else if let verification = content.verificationState {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(localizationSelection.snapshot.phrase(
                            verification.stage.localizationKey
                        ))
                        .font(.system(size: 12, weight: .semibold))
                        ProgressView(value: verification.fractionCompleted)
                            .tint(Color(red: 0.2, green: 0.67, blue: 1))
                        HStack {
                            Text(
                                "\(verification.progress.completedFileCount)/" +
                                    "\(verification.progress.totalFileCount) " +
                                    localizationSelection.snapshot.phrase(
                                        "garryspad.content.verification.files"
                                    )
                            )
                            Spacer()
                            Text(
                                "\(Int(verification.fractionCompleted * 100))%"
                            )
                            Text(
                                "\(verification.progress.completedByteCount)/" +
                                    "\(verification.progress.totalByteCount) " +
                                    localizationSelection.snapshot.phrase(
                                        "garryspad.content.verification.bytes"
                                    )
                            )
                        }
                        .font(.system(size: 10).monospacedDigit())
                        if let path = verification.progress.currentPath {
                            Text(path)
                                .font(.system(size: 10, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Button(localizationSelection.snapshot.phrase(
                            "garryspad.content.cancel-validation"
                        )) {
                            content.cancelValidation()
                        }
                        .buttonStyle(GModButtonStyle())
                        .accessibilityIdentifier(
                            "garryspad.content.cancel-validation"
                        )
                    }
                    .frame(maxWidth: 620)
                    .accessibilityIdentifier("garryspad.content.verification")
                } else {
                    VStack(spacing: 12) {
                        ProgressView().tint(.white)
                        Button(localizationSelection.snapshot.phrase(
                            "garryspad.content.cancel-validation"
                        )) {
                            content.cancelValidation()
                        }
                        .buttonStyle(GModButtonStyle())
                        .accessibilityIdentifier(
                            "garryspad.content.cancel-validation"
                        )
                    }
                }
                if showsForgetAction {
                    Button(localizationSelection.snapshot.phrase(
                        "garryspad.content.forget"
                    )) {
                        content.forgetSelection()
                    }
                    .buttonStyle(GModButtonStyle())
                    .accessibilityIdentifier("garryspad.content.forget")
                }
            }
            .padding(30)
        }
    }

    private var activeContentPackURL: URL? {
        guard case let .ready(pack, _, _) = content.state else { return nil }
        return pack.archiveURL
    }

    private func handlePresentationEvent(
        _ event: GModGamePresentationEvent,
        contentPackURL: URL? = nil
    ) {
        if case .homeMenuAction(.openOptions) = event {
            activeUtilityWindow = .options
            return
        }
        if case .homeMenuAction(.openProblems) = event {
            activeUtilityWindow = .problems
            return
        }
        var replacement = presentation
        let effects = replacement.reduce(event)
        presentation = replacement

        for effect in effects {
            switch effect {
            case .suspendForPauseMenu:
                game.presentPauseMenu()

            case .resumeExistingSession:
                game.resumeInput()

            case let .startMap(map):
                if game.hasActiveSession {
                    permissions.clearTemporaryPermissions()
                }
                game.resumeInput()
                game.start(
                    map: map,
                    contentPackURL: contentPackURL ?? activeContentPackURL,
                    languageCode: localizationSelection.snapshot.code,
                    languagePhrases: localizationSelection.snapshot.phrases
                )

            case .disconnectSession:
                permissions.clearTemporaryPermissions()
                game.disconnect()

            case .abandonFailedStart:
                permissions.clearTemporaryPermissions()
                game.returnToHomeAfterStartFailure()

            case .presentQuitUnavailable:
                showingQuitUnavailable = true

            case .awaitValidatedMapSelection:
                // GModHomeMenuView follows this raw command with its validated
                // bundled-map callback. Starting here would process it twice.
                break
            }
        }
    }

    private var currentProblemSnapshot: GModAppProblemSnapshot {
        GModAppProblemSnapshotBuilder.build(
            retained: diagnostics.records,
            gameLogs: game.recentLogs,
            consoleLogs: console.lines.map(\.text),
            worldScene: game.worldScene,
            surfaceDiagnostics: game.surfaceDiagnostics,
            contentError: content.lastError,
            rendererFailure: game.lastRendererFailure,
            startFailure: game.startFailure,
            permissionCollection: permissions.collection,
            permissionPersistenceError: permissions.persistenceError
        )
    }

    private func revokePermission(_ record: GModAppPermissionRecord) {
        do {
            _ = try permissions.revoke(
                record.permission,
                for: record.serverIdentifier
            )
        } catch {
            diagnostics.record(
                kind: .compatibility,
                severity: .error,
                title: "#garryspad.problem.permissions-storage",
                detail: error.localizedDescription,
                source: "permissions"
            )
        }
    }

    private var currentProblemSeverity: Int {
        currentProblemSnapshot.problems.map(\.severity.rawValue).max() ?? 0
    }

    private func selectLanguageFromOptions(_ rawCode: String) {
        guard case let .ready(pack, _, _) = content.state else { return }
        publishLanguageSelection(rawCode, from: pack)
    }

    private func publishHomeLanguageSelection(
        _ requested: GModMenuLanguageSnapshot,
        from pack: GarrysPADContentPack
    ) {
        let catalog = localizationCatalog(from: pack)
        _ = localizationSelection.publishHomeSelection(
            requested,
            catalog: catalog,
            preferenceStore: GModMenuLanguagePreferenceStore()
        )
    }

    private func publishLanguageSelection(
        _ rawCode: String,
        from pack: GarrysPADContentPack
    ) {
        let catalog = localizationCatalog(from: pack)
        let code = GModMenuLocalizationCatalog.normalizedCode(rawCode)
        guard catalog.contains(languageCode: code),
              GModMenuLanguagePreferenceStore().persist(
                languageCode: code,
                availableLanguageCodes: catalog.availableLanguageCodes
              ) else {
            return
        }
        localizationSelection.publish(
            catalog.snapshot(languageCode: code),
            availableLanguageCodes: catalog.availableLanguageCodes
        )
    }

    private func localizationCatalog(
        from pack: GarrysPADContentPack
    ) -> GModMenuLocalizationCatalog {
        let appPhrases = GModBundledAppLocalization.load { message in
            diagnostics.record(
                kind: .compatibility,
                severity: .warning,
                title: "#garryspad.problem.menu",
                detail: message,
                source: "localization"
            )
        }
        return GModMenuLocalizationCatalog.load(
            from: pack,
            appPhrasesByLanguage: appPhrases
        ) { message in
            diagnostics.record(
                kind: .compatibility,
                severity: .warning,
                title: "#garryspad.problem.menu",
                detail: message,
                source: "localization"
            )
        }
    }

    private func requestContentManagementAction(
        _ action: GModPendingContentManagementAction
    ) {
        if game.hasActiveSession {
            pendingContentManagementAction = action
            showingContentChangeConfirmation = true
        } else {
            performContentManagementAction(action)
        }
    }

    private func confirmContentManagementAction() {
        guard let action = pendingContentManagementAction else { return }
        pendingContentManagementAction = nil
        contentActionAfterDisconnect = action
        handlePresentationEvent(.homeMenuAction(.disconnect))
        if !game.isDisconnecting {
            contentActionAfterDisconnect = nil
            performContentManagementAction(action)
        }
    }

    private func performContentManagementAction(
        _ action: GModPendingContentManagementAction
    ) {
        switch action {
        case .chooseZIP:
            isChoosingContentPack = true
        case .unmountZIP:
            activeUtilityWindow = nil
            content.forgetSelection()
        case .revalidateZIP:
            content.revalidateActiveSelection()
        }
    }

    private func dumpContentDiagnostics() {
        for line in content.diagnosticsLines(
            currentMap: game.activeMap?.rawValue
        ) {
            console.append(line)
        }
        if developerDiagnostics.isEnabled {
            showConsole = true
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
                game.start(
                    map: .construct,
                    contentPackURL: activeContentPackURL,
                    languageCode: localizationSelection.snapshot.code,
                    languagePhrases: localizationSelection.snapshot.phrases
                )
            }
            .buttonStyle(GModButtonStyle())
            .disabled(game.isStarting)

            Button("gm_flatgrass") {
                game.start(
                    map: .flatgrass,
                    contentPackURL: activeContentPackURL,
                    languageCode: localizationSelection.snapshot.code,
                    languagePhrases: localizationSelection.snapshot.phrases
                )
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

            Button("Home") {
                handlePresentationEvent(
                    .pauseRequested(game.continuitySnapshot)
                )
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
            .disabled(!game.isReady || game.isClientMenuTransitioning)

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

private struct GModInGameButtonStyle: ButtonStyle {
    let size: Double
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .foregroundColor(Color.white.opacity(configuration.isPressed ? 1 : 0.92))
            .frame(width: CGFloat(size), height: CGFloat(size))
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        isActive
                            ? Color(red: 0.10, green: 0.49, blue: 0.76)
                                .opacity(configuration.isPressed ? 0.90 : 0.72)
                            : Color.black.opacity(
                                configuration.isPressed ? 0.62 : 0.34
                            )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(
                        isActive
                            ? Color.white.opacity(0.72)
                            : Color.white.opacity(0.34),
                        lineWidth: 1
                    )
            )
            .overlay(alignment: .bottom) {
                if isActive {
                    Rectangle()
                        .fill(Color.white.opacity(0.88))
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 4)
                }
            }
            .shadow(
                color: Color.black.opacity(configuration.isPressed ? 0.12 : 0.28),
                radius: 3,
                y: 1
            )
            .contentShape(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
    }
}

private struct GModTouchJoystick: View {
    let diameter: Double
    let knobDiameter: Double
    let onChange: (_ forward: Float, _ side: Float) -> Void
    @State private var touchState = GModJoystickTouchState()

    var body: some View {
        GeometryReader { geometry in
            let radius = Double(Swift.max(
                1,
                Swift.min(geometry.size.width, geometry.size.height) * 0.5 -
                    CGFloat(knobDiameter * 0.5)
            ))
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.16))
                    .overlay(
                        Circle().stroke(
                            Color.white.opacity(0.34),
                            lineWidth: 1.25
                        )
                    )
                Circle()
                    .stroke(
                        Color.white.opacity(0.10),
                        style: StrokeStyle(lineWidth: 1, dash: [2, 5])
                    )
                    .padding(CGFloat(diameter * 0.20))
                Circle()
                    .fill(Color.white.opacity(0.50))
                    .overlay(
                        Circle().stroke(Color.black.opacity(0.22), lineWidth: 1)
                    )
                    .frame(
                        width: CGFloat(knobDiameter),
                        height: CGFloat(knobDiameter)
                    )
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
        .frame(width: CGFloat(diameter), height: CGFloat(diameter))
        .accessibilityLabel("Movement joystick")
        .accessibilityIdentifier("garryspad.control.movement")
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
    let width: Double
    let height: Double
    let onDelta: (_ deltaX: Float, _ deltaY: Float) -> Void
    @State private var touchState = GModLookTouchState()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.20), lineWidth: 1)
                )
            Image(systemName: "viewfinder")
                .font(.system(size: 23, weight: .ultraLight))
                .foregroundColor(Color.white.opacity(0.34))
            GModTouchInputBridge { sample in
                handleTouch(sample)
            }
        }
        .frame(width: CGFloat(width), height: CGFloat(height))
        .contentShape(Rectangle())
        .accessibilityLabel("Look control")
        .accessibilityIdentifier("garryspad.control.look")
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

private struct GModTouchActionButton: View {
    let label: String
    let diameter: Double
    let accessibilityIdentifier: String
    let onPressedChanged: (Bool) -> Void
    @State private var isPressed = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(isPressed ? 0.48 : 0.17))
                .overlay(
                    Circle().stroke(
                        Color.white.opacity(isPressed ? 0.82 : 0.36),
                        lineWidth: 1.25
                    )
                )
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.72)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .foregroundColor(.white.opacity(isPressed ? 1 : 0.82))
            GModTouchInputBridge { sample in
                switch sample.phase {
                case .began:
                    guard !isPressed else { return }
                    isPressed = true
                    onPressedChanged(true)
                case .ended, .cancelled:
                    guard isPressed else { return }
                    isPressed = false
                    onPressedChanged(false)
                case .moved, .scroll:
                    break
                }
            }
            .contentShape(Circle())
        }
        .frame(width: CGFloat(diameter), height: CGFloat(diameter))
        .contentShape(Circle())
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
