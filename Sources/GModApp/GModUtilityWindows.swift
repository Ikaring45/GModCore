import SwiftUI

enum GModUtilityWindowKind: Equatable, Sendable {
    case options
    case problems
}

enum GModOptionsTab: String, CaseIterable, Identifiable, Sendable {
    case game
    case keyboard
    case mouse
    case audio
    case video
    case voice
    case legal
    case garrysPAD

    var id: String { rawValue }

    var localizationKey: String {
        "garryspad.options.tab.\(rawValue.lowercased())"
    }
}

enum GModProblemsTab: String, CaseIterable, Identifiable, Sendable {
    case problems
    case luaErrors
    case permissions

    var id: String { rawValue }

    var localizationKey: String {
        switch self {
        case .problems: return "problems.problems"
        case .luaErrors: return "problems.lua_errors"
        case .permissions: return "permissions.title"
        }
    }
}

private struct GModUtilityWindowFrame<Content: View>: View {
    let title: String
    let closeLabel: String
    let onClose: () -> Void
    let content: Content

    @State private var settledOffset = CGSize.zero
    @GestureState private var dragOffset = CGSize.zero

    init(
        title: String,
        closeLabel: String,
        onClose: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.closeLabel = closeLabel
        self.onClose = onClose
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 30, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundColor(.white)
                .accessibilityLabel(closeLabel)
            }
            .padding(.horizontal, 9)
            .frame(height: 34)
            .background(Color(red: 0.19, green: 0.20, blue: 0.21))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .updating($dragOffset) { value, state, _ in
                    state = value.translation
                }
                .onEnded { value in
                    settledOffset.width += value.translation.width
                    settledOffset.height += value.translation.height
                })

            content
        }
        .background(Color(red: 0.12, green: 0.125, blue: 0.13))
        .overlay(
            Rectangle().stroke(
                Color(red: 0.43, green: 0.44, blue: 0.45),
                lineWidth: 1
            )
        )
        .shadow(color: .black.opacity(0.7), radius: 24, x: 0, y: 10)
        .offset(
            x: settledOffset.width + dragOffset.width,
            y: settledOffset.height + dragOffset.height
        )
    }
}

struct GModOptionsWindow: View {
    let localization: GModMenuLanguageSnapshot
    @ObservedObject var audio: GModMenuAudioSettingsStore
    @ObservedObject var inputVideo: GModInputVideoSettingsStore
    @ObservedObject var developerDiagnostics: GModDeveloperDiagnosticsSettingsStore
    @ObservedObject var contentSettings: GModContentSettingsStore
    @ObservedObject var content: GModPlaygroundContentModel
    let currentMap: String?
    let onClose: () -> Void
    let onLanguageChange: (String) -> Void
    let onChooseZIP: () -> Void
    let onUnmountZIP: () -> Void
    let onRevalidateZIP: () -> Void
    let onClearCaches: () -> Void
    let onDumpDiagnostics: () -> Void

    @State private var selectedTab = GModOptionsTab.game

