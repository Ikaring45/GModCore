@preconcurrency import AVFoundation
import Combine
import Foundation
import UIKit

extension GModMenuWebContract {
    static let htmlAudioBridgeScript = """
    (function(){
      function audioSource(element){
        let value=element.getAttribute('src')||'';
        if(!value){
          const source=element.querySelector&&element.querySelector('source[src]');
          value=source?(source.getAttribute('src')||''):'';
        }
        if(!value) value=element.currentSrc||'';
        if(!value) return '';
        return value;
      }
      function isSupported(value){
        try{
          const path=new URL(value,document.baseURI).pathname||'';
          return /\\.(wav|mp3)$/i.test(path);
        }catch(_){
          return /\\.(wav|mp3)(?:[?#].*)?$/i.test(String(value||''));
        }
      }
      function post(element){
        const value=audioSource(element);
        if(!value||!isSupported(value)) return false;
        try{
          window.webkit.messageHandlers.garrysPAD.postMessage({
            action:'htmlSound',name:value,base:String(document.baseURI||'')
          });
          return true;
        }catch(_){return false;}
      }
      const nativePlay=window.HTMLMediaElement&&HTMLMediaElement.prototype.play;
      if(nativePlay){
        HTMLMediaElement.prototype.play=function(){
          if((this.tagName||'').toUpperCase()==='AUDIO'&&post(this)){
            return Promise.resolve();
          }
          return nativePlay.apply(this,arguments);
        };
      }
      document.addEventListener('play',function(event){
        const element=event.target;
        if(!element||(element.tagName||'').toUpperCase()!=='AUDIO') return;
        if(element.dataset.garrysPadNativeAudio==='1') return;
        if(post(element)){
          element.dataset.garrysPadNativeAudio='1';
          element.pause();
          Promise.resolve().then(function(){
            delete element.dataset.garrysPadNativeAudio;
          });
        }
      },true);
    })();
    """
}

enum GModAudioBus: String, Equatable, Sendable {
    case menu
    case gameplay
}

enum GModAudioDiagnosticCode: String, Equatable, Sendable {
    case playing
    case cacheBypassed
    case rejectedPath
    case voicePoolDisabled
    case assetNotFound
    case assetResolutionFailed
    case decodeFailed
    case playerRefused
    case audioSessionFailed
    case requestQueueOverflow
    case invalidRequestEncoding
}

enum GModAudioDiagnosticSeverity: Int, Equatable, Sendable {
    case info
    case warning
    case error
}

struct GModAudioDiagnostic: Equatable, Sendable {
    let code: GModAudioDiagnosticCode
    let severity: GModAudioDiagnosticSeverity
    let bus: GModAudioBus
    let message: String
    let logicalPath: String?

    var isProblem: Bool { severity != .info }
}

enum GModAudioProblemMapper {
    static func record(
        for diagnostic: GModAudioDiagnostic
    ) -> GModAppProblemRecord? {
        guard diagnostic.isProblem else { return nil }
        let detail = [diagnostic.logicalPath, diagnostic.message]
            .compactMap { $0 }
            .joined(separator: ": ")
        let source: String
        if diagnostic.code == .audioSessionFailed {
            source = "AVAudioSession"
        } else {
            source = diagnostic.bus == .menu
                ? "Home/Menu audio"
                : "CLIENT surface.PlaySound"
        }
        return GModAppProblemRecord(
            id: "audio|\(diagnostic.code.rawValue)|" +
                "\(diagnostic.bus.rawValue)|\(detail)",
            kind: .audio,
            severity: diagnostic.severity == .warning ? .warning : .error,
            title: "#garryspad.problem.audio",
            detail: detail,
            source: source
        )
    }
}

struct GModMenuAudioSettings: Equatable, Sendable {
    var masterVolume: Double
    var menuVolume: Double
    var gameplayVolume: Double

