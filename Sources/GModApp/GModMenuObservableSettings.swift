import Combine
import Foundation

/// One observable snapshot lets MainView/loading overlays consume the exact
/// catalog selected by the stock Home language control without reopening the
/// content ZIP. Home remains the owner of language changes.
final class GModMenuLocalizationSelectionStore: ObservableObject {
    static let shared: GModMenuLocalizationSelectionStore = {
        let catalog = GModMenuLocalizationCatalog(
            phrasesByLanguage: GModBundledAppLocalization.load()
        )
        return GModMenuLocalizationSelectionStore(
            catalog: catalog,
            preferenceStore: GModMenuLanguagePreferenceStore()
        )
    }()

    @Published private(set) var snapshot: GModMenuLanguageSnapshot
    @Published private(set) var availableLanguageCodes: [String]

    init(
        catalog: GModMenuLocalizationCatalog,
        preferenceStore: GModMenuLanguagePreferenceStore,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) {
        let codes = catalog.availableLanguageCodes
        let code = preferenceStore.resolvedLanguageCode(
            availableLanguageCodes: codes,
            preferredLanguages: preferredLanguages
        )
        snapshot = catalog.snapshot(languageCode: code)
        availableLanguageCodes = codes
    }

    func publish(
        _ replacement: GModMenuLanguageSnapshot,
        availableLanguageCodes: [String]
    ) {
        snapshot = replacement
        self.availableLanguageCodes = availableLanguageCodes
    }

    /// Publishes a Home-menu request only after re-reading the active pack's
    /// catalog. The callback's phrase payload is deliberately not trusted: the
    /// same source-backed snapshot must drive WKWebView, Loading, Options and
    /// native control labels.
    @discardableResult
    func publishHomeSelection(
        _ requested: GModMenuLanguageSnapshot,
        catalog: GModMenuLocalizationCatalog,
        preferenceStore: GModMenuLanguagePreferenceStore
    ) -> Bool {
        let code = GModMenuLocalizationCatalog.normalizedCode(requested.code)
        let codes = catalog.availableLanguageCodes
        guard catalog.contains(languageCode: code),
              preferenceStore.persist(
                languageCode: code,
                availableLanguageCodes: codes
              ) else {
            return false
        }
        publish(catalog.snapshot(languageCode: code), availableLanguageCodes: codes)
        return true
    }
}