    var body: some View {
        ZStack {
            Color.black.opacity(0.54)
                .ignoresSafeArea()
                .contentShape(Rectangle())

            GModUtilityWindowFrame(
                title: text("garryspad.options.title"),
                closeLabel: text("garryspad.control.close"),
                onClose: onClose
            ) {
                VStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            ForEach(GModOptionsTab.allCases) { tab in
                                Button(text(tab.localizationKey)) {
                                    selectedTab = tab
                                }
                                .buttonStyle(GModUtilityTabButtonStyle(
                                    isSelected: selectedTab == tab
                                ))
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                    }

                    Divider().overlay(Color.white.opacity(0.28))

                    tabBody
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minHeight: 450)
            }
            .frame(maxWidth: 880, maxHeight: 650)
            .padding(36)
        }
        .accessibilityIdentifier("garryspad.options.window")
    }

    @ViewBuilder
    private var tabBody: some View {
        switch selectedTab {
        case .audio:
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    slider(
                        title: text("garryspad.options.audio.master"),
                        value: Binding(
                            get: { audio.settings.masterVolume },
                            set: { audio.setMasterVolume($0) }
                        )
                    )
                    slider(
                        title: text("garryspad.options.audio.menu"),
                        value: Binding(
                            get: { audio.settings.menuVolume },
                            set: { audio.setMenuVolume($0) }
                        )
                    )
                    slider(
                        title: text("garryspad.options.audio.gameplay"),
                        value: Binding(
                            get: { audio.settings.gameplayVolume },
                            set: { audio.setGameplayVolume($0) }
                        )
                    )
                    Text(text("garryspad.options.audio.live-note"))
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.68))
                }
                .padding(24)
            }

        case .garrysPAD:
            garrysPADTab

        case .mouse:
            touchLookTab

        case .video:
            videoTab

        case .legal:
            unavailableOrLegal(
                titleKey: "garryspad.options.legal.title",
                detailKey: "garryspad.options.legal.detail",
                isUnavailable: false
            )

        case .game:
            gameInputTab
        case .keyboard:
            unavailableOrLegal(
                titleKey: "garryspad.options.tab.keyboard",
                detailKey: "garryspad.options.unavailable.keyboard",
                isUnavailable: true
            )
        case .voice:
            unavailableOrLegal(
                titleKey: "garryspad.options.tab.voice",
                detailKey: "garryspad.options.unavailable.voice",
                isUnavailable: true
            )
        }
    }

    private var touchLookTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(text("garryspad.options.mouse.touch-title"))
                    .font(.title3.weight(.semibold))
                HStack {
                    Text(text("garryspad.options.mouse.sensitivity"))
                    Spacer()
                    Text(String(format: "%.2f", inputVideo.touchLookSensitivity))
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { inputVideo.touchLookSensitivity },
                        set: { inputVideo.setTouchLookSensitivity($0) }
                    ),
                    in: GModInputVideoSettingsStore.minimumTouchLookSensitivity...GModInputVideoSettingsStore.maximumTouchLookSensitivity,
                    step: 0.01
                )
                Toggle(
                    text("garryspad.options.mouse.invert-y"),
                    isOn: Binding(
                        get: { inputVideo.invertTouchLookY },
                        set: { inputVideo.setInvertTouchLookY($0) }
                    )
                )
                Text(text("garryspad.options.mouse.live-note"))
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.68))
                capabilityBlocker("garryspad.options.unavailable.mouse")
            }
            .padding(24)
        }
        .foregroundColor(.white)
    }

    private var gameInputTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(text("garryspad.options.tab.game"))
                    .font(.title3.weight(.semibold))
                Label(
                    text("garryspad.options.game.touch-actions-title"),
                    systemImage: "hand.tap"
                )
                .font(.headline)
                Text(text("garryspad.options.game.touch-actions-detail"))
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.74))
                    .fixedSize(horizontal: false, vertical: true)
                capabilityBlocker("garryspad.options.unavailable.game")
            }
            .padding(24)
        }
        .foregroundColor(.white)
    }

    private var videoTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(text("garryspad.options.video.host-title"))
                    .font(.title3.weight(.semibold))
                Picker(
                    text("garryspad.options.video.frame-rate"),
                    selection: Binding(
                        get: { inputVideo.preferredFramesPerSecond },
                        set: { inputVideo.setPreferredFramesPerSecond($0) }
                    )
                ) {
                    Text("60 FPS").tag(60)
                    Text("120 FPS").tag(120)
                }
                .pickerStyle(.segmented)
                Text(text("garryspad.options.video.live-note"))
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.68))
                capabilityBlocker("garryspad.options.unavailable.video")
            }
            .padding(24)
        }
        .foregroundColor(.white)
    }

    private var garrysPADTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox {
                    VStack(spacing: 7) {
                        metadataRow(
                            "garryspad.content.zip-name",
                            content.metadata?.zipFileName
                        )
                        metadataRow(
                            "garryspad.content.profile",
                            content.metadata?.profile
                        )
                        metadataRow(
                            "garryspad.content.file-count",
                            content.metadata.map { String($0.fileCount) }
                        )
                        metadataRow(
                            "garryspad.content.size",
                            content.metadata.map(sizeDescription)
                        )
                        metadataRow(
                            "garryspad.content.manifest",
                            content.metadata.map(manifestDescription)
                        )
                        metadataRow(
                            "garryspad.content.security-scope",
                            content.metadata.map {
                                text($0.securityScopeStatus.localizationKey)
                            }
                        )
                        metadataRow(
                            "garryspad.content.mounted-vpks",
                            content.metadata.map { String($0.mountedVPKCount) }
                        )
                        metadataRow("garryspad.content.current-map", currentMap)
                        metadataRow("garryspad.content.last-error", content.lastError)
                    }
                    .padding(.top, 4)
                } label: {
                    Text(text("garryspad.content.title"))
                }

                if content.isValidatingCandidate {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(text("garryspad.content.validating"))
                            .font(.system(size: 12, weight: .semibold))
                        if let state = content.verificationState {
                            Text(text(state.stage.localizationKey))
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.72))
                            ProgressView(value: state.fractionCompleted)
                                .tint(Color(red: 0.2, green: 0.67, blue: 1))
                            HStack {
                                Text(
                                    "\(state.progress.completedFileCount)/" +
                                        "\(state.progress.totalFileCount) " +
                                        text("garryspad.content.verification.files")
                                )
                                Spacer()
                                Text(
                                    "\(state.progress.completedByteCount)/" +
                                        "\(state.progress.totalByteCount) " +
                                        text("garryspad.content.verification.bytes")
                                )
                            }
                            .font(.system(size: 10).monospacedDigit())
                            if let path = state.progress.currentPath {
                                Text(path)
                                    .font(.system(size: 10, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        } else {
                            ProgressView().tint(.white)
                        }
                        utilityButton(
                            "garryspad.content.cancel-validation",
                            action: { content.cancelValidation() }
                        )
                    }
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150), spacing: 8)],
                    spacing: 8
                ) {
                    utilityButton("garryspad.content.change", action: onChooseZIP)
                    utilityButton(
                        "garryspad.content.unmount",
                        action: onUnmountZIP,
                        disabled: content.metadata == nil
                    )
                    utilityButton(
                        "garryspad.content.revalidate",
                        action: onRevalidateZIP,
                        disabled: content.metadata == nil || content.isValidatingCandidate
                    )
                    utilityButton("garryspad.content.clear-cache", action: onClearCaches)
                    utilityButton("garryspad.content.dump", action: onDumpDiagnostics)
                }

                Divider().overlay(Color.white.opacity(0.25))

                Picker(
                    text("garryspad.options.language"),
                    selection: Binding(
                        get: { localization.code },
                        set: onLanguageChange
                    )
                ) {
                    Text(text("garryspad.language.en")).tag("en")
                    Text(text("garryspad.language.ja")).tag("ja")
                }
                .pickerStyle(.menu)
                .tint(.white)

                Toggle(
                    text("garryspad.options.auto-reload"),
                    isOn: Binding(
                        get: { contentSettings.automaticallyReloadsLastPack },
                        set: { contentSettings.setAutomaticallyReloadsLastPack($0) }
                    )
                )
                Toggle(
                    text("garryspad.options.backgrounds"),
                    isOn: Binding(
                        get: { contentSettings.menuBackgroundsEnabled },
                        set: { contentSettings.setMenuBackgroundsEnabled($0) }
                    )
                )
                Toggle(
                    text("garryspad.options.developer-diagnostics"),
                    isOn: Binding(
                        get: { developerDiagnostics.isEnabled },
                        set: { developerDiagnostics.setEnabled($0) }
                    )
                )
            }
            .padding(18)
        }
        .foregroundColor(.white)
    }

    private func slider(title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .monospacedDigit()
            }
            Slider(value: value, in: 0...1)
        }
        .foregroundColor(.white)
    }

    private func unavailableOrLegal(
        titleKey: String,
        detailKey: String,
        isUnavailable: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text(titleKey)).font(.title3.weight(.semibold))
            if isUnavailable {
                Label(
                    text("garryspad.status.unavailable"),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundColor(Color(red: 1, green: 0.72, blue: 0.25))
            }
            Text(text(detailKey))
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
    }

    private func capabilityBlocker(_ detailKey: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                text("garryspad.status.unavailable"),
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundColor(Color(red: 1, green: 0.72, blue: 0.25))
            Text(text(detailKey))
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    private func metadataRow(_ key: String, _ value: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(text(key))
                .foregroundColor(.white.opacity(0.66))
                .frame(width: 170, alignment: .leading)
            Text(value ?? text("garryspad.status.unavailable"))
                .foregroundColor(.white)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, design: .monospaced))
    }

    private func utilityButton(
        _ key: String,
        action: @escaping () -> Void,
        disabled: Bool = false
    ) -> some View {
        Button(text(key), action: action)
            .buttonStyle(GModUtilityActionButtonStyle())
            .disabled(disabled)
    }

    private func sizeDescription(_ metadata: GModContentPackMetadata) -> String {
        let bytes = metadata.archiveByteCount ?? metadata.payloadByteCount
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
            + " · \(bytes) B"
    }

    private func manifestDescription(_ metadata: GModContentPackMetadata) -> String {
        text(metadata.manifestStatus.localizationKey)
    }

    private func text(_ key: String) -> String { localization.phrase(key) }
}