    init(
        masterVolume: Double = 1,
        menuVolume: Double = 1,
        gameplayVolume: Double = 1
    ) {
        self.masterVolume = Self.clamped(masterVolume)
        self.menuVolume = Self.clamped(menuVolume)
        self.gameplayVolume = Self.clamped(gameplayVolume)
    }

    var effectiveMenuVolume: Float {
        Float(Self.clamped(masterVolume) * Self.clamped(menuVolume))
    }

    var effectiveGameplayVolume: Float {
        Float(Self.clamped(masterVolume) * Self.clamped(gameplayVolume))
    }

    func effectiveVolume(for bus: GModAudioBus) -> Float {
        switch bus {
        case .menu: return effectiveMenuVolume
        case .gameplay: return effectiveGameplayVolume
        }
    }

    private static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(1, max(0, value))
    }
}

/// Persistent, observable audio values shared by Home and a future stock-like
/// Options surface. The store owns policy only; the audio controller observes
/// it and updates every active voice immediately.
@MainActor
final class GModMenuAudioSettingsStore: ObservableObject {
    static let shared = GModMenuAudioSettingsStore()
    nonisolated static let didChangeNotification = Notification.Name(
        "GarrysPAD.MenuAudioSettingsDidChange"
    )
    nonisolated static let clearContentCachesNotification = Notification.Name(
        "GarrysPAD.ClearContentCaches"
    )
    static let masterVolumeKey = "GarrysPAD.Audio.MasterVolume.v1"
    static let menuVolumeKey = "GarrysPAD.Audio.MenuVolume.v1"
    static let gameplayVolumeKey = "GarrysPAD.Audio.GameplayVolume.v1"

    @Published private(set) var settings: GModMenuAudioSettings

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = GModMenuAudioSettings(
            masterVolume: Self.persistedValue(
                defaults: defaults,
                key: Self.masterVolumeKey
            ),
            menuVolume: Self.persistedValue(
                defaults: defaults,
                key: Self.menuVolumeKey
            ),
            gameplayVolume: Self.persistedValue(
                defaults: defaults,
                key: Self.gameplayVolumeKey
            )
        )
    }

    func setMasterVolume(_ value: Double) {
        save(GModMenuAudioSettings(
            masterVolume: value,
            menuVolume: settings.menuVolume,
            gameplayVolume: settings.gameplayVolume
        ))
    }

    func setMenuVolume(_ value: Double) {
        save(GModMenuAudioSettings(
            masterVolume: settings.masterVolume,
            menuVolume: value,
            gameplayVolume: settings.gameplayVolume
        ))
    }

    func setGameplayVolume(_ value: Double) {
        save(GModMenuAudioSettings(
            masterVolume: settings.masterVolume,
            menuVolume: settings.menuVolume,
            gameplayVolume: value
        ))
    }

    func save(_ replacement: GModMenuAudioSettings) {
        guard replacement != settings else { return }
        settings = replacement
        defaults.set(replacement.masterVolume, forKey: Self.masterVolumeKey)
        defaults.set(replacement.menuVolume, forKey: Self.menuVolumeKey)
        defaults.set(
            replacement.gameplayVolume,
            forKey: Self.gameplayVolumeKey
        )
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: self
        )
    }

    private static func persistedValue(
        defaults: UserDefaults,
        key: String
    ) -> Double {
        guard defaults.object(forKey: key) != nil else { return 1 }
        return defaults.double(forKey: key)
    }
}

/// Developer chrome is opt-in and remains off for ordinary play. MainView can
/// observe this shared store and gate stats, console and debug map buttons;
/// Options can mutate it without knowing the UserDefaults key.
@MainActor
final class GModDeveloperDiagnosticsSettingsStore: ObservableObject {
    static let shared = GModDeveloperDiagnosticsSettingsStore()
    static let key = "GarrysPAD.DeveloperDiagnostics.Enabled.v1"

    @Published private(set) var isEnabled: Bool

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.key) == nil
            ? false
            : defaults.bool(forKey: Self.key)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.key)
    }
}

