import Combine
import Foundation
import GModGameAssets
import GModGameSession

private final class GModSecurityScopedResourceLease: @unchecked Sendable {
    let url: URL
    private let didStartAccess: Bool

    init(url: URL) {
        // Preserve the exact document-picker URL when starting the grant.
        // Rebuilding or standardizing the URL first can discard its ephemeral
        // security-scope association.
        self.url = url
        didStartAccess = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if didStartAccess {
            url.stopAccessingSecurityScopedResource()
        }
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
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }

    func save(url: URL) throws {
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
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

    private let runtimeFactory: GModAppRuntimeFactory
    private let bookmarkStore: GModContentPackBookmarkStore
    private var securityScope: GModSecurityScopedResourceLease?
    private var loadGeneration: UInt64 = 0

    init(
        runtimeFactory: GModAppRuntimeFactory,
        defaults: UserDefaults = .standard
    ) {
        self.runtimeFactory = runtimeFactory
        bookmarkStore = GModContentPackBookmarkStore(defaults: defaults)
        reloadSavedSelection()
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
            beginLoading(url: lease.url, securityScope: lease)
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
        do {
            try bookmarkStore.save(url: lease.url)
            persistenceWarning = nil
        } catch {
            persistenceWarning =
                "The ZIP is usable now, but must be selected again after relaunch: " +
                String(describing: error)
        }
        beginLoading(url: lease.url, securityScope: lease)
    }

    func reportSelectionFailure(_ error: Error) {
        bookmarkStore.clear()
        beginFailure("The Files picker could not open the selected ZIP: \(error)")
    }

    func forgetSelection() {
        bookmarkStore.clear()
        beginMissingState()
    }

    private func beginLoading(
        url: URL,
        securityScope replacementScope: GModSecurityScopedResourceLease
    ) {
        loadGeneration &+= 1
        let generation = loadGeneration
        state = .loading
        assetSource = nil
        securityScope = replacementScope
        let runtimeFactory = self.runtimeFactory

        Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    // Retain the security grant through all background ZIP and
                    // nested-VPK indexing, even if the view disappears.
                    _ = replacementScope
                    let pack = try GarrysPADContentPack(url: url)
                    let background = try pack.data(
                        for: "garrysmod/html/img/bg.jpg",
                        maximumByteCount: 4 * 1_024 * 1_024
                    )
                    let logo = try? pack.data(
                        for: "garrysmod/html/img/gmod_logo_brave.png",
                        maximumByteCount: 4 * 1_024 * 1_024
                    )
                    let source = try runtimeFactory.prepareContentPack(pack)
                    return (pack, background, logo, source)
                }.value
                guard let self, generation == loadGeneration else { return }
                runtimeFactory.activateContentPack(result.3)
                assetSource = result.3
                state = .ready(
                    result.0,
                    backgroundJPEG: result.1,
                    logoPNG: result.2
                )
            } catch {
                guard let self, generation == loadGeneration else { return }
                bookmarkStore.clear()
                assetSource = nil
                securityScope = nil
                state = .failed(String(describing: error))
            }
        }
    }

    private func beginMissingState() {
        loadGeneration &+= 1
        state = .missing
        assetSource = nil
        securityScope = nil
        persistenceWarning = nil
    }

    private func beginFailure(_ message: String) {
        loadGeneration &+= 1
        state = .failed(message)
        assetSource = nil
        securityScope = nil
    }
}