struct GModProblemsWindow: View {
    let localization: GModMenuLanguageSnapshot
    let snapshot: GModAppProblemSnapshot
    let onClose: () -> Void
    @State private var selectedTab = GModProblemsTab.problems

    var body: some View {
        ZStack {
            Color.black.opacity(0.54)
                .ignoresSafeArea()
                .contentShape(Rectangle())

            GModUtilityWindowFrame(
                title: text("garryspad.problems.title"),
                closeLabel: text("garryspad.control.close"),
                onClose: onClose
            ) {
                VStack(spacing: 0) {
                    HStack(spacing: 2) {
                        ForEach(GModProblemsTab.allCases) { tab in
                            Button(text(tab.localizationKey)) {
                                selectedTab = tab
                            }
                            .buttonStyle(GModUtilityTabButtonStyle(
                                isSelected: selectedTab == tab
                            ))
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)

                    Divider().overlay(Color.white.opacity(0.28))

                    tabBody
                }
                .frame(minHeight: 420)
            }
            .frame(maxWidth: 900, maxHeight: 640)
            .padding(36)
        }
        .accessibilityIdentifier("garryspad.problems.window")
    }

    @ViewBuilder
    private var tabBody: some View {
        switch selectedTab {
        case .problems:
            recordList
        case .luaErrors:
            luaErrorList
        case .permissions:
            permissionList
        }
    }

    private var recordList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(snapshot.problems) { record in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: severityIcon(record.severity))
                            .foregroundColor(severityColor(record.severity))
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.localizedTitle(using: localization))
                                .font(.headline)
                            Text(record.localizedDetail(using: localization))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.white.opacity(0.74))
                                .textSelection(.enabled)
                            if let source = record.source {
                                Text(source)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.055))
                }
            }
            .padding(12)
        }
    }

    private var luaErrorList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if snapshot.luaErrors.isEmpty {
                    capabilityEmptyState("garryspad.problems.no-captured-lua-errors")
                }
                ForEach(snapshot.luaErrors) { error in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(error.realm).font(.caption.bold())
                            Text(error.source)
                            if let line = error.line { Text(":\(line)") }
                            Spacer()
                        }
                        .font(.system(size: 11, design: .monospaced))
                        Text(error.message)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white.opacity(0.76))
                            .textSelection(.enabled)
                        if let traceback = error.traceback {
                            Text(traceback)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.white.opacity(0.56))
                        }
                    }
                    .padding(10)
                    .background(Color.red.opacity(0.09))
                }
            }
            .padding(12)
        }
    }

    private var permissionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(snapshot.permissions) { permission in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(resolve(permission.name)).font(.headline)
                            Spacer()
                            Text(resolve(permission.status))
                                .font(.caption.bold())
                                .foregroundColor(.orange)
                        }
                        Text(resolve(permission.detail))
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.72))
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.055))
                }
            }
            .padding(12)
        }
    }

    private func capabilityEmptyState(_ key: String) -> some View {
        Label(text(key), systemImage: "info.circle")
            .font(.system(size: 13))
            .foregroundColor(.white.opacity(0.72))
            .padding(12)
    }

    private func text(_ key: String) -> String { localization.phrase(key) }

    private func severityIcon(_ severity: GModAppProblemSeverity) -> String {
        switch severity {
        case .information: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private func severityColor(_ severity: GModAppProblemSeverity) -> Color {
        switch severity {
        case .information: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}

private struct GModUtilityTabButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            .foregroundColor(isSelected ? .black : .white.opacity(0.82))
            .padding(.horizontal, 13)
            .frame(height: 30)
            .background(
                isSelected
                    ? Color(white: 0.88)
                    : Color.white.opacity(configuration.isPressed ? 0.14 : 0.06)
            )
    }
}

private struct GModUtilityActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white.opacity(isEnabled ? 1 : 0.42))
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(
                Color.white.opacity(
                    isEnabled ? (configuration.isPressed ? 0.18 : 0.10) : 0.035
                )
            )
            .overlay(Rectangle().stroke(Color.white.opacity(0.2), lineWidth: 1))
    }
}