enum GModMenuSoundOrigin: Equatable, Sendable {
    case lua
    case html
}

enum GModMenuSoundPath {
    static let supportedExtensions = Set(["wav", "mp3"])

    static func normalize(
        _ rawValue: String,
        origin: GModMenuSoundOrigin,
        documentURL: URL? = URL(string: "asset://garrysmod/html/menu.html")
    ) -> String? {
        var raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.contains("\0") else { return nil }
        raw = raw.replacingOccurrences(of: "\\", with: "/")

        let path: String
        var stripsPackRoot = false
        var isSchemeLessSoundName = false
        if let components = URLComponents(string: raw),
           let scheme = components.scheme?.lowercased() {
            guard scheme == "asset"
                    || scheme == "garryspad"
                    || scheme == "garryspadloading" else {
                return nil
            }
            var absolutePath = components.percentEncodedPath
                .removingPercentEncoding ?? components.path
            if scheme == "asset",
               let host = components.host?.lowercased(),
               host != "garrysmod",
               host != "content" {
                absolutePath = host + "/" + absolutePath
            }
            path = absolutePath
            stripsPackRoot = scheme != "asset"
        } else if origin == .html, let documentURL {
            let lowered = raw.lowercased()
            let logicalSoundRoots = [
                "garrysmod/", "platform/", "sourceengine/", "sound/",
            ]
            if logicalSoundRoots.contains(where: lowered.hasPrefix) {
                path = raw
                isSchemeLessSoundName = true
            } else {
                path = resolveRelativePath(raw, against: documentURL.path)
            }
        } else {
            path = raw
                .split(separator: "?", maxSplits: 1)
                .first
                .map(String.init) ?? raw
            isSchemeLessSoundName = true
        }

        guard var normalized = canonicalPath(path) else { return nil }
        if stripsPackRoot {
            for root in ["garrysmod/", "platform/", "sourceengine/"]
            where normalized.lowercased().hasPrefix(root) {
                normalized.removeFirst(root.count)
                break
            }
        }
        if (origin == .lua || isSchemeLessSoundName),
           !normalized.lowercased().hasPrefix("sound/") {
            normalized = "sound/" + normalized
        }
        guard supportedExtensions.contains(
            URL(fileURLWithPath: normalized).pathExtension.lowercased()
        ) else {
            return nil
        }
        return normalized
    }

    private static func resolveRelativePath(
        _ raw: String,
        against documentPath: String
    ) -> String {
        let withoutFragment = raw.split(separator: "#", maxSplits: 1)
            .first.map(String.init) ?? raw
        let withoutQuery = withoutFragment.split(separator: "?", maxSplits: 1)
            .first.map(String.init) ?? withoutFragment
        let decoded = withoutQuery.removingPercentEncoding ?? withoutQuery
        if decoded.hasPrefix("/") { return decoded }

        var baseComponents = documentPath
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map(String.init)
        if !baseComponents.isEmpty { baseComponents.removeLast() }
        baseComponents.append(contentsOf: decoded.split(separator: "/").map(String.init))
        return baseComponents.joined(separator: "/")
    }

    private static func canonicalPath(_ raw: String) -> String? {
        let decoded = raw.removingPercentEncoding ?? raw
        let withoutFragment = decoded.split(separator: "#", maxSplits: 1)
            .first.map(String.init) ?? decoded
        let withoutQuery = withoutFragment.split(separator: "?", maxSplits: 1)
            .first.map(String.init) ?? withoutFragment
        var components: [String] = []
        for component in withoutQuery
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/") {
            switch component {
            case ".", "":
                continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default:
                components.append(String(component))
            }
        }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: "/")
    }
}

struct GModMenuBoundedDataCache {
    private struct Entry {
        let data: Data
        var use: UInt64
    }

    let maximumByteCount: Int
    let maximumEntryCount: Int
    private(set) var byteCount = 0
    private var entries: [String: Entry] = [:]
    private var useCounter: UInt64 = 0

