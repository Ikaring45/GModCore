import Combine
import Foundation
import GModGameAssets
import GModGameSession

private final class GModSecurityScopedResourceLease: @unchecked Sendable {
    let url: URL
    let status: GModContentSecurityScopeStatus
    private let didStartAccess: Bool

    init(url: URL) {
        // Preserve the exact document-picker URL when starting the grant.
        // Rebuilding or standardizing the URL first can discard its ephemeral
        // security-scope association.
        self.url = url
        didStartAccess = url.startAccessingSecurityScopedResource()
        if didStartAccess {
            status = .active
        } else if FileManager.default.isReadableFile(atPath: url.path) {
            status = .inheritedOrNotRequired
        } else {
            status = .unavailable
        }
    }

    deinit {
        if didStartAccess {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

enum GModContentSecurityScopeStatus: String, Equatable, Sendable {
    case active
    case inheritedOrNotRequired
    case unavailable

    var localizationKey: String {
        switch self {
        case .active: return "garryspad.content.security.active"
        case .inheritedOrNotRequired:
            return "garryspad.content.security.inherited"
        case .unavailable: return "garryspad.content.security.unavailable"
        }
    }
}

enum GModContentManifestStatus: Equatable, Sendable {
    /// Complete schema/index authorization and the runtime-critical payloads
    /// have passed ZIP CRC plus manifest SHA-256.
    case coreIntegrityVerified
    /// Every manifest-authorized payload has passed ZIP CRC plus SHA-256.
    case fullIntegrityVerified

    var localizationKey: String {
        switch self {
        case .coreIntegrityVerified:
            return "garryspad.content.manifest.core-verified"
        case .fullIntegrityVerified:
            return "garryspad.content.manifest.full-verified"
        }
    }
}

enum GModContentVerificationStage: Equatable, Sendable {
    case candidateCore
    case fullPack

    var localizationKey: String {
        switch self {
        case .candidateCore: return "garryspad.content.verification.core"
        case .fullPack: return "garryspad.content.verification.full"
        }
    }
}

struct GModContentVerificationState: Equatable, Sendable {
    let stage: GModContentVerificationStage
    let progress: GarrysPADContentVerificationProgress

    var fractionCompleted: Double {
        if progress.totalByteCount > 0 {
            return min(
                1,
                Double(progress.completedByteCount) /
                    Double(progress.totalByteCount)
            )
        }
        guard progress.totalFileCount > 0 else { return 0 }
        return min(
            1,
            Double(progress.completedFileCount) /
                Double(progress.totalFileCount)
        )
    }
}

struct GModContentPackMetadata: Equatable, Sendable {
    let zipFileName: String
    let profile: String?
    let fileCount: Int
    let payloadByteCount: UInt64
    let archiveByteCount: UInt64?
    let manifestStatus: GModContentManifestStatus
    let securityScopeStatus: GModContentSecurityScopeStatus
    let mountedVPKCount: Int
}

private enum GModContentPackRuntimeValidationError: Error,
    CustomStringConvertible
{
    case missingRuntimeEntry(String)
    case invalidManifest(String)

    var description: String {
        switch self {
        case let .missingRuntimeEntry(path):
            return "content pack is missing runtime entry: \(path)"
        case let .invalidManifest(reason):
            return "content-pack manifest is invalid: \(reason)"
        }
    }
}

private final class GModContentValidationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

private struct GModContentPackBookmarkStore {
    static let storageKey = "GarrysPAD.ContentPack.SecurityScopedBookmark.v1"

    let defaults: UserDefaults

    func resolve() throws -> (url: URL, isStale: Bool)? {
        guard let bookmark = defaults.data(forKey: Self.storageKey) else {
            return nil
        }
        var isStale = false
        #if os(iOS)
        // The document picker supplies iOS security scope. Foundation marks
        // the macOS-only explicit security-scope bookmark option unavailable
        // on iOS, so preserve the picker's implicit scope in a normal bookmark.
        let resolutionOptions: URL.BookmarkResolutionOptions = [.withoutUI]
        #else
        let resolutionOptions: URL.BookmarkResolutionOptions = [
            .withSecurityScope,
            .withoutUI,
        ]
        #endif
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: resolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }

    func save(url: URL) throws {
        #if os(iOS)
        let creationOptions: URL.BookmarkCreationOptions = []
        #else
        let creationOptions: URL.BookmarkCreationOptions = [
            .withSecurityScope,
            .securityScopeAllowOnlyReadAccess,
        ]
        #endif
        let bookmark = try url.bookmarkData(
            options: creationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(bookmark, forKey: Self.storageKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.storageKey)
    }
}

@MainActor
final class GModPlaygroundContentModel: ObservableObject {
    enum State {
        case loading
        case missing
        case ready(GarrysPADContentPack, backgroundJPEG: Data, logoPNG: Data?)
        case failed(String)
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var assetSource: GModContentPackAssetSource?
    @Published private(set) var persistenceWarning: String?
    @Published private(set) var metadata: GModContentPackMetadata?
    @Published private(set) var lastError: String?
    @Published private(set) var isValidatingCandidate = false
    @Published private(set) var verificationState: GModContentVerificationState?
    @Published private(set) var lastValidationDate: Date?
    @Published private(set) var cacheClearCount: UInt64 = 0
    /// Changes only after a candidate has passed every ZIP/VPK/manifest check
    /// and has become the process-active content source. SwiftUI uses this as
    /// the identity of pack-bound views such as Home's WKWebView. A generation
    /// is required instead of the URL because revalidating a replaced file at
    /// the same Files location must also discard the prior scheme handler,
    /// language catalog, background and audio resolver.
    @Published private(set) var activeMountGeneration: UInt64 = 0

    let settingsStore: GModContentSettingsStore

    private let runtimeFactory: GModAppRuntimeFactory
    private let bookmarkStore: GModContentPackBookmarkStore
    private var securityScope: GModSecurityScopedResourceLease?
    private var loadGeneration: UInt64 = 0
    private var validationCancellation: GModContentValidationCancellation?
    private var validationTask: Task<Void, Never>?

    init(
        runtimeFactory: GModAppRuntimeFactory,
        defaults: UserDefaults = .standard,
        settingsStore: GModContentSettingsStore? = nil
    ) {
        self.runtimeFactory = runtimeFactory
        self.settingsStore = settingsStore
            ?? GModContentSettingsStore(defaults: defaults)
        bookmarkStore = GModContentPackBookmarkStore(defaults: defaults)
        if self.settingsStore.automaticallyReloadsLastPack {
            reloadSavedSelection()
        } else {
            beginMissingState()
        }
    }

    /// Reopens the previously selected Files/iCloud Drive ZIP. Large playable
    /// packs deliberately do not live in the app bundle: embedding a multi-GB
    /// resource forces Swift Playgrounds to copy and sign it before launch.
    func reloadSavedSelection() {
        do {
            guard let saved = try bookmarkStore.resolve() else {
                beginMissingState()
                return
            }
            let lease = GModSecurityScopedResourceLease(url: saved.url)
            if saved.isStale {
                do {
                    try bookmarkStore.save(url: lease.url)
                    persistenceWarning = nil
                } catch {
                    persistenceWarning =
                        "The ZIP opened, but its saved Files reference could not be refreshed: " +
                        String(describing: error)
                }
            }
            beginCandidateLoad(
                url: lease.url,
                securityScope: lease,
                saveBookmarkOnSuccess: false,
                clearBookmarkOnFailure: true
            )
        } catch {
            bookmarkStore.clear()
            beginFailure(
                "The saved Files reference is no longer available. Choose the content ZIP again. " +
                    String(describing: error)
            )
        }
    }

    /// Mounts a document-picker URL in place. The lease stays alive for as
    /// long as the content model can issue ZIP/VPK range reads.
    func selectContentPack(url: URL) {
        let lease = GModSecurityScopedResourceLease(url: url)
        beginCandidateLoad(
            url: lease.url,
            securityScope: lease,
            saveBookmarkOnSuccess: true,
            clearBookmarkOnFailure: false
        )
    }

    func reportSelectionFailure(_ error: Error) {
        let message = "The Files picker could not open the selected ZIP: \(error)"
        lastError = message
        recordContentProblem(message)
        guard !hasReadyContent else { return }
        beginFailure(message)
    }

    func forgetSelection() {
        cancelCurrentValidation(preserveReadyState: false)
        bookmarkStore.clear()
        beginMissingState()
    }

    func revalidateActiveSelection() {
        beginFullRevalidation()
    }

    /// Cancels candidate/full verification at a real chunk boundary. An
    /// already-active mount, its prior integrity label and validation date are
    /// intentionally left untouched.
    func cancelValidation() {
        cancelCurrentValidation(preserveReadyState: hasReadyContent)
    }

    func clearCaches() {
        runtimeFactory.clearContentCaches()
        cacheClearCount &+= 1
    }

    func diagnosticsLines(currentMap: String?) -> [String] {
        let cache = runtimeFactory.cacheDiagnostics()
        var lines = ["[Garry's PAD][Content]"]
        if let metadata {
            lines.append("ZIP: \(metadata.zipFileName)")
            lines.append("Profile: \(metadata.profile ?? "unavailable")")
            lines.append("Files: \(metadata.fileCount)")
            lines.append("Payload bytes: \(metadata.payloadByteCount)")
            lines.append("Archive bytes: \(metadata.archiveByteCount.map(String.init) ?? "unavailable")")
            lines.append("Manifest: \(metadata.manifestStatus)")
            lines.append("Security scope: \(metadata.securityScopeStatus.rawValue)")
            lines.append("Mounted VPKs: \(metadata.mountedVPKCount)")
        } else {
            lines.append("ZIP: none")
        }
        if let verificationState {
            let progress = verificationState.progress
            lines.append(
                "Verification: \(verificationState.stage) " +
                    "files=\(progress.completedFileCount)/\(progress.totalFileCount) " +
                    "bytes=\(progress.completedByteCount)/\(progress.totalByteCount) " +
                    "path=\(progress.currentPath ?? "complete")"
            )
        }
        lines.append("Current map: \(currentMap ?? "none")")
        lines.append("Last error: \(lastError ?? "none")")
        lines.append(
            "Caches: textures=\(cache.textures)/\(cache.textureBytes)B " +
                "glyphs=\(cache.glyphs)/\(cache.glyphBytes)B"
        )
        return lines
    }

    private func beginCandidateLoad(
        url: URL,
        securityScope replacementScope: GModSecurityScopedResourceLease,
        saveBookmarkOnSuccess: Bool,
        clearBookmarkOnFailure: Bool
    ) {
        cancelCurrentValidation(preserveReadyState: true)
        loadGeneration &+= 1
        let generation = loadGeneration
        let preservedReadyContent = hasReadyContent
        if !preservedReadyContent {
            runtimeFactory.unmountContentPack()
            state = .loading
        }
        isValidatingCandidate = true
        verificationState = nil
        let runtimeFactory = self.runtimeFactory
        let cancellation = GModContentValidationCancellation()
        validationCancellation = cancellation
        let progressSink = makeProgressSink(
            generation: generation,
            cancellation: cancellation,
            stage: .candidateCore
        )

        validationTask = Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    // Retain the security grant through all background ZIP and
                    // nested-VPK indexing, even if the view disappears.
                    _ = replacementScope
                    let pack = try GarrysPADContentPack(url: url)
                    let manifest = try GarrysPADContentManifestValidator
                        .loadAndValidateIndex(from: pack)
                    try GarrysPADContentManifestValidator.verifyPayloads(
                        in: pack,
                        manifest: manifest,
                        paths: Set([
                            "garrysmod/maps/gm_construct.bsp",
                            "garrysmod/maps/gm_flatgrass.bsp",
                            "garrysmod/html/img/bg.jpg",
                            "garrysmod/html/menu.html",
                        ]),
                        shouldCancel: { cancellation.isCancelled },
                        progress: progressSink
                    )
                    if cancellation.isCancelled { throw CancellationError() }
                    let background = try pack.data(
                        for: "garrysmod/html/img/bg.jpg",
                        maximumByteCount: 4 * 1_024 * 1_024
                    )
                    let logo = try? pack.data(
                        for: "garrysmod/html/img/gmod_logo_brave.png",
                        maximumByteCount: 4 * 1_024 * 1_024
                    )
                    guard pack.contains("garrysmod/html/menu.html") else {
                        throw GModContentPackRuntimeValidationError
                            .missingRuntimeEntry("garrysmod/html/menu.html")
                    }
                    for mapPath in [
                        "garrysmod/maps/gm_construct.bsp",
                        "garrysmod/maps/gm_flatgrass.bsp",
                    ] {
                        let signature = try pack.data(
                            for: mapPath,
                            offset: 0,
                            count: 4
                        )
                        guard signature == Data([0x56, 0x42, 0x53, 0x50]) else {
                            throw GModContentPackRuntimeValidationError
                                .invalidManifest(
                                    "runtime map does not start with VBSP: \(mapPath)"
                                )
                        }
                    }
                    if cancellation.isCancelled { throw CancellationError() }
                    let source = try runtimeFactory.prepareContentPack(pack)
                    if cancellation.isCancelled { throw CancellationError() }
                    let metadata = try Self.metadata(
                        pack: pack,
                        manifest: manifest,
                        manifestStatus: .coreIntegrityVerified,
                        source: source,
                        securityScopeStatus: replacementScope.status
                    )
                    return (pack, background, logo, source, metadata)
                }.value
                guard let self, generation == loadGeneration else { return }
                cancellation.cancel()
                if saveBookmarkOnSuccess {
                    do {
                        try bookmarkStore.save(url: replacementScope.url)
                        persistenceWarning = nil
                    } catch {
                        // Do not leave a bookmark for the previously mounted
                        // ZIP while reporting that the newly active candidate
                        // could not be persisted.
                        bookmarkStore.clear()
                        persistenceWarning =
                            "The ZIP is usable now, but must be selected again after relaunch: " +
                            String(describing: error)
                    }
                }
                runtimeFactory.activateContentPack(result.3)
                assetSource = result.3
                securityScope = replacementScope
                metadata = result.4
                lastError = nil
                lastValidationDate = Date()
                isValidatingCandidate = false
                verificationState = nil
                validationCancellation = nil
                validationTask = nil
                activeMountGeneration = activeMountGeneration &+ 1
                state = .ready(
                    result.0,
                    backgroundJPEG: result.1,
                    logoPNG: result.2
                )
            } catch {
                guard let self, generation == loadGeneration else { return }
                cancellation.cancel()
                let message = String(describing: error)
                lastError = message
                isValidatingCandidate = false
                verificationState = nil
                validationCancellation = nil
                validationTask = nil
                if clearBookmarkOnFailure {
                    bookmarkStore.clear()
                }
                recordContentProblem(message)
                if !preservedReadyContent {
                    runtimeFactory.unmountContentPack()
                    assetSource = nil
                    securityScope = nil
                    metadata = nil
                    state = .failed(message)
                }
            }
        }
    }

    private func beginFullRevalidation() {
        guard case let .ready(activePack, _, _) = state else { return }
        cancelCurrentValidation(preserveReadyState: true)
        loadGeneration &+= 1
        let generation = loadGeneration
        let activeScope = securityScope
        let scopeStatus = metadata?.securityScopeStatus ?? .unavailable
        let runtimeFactory = self.runtimeFactory
        let cancellation = GModContentValidationCancellation()
        validationCancellation = cancellation
        isValidatingCandidate = true
        verificationState = nil
        let progressSink = makeProgressSink(
            generation: generation,
            cancellation: cancellation,
            stage: .fullPack
        )

        validationTask = Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    // Keep the original Files grant alive for the complete
                    // multi-gigabyte streaming pass.
                    _ = activeScope
                    let pack = try GarrysPADContentPack(url: activePack.archiveURL)
                    let manifest = try GarrysPADContentManifestValidator
                        .loadAndValidateIndex(from: pack)
                    try GarrysPADContentManifestValidator.verifyPayloads(
                        in: pack,
                        manifest: manifest,
                        shouldCancel: { cancellation.isCancelled },
                        progress: progressSink
                    )
                    if cancellation.isCancelled { throw CancellationError() }
                    let background = try pack.data(
                        for: "garrysmod/html/img/bg.jpg",
                        maximumByteCount: 4 * 1_024 * 1_024
                    )
                    let logo = try? pack.data(
                        for: "garrysmod/html/img/gmod_logo_brave.png",
                        maximumByteCount: 4 * 1_024 * 1_024
                    )
                    let source = try runtimeFactory.prepareContentPack(pack)
                    if cancellation.isCancelled { throw CancellationError() }
                    let metadata = try Self.metadata(
                        pack: pack,
                        manifest: manifest,
                        manifestStatus: .fullIntegrityVerified,
                        source: source,
                        securityScopeStatus: scopeStatus
                    )
                    return (pack, background, logo, source, metadata)
                }.value
                guard let self, generation == loadGeneration else { return }
                cancellation.cancel()
                runtimeFactory.activateContentPack(result.3)
                assetSource = result.3
                metadata = result.4
                lastError = nil
                lastValidationDate = Date()
                isValidatingCandidate = false
                verificationState = nil
                validationCancellation = nil
                validationTask = nil
                activeMountGeneration = activeMountGeneration &+ 1
                state = .ready(
                    result.0,
                    backgroundJPEG: result.1,
                    logoPNG: result.2
                )
            } catch {
                guard let self, generation == loadGeneration else { return }
                cancellation.cancel()
                isValidatingCandidate = false
                verificationState = nil
                validationCancellation = nil
                validationTask = nil
                if error is CancellationError { return }
                let message = String(describing: error)
                lastError = message
                recordContentProblem(message)
                // Transactional boundary: prior state/source/metadata/mount and
                // prior verification date remain exactly as they were.
            }
        }
    }

    private func makeProgressSink(
        generation: UInt64,
        cancellation: GModContentValidationCancellation,
        stage: GModContentVerificationStage
    ) -> @Sendable (GarrysPADContentVerificationProgress) -> Void {
        { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self,
                      generation == loadGeneration,
                      validationCancellation === cancellation,
                      !cancellation.isCancelled else { return }
                verificationState = GModContentVerificationState(
                    stage: stage,
                    progress: progress
                )
            }
        }
    }

    private func cancelCurrentValidation(preserveReadyState: Bool) {
        let wasValidating = isValidatingCandidate
        validationCancellation?.cancel()
        validationTask?.cancel()
        validationCancellation = nil
        validationTask = nil
        if wasValidating { loadGeneration &+= 1 }
        isValidatingCandidate = false
        verificationState = nil
        guard !preserveReadyState, !hasReadyContent else { return }
        runtimeFactory.unmountContentPack()
        assetSource = nil
        securityScope = nil
        metadata = nil
        persistenceWarning = nil
        state = .missing
    }

    private func beginMissingState() {
        validationCancellation?.cancel()
        validationTask?.cancel()
        validationCancellation = nil
        validationTask = nil
        loadGeneration &+= 1
        runtimeFactory.unmountContentPack()
        state = .missing
        assetSource = nil
        securityScope = nil
        metadata = nil
        isValidatingCandidate = false
        verificationState = nil
        persistenceWarning = nil
    }

    private func beginFailure(_ message: String) {
        validationCancellation?.cancel()
        validationTask?.cancel()
        validationCancellation = nil
        validationTask = nil
        loadGeneration &+= 1
        runtimeFactory.unmountContentPack()
        state = .failed(message)
        assetSource = nil
        securityScope = nil
        metadata = nil
        isValidatingCandidate = false
        verificationState = nil
        lastError = message
    }

    private var hasReadyContent: Bool {
        if case .ready = state { return true }
        return false
    }

    private func recordContentProblem(_ message: String) {
        GModAppDiagnosticsStore.shared.record(
            kind: .contentPack,
            severity: .error,
            title: "#garryspad.problem.content-pack",
            detail: message
        )
    }

    nonisolated private static func metadata(
        pack: GarrysPADContentPack,
        manifest: GarrysPADContentManifest,
        manifestStatus: GModContentManifestStatus,
        source: GModContentPackAssetSource,
        securityScopeStatus: GModContentSecurityScopeStatus
    ) throws -> GModContentPackMetadata {
        let archiveValues = try? pack.archiveURL.resourceValues(
            forKeys: [.fileSizeKey]
        )
        let archiveBytes: UInt64?
        if let fileSize = archiveValues?.fileSize, fileSize >= 0 {
            archiveBytes = UInt64(fileSize)
        } else {
            archiveBytes = nil
        }
        return GModContentPackMetadata(
            zipFileName: pack.archiveURL.lastPathComponent,
            profile: manifest.profile,
            fileCount: manifest.fileCount,
            payloadByteCount: manifest.byteCount,
            archiveByteCount: archiveBytes,
            manifestStatus: manifestStatus,
            securityScopeStatus: securityScopeStatus,
            mountedVPKCount: source.archives.count
        )
    }
}