    init(maximumByteCount: Int, maximumEntryCount: Int) {
        self.maximumByteCount = max(0, maximumByteCount)
        self.maximumEntryCount = max(0, maximumEntryCount)
    }

    var count: Int { entries.count }

    mutating func data(for key: String) -> Data? {
        guard var entry = entries[key] else { return nil }
        useCounter &+= 1
        entry.use = useCounter
        entries[key] = entry
        return entry.data
    }

    @discardableResult
    mutating func insert(_ data: Data, for key: String) -> Bool {
        guard maximumEntryCount > 0,
              data.count <= maximumByteCount else {
            return false
        }
        if let old = entries.removeValue(forKey: key) {
            byteCount -= old.data.count
        }
        useCounter &+= 1
        entries[key] = Entry(data: data, use: useCounter)
        byteCount += data.count

        while entries.count > maximumEntryCount
                || byteCount > maximumByteCount {
            guard let victim = entries.min(by: { $0.value.use < $1.value.use }) else {
                break
            }
            entries.removeValue(forKey: victim.key)
            byteCount -= victim.value.data.count
        }
        return entries[key] != nil
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: false)
        byteCount = 0
        useCounter = 0
    }
}

struct GModMenuVoiceSlot: Equatable, Sendable {
    let id: Int
    let path: String
    let bus: GModAudioBus
    let isPlaying: Bool
    let lastUse: UInt64
}

enum GModMenuVoiceDecision: Equatable, Sendable {
    case create
    case reuse(Int)
    case steal(Int)
}

enum GModMenuVoicePoolPolicy {
    static func decision(
        for path: String,
        bus: GModAudioBus,
        slots: [GModMenuVoiceSlot],
        maximumVoiceCount: Int,
        maximumVoicesPerSound: Int
    ) -> GModMenuVoiceDecision? {
        guard maximumVoiceCount > 0, maximumVoicesPerSound > 0 else {
            return nil
        }
        let samePath = slots.filter { $0.path == path && $0.bus == bus }
        if let idle = samePath
            .filter({ !$0.isPlaying })
            .min(by: { $0.lastUse < $1.lastUse }) {
            return .reuse(idle.id)
        }
        if samePath.count < maximumVoicesPerSound,
           slots.count < maximumVoiceCount {
            return .create
        }
        if let idle = slots
            .filter({ !$0.isPlaying })
            .min(by: { $0.lastUse < $1.lastUse }) {
            return .reuse(idle.id)
        }
        if samePath.count >= maximumVoicesPerSound,
           let oldestSame = samePath.min(by: { $0.lastUse < $1.lastUse }) {
            return .steal(oldestSame.id)
        }
        if slots.count >= maximumVoiceCount,
           let oldest = slots.min(by: { $0.lastUse < $1.lastUse }) {
            return .steal(oldest.id)
        }
        return .create
    }
}

@MainActor
final class GModMenuAudioController: NSObject, AVAudioPlayerDelegate {
    typealias Resolver = (_ logicalPath: String, _ maximumByteCount: UInt64) throws -> Data?
    typealias Diagnostic = (_ diagnostic: GModAudioDiagnostic) -> Void

    private struct Voice {
        let id: Int
        var path: String
        var bus: GModAudioBus
        var eventGain: Float
        var player: AVAudioPlayer
        var lastUse: UInt64
    }

    private let maximumAssetByteCount: UInt64 = 16 * 1_024 * 1_024
    private let maximumVoiceCount = 16
    private let maximumVoicesPerSound = 4
    private let resolver: Resolver
    private let settingsStore: GModMenuAudioSettingsStore
    private let diagnostic: Diagnostic
    private var dataCache = GModMenuBoundedDataCache(
        maximumByteCount: 12 * 1_024 * 1_024,
        maximumEntryCount: 24
    )
    private var voices: [Int: Voice] = [:]
    private var nextVoiceID = 1
    private var useCounter: UInt64 = 0
    private var observers: [NSObjectProtocol] = []

    init(
        resolver: @escaping Resolver,
        settingsStore: GModMenuAudioSettingsStore = .shared,
        diagnostic: @escaping Diagnostic
    ) {
        self.resolver = resolver
        self.settingsStore = settingsStore
        self.diagnostic = diagnostic
        super.init()
        configureAudioSession(context: "initialization")
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.configureAudioSession(context: "application activation")
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey]
                    as? UInt,
                  AVAudioSession.InterruptionType(rawValue: rawType) == .ended else {
                return
            }
            Task { @MainActor [weak self] in
                self?.configureAudioSession(context: "audio interruption end")
            }
        })
        observers.append(center.addObserver(
            forName: GModMenuAudioSettingsStore.didChangeNotification,
            object: settingsStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyVolumeToAllVoices()
            }
        })
        observers.append(center.addObserver(
            forName: GModMenuAudioSettingsStore.clearContentCachesNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stopAll()
                self?.dataCache.removeAll()
            }
        })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func play(
        _ rawName: String,
        origin: GModMenuSoundOrigin,
        documentURL: URL? = nil,
        bus: GModAudioBus = .menu,
        gain: Double = 1
    ) {
        let effectiveDocumentURL = documentURL ?? (origin == .html
            ? URL(string: "asset://garrysmod/html/menu.html")
            : nil)
        guard let path = GModMenuSoundPath.normalize(
            rawName,
            origin: origin,
            documentURL: effectiveDocumentURL
        ) else {
            emit(
                code: .rejectedPath,
                severity: .error,
                bus: bus,
                message: "rejected unsupported or unsafe \(origin) sound path: \(rawName)"
            )
            return
        }
        play(logicalPath: path, bus: bus, gain: gain)
    }

    func stopAll() {
        for voice in voices.values { voice.player.stop() }
        voices.removeAll(keepingCapacity: false)
    }

    func stop(bus: GModAudioBus) {
        let identifiers = voices.values
            .filter { $0.bus == bus }
            .map(\.id)
        for identifier in identifiers {
            voices[identifier]?.player.stop()
            voices.removeValue(forKey: identifier)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(
        _ player: AVAudioPlayer,
        error: Error?
    ) {
        let playerIdentifier = ObjectIdentifier(player)
        let description = error?.localizedDescription ?? "unknown error"
        Task { @MainActor [weak self] in
            self?.handleDecodeError(
                playerIdentifier: playerIdentifier,
                description: description
            )
        }
    }

    private func handleDecodeError(
        playerIdentifier: ObjectIdentifier,
        description: String
    ) {
        let voice = voices.values.first {
            ObjectIdentifier($0.player) == playerIdentifier
        }
        if let voice {
            voices.removeValue(forKey: voice.id)
        }
        emit(
            code: .decodeFailed,
            severity: .error,
            bus: voice?.bus ?? .menu,
            message: "audio decode failed: " + description,
            logicalPath: voice?.path
        )
    }

    private func play(
        logicalPath: String,
        bus: GModAudioBus,
        gain: Double
    ) {
        let normalizedGain = Float(
            gain.isFinite ? min(1, max(0, gain)) : 1
        )
        useCounter &+= 1
        let slots = voices.values.map {
            GModMenuVoiceSlot(
                id: $0.id,
                path: $0.path,
                bus: $0.bus,
                isPlaying: $0.player.isPlaying,
                lastUse: $0.lastUse
            )
        }
        guard let decision = GModMenuVoicePoolPolicy.decision(
            for: logicalPath,
            bus: bus,
            slots: slots,
            maximumVoiceCount: maximumVoiceCount,
            maximumVoicesPerSound: maximumVoicesPerSound
        ) else {
            emit(
                code: .voicePoolDisabled,
                severity: .error,
                bus: bus,
                message: "voice pool is disabled; sound was not played",
                logicalPath: logicalPath
            )
            return
        }

        let targetID: Int
        switch decision {
        case .create:
            targetID = nextVoiceID
            nextVoiceID += 1
        case let .reuse(id), let .steal(id):
            targetID = id
        }

        if var voice = voices[targetID],
           voice.path == logicalPath,
           voice.bus == bus {
            voice.player.currentTime = 0
            voice.eventGain = normalizedGain
            voice.player.volume = effectiveVolume(
                bus: bus,
                eventGain: normalizedGain
            )
            voice.lastUse = useCounter
            voices[targetID] = voice
            guard voice.player.play() else {
                voices.removeValue(forKey: targetID)
                emit(
                    code: .playerRefused,
                    severity: .error,
                    bus: bus,
                    message: "AVAudioPlayer refused pooled voice \(targetID)",
                    logicalPath: logicalPath
                )
                return
            }
            emit(
                code: .playing,
                severity: .info,
                bus: bus,
                message: "playing on pooled voice \(targetID)",
                logicalPath: logicalPath
            )
            return
        }

        let data: Data
        if let cached = dataCache.data(for: logicalPath) {
            data = cached
        } else {
            do {
                guard let loaded = try resolver(logicalPath, maximumAssetByteCount) else {
                    emit(
                        code: .assetNotFound,
                        severity: .error,
                        bus: bus,
                        message: "sound asset was not found in ZIP, VPK, or bundle",
                        logicalPath: logicalPath
                    )
                    return
                }
                data = loaded
                if !dataCache.insert(loaded, for: logicalPath) {
                    emit(
                        code: .cacheBypassed,
                        severity: .warning,
                        bus: bus,
                        message: "sound exceeds the bounded data cache and remains voice-local",
                        logicalPath: logicalPath
                    )
                }
            } catch {
                emit(
                    code: .assetResolutionFailed,
                    severity: .error,
                    bus: bus,
                    message: "sound resolution failed: \(error)",
                    logicalPath: logicalPath
                )
                return
            }
        }

        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(data: data)
        } catch {
            emit(
                code: .decodeFailed,
                severity: .error,
                bus: bus,
                message: "unsupported or corrupt WAV/MP3: \(error)",
                logicalPath: logicalPath
            )
            return
        }
        player.delegate = self
        player.volume = effectiveVolume(
            bus: bus,
            eventGain: normalizedGain
        )
        player.prepareToPlay()
        voices[targetID]?.player.stop()
        voices[targetID] = Voice(
            id: targetID,
            path: logicalPath,
            bus: bus,
            eventGain: normalizedGain,
            player: player,
            lastUse: useCounter
        )
        guard player.play() else {
            voices.removeValue(forKey: targetID)
            emit(
                code: .playerRefused,
                severity: .error,
                bus: bus,
                message: "AVAudioPlayer refused new voice \(targetID)",
                logicalPath: logicalPath
            )
            return
        }
        emit(
            code: .playing,
            severity: .info,
            bus: bus,
            message: "playing on new voice \(targetID)",
            logicalPath: logicalPath
        )
    }

    private func applyVolumeToAllVoices() {
        for voice in voices.values {
            voice.player.volume = effectiveVolume(
                bus: voice.bus,
                eventGain: voice.eventGain
            )
        }
    }

    private func effectiveVolume(
        bus: GModAudioBus,
        eventGain: Float
    ) -> Float {
        settingsStore.settings.effectiveVolume(for: bus) * eventGain
    }

    private func configureAudioSession(context: String) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.ambient, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            emit(
                code: .audioSessionFailed,
                severity: .error,
                bus: .menu,
                message: "AVAudioSession \(context) failed: \(error)"
            )
        }
    }

    private func emit(
        code: GModAudioDiagnosticCode,
        severity: GModAudioDiagnosticSeverity,
        bus: GModAudioBus,
        message: String,
        logicalPath: String? = nil
    ) {
        diagnostic(GModAudioDiagnostic(
            code: code,
            severity: severity,
            bus: bus,
            message: message,
            logicalPath: logicalPath
        ))
    }
}
