import Combine
import Foundation

/// Garry's PAD-only preferences. They are deliberately separate from Source
/// convars: only settings that the iPad host can actually honor live here.
@MainActor
final class GModContentSettingsStore: ObservableObject {
    static let shared = GModContentSettingsStore()

    static let automaticallyReloadKey =
        "GarrysPAD.ContentPack.AutomaticallyReload.v1"
    static let menuBackgroundsEnabledKey =
        "GarrysPAD.Home.BackgroundsEnabled.v1"

    @Published private(set) var automaticallyReloadsLastPack: Bool
    @Published private(set) var menuBackgroundsEnabled: Bool

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        automaticallyReloadsLastPack = Self.bool(
            defaults,
            key: Self.automaticallyReloadKey,
            defaultValue: true
        )
        menuBackgroundsEnabled = Self.bool(
            defaults,
            key: Self.menuBackgroundsEnabledKey,
            defaultValue: true
        )
    }

    func setAutomaticallyReloadsLastPack(_ enabled: Bool) {
        guard enabled != automaticallyReloadsLastPack else { return }
        automaticallyReloadsLastPack = enabled
        defaults.set(enabled, forKey: Self.automaticallyReloadKey)
    }

    func setMenuBackgroundsEnabled(_ enabled: Bool) {
        guard enabled != menuBackgroundsEnabled else { return }
        menuBackgroundsEnabled = enabled
        defaults.set(enabled, forKey: Self.menuBackgroundsEnabledKey)
    }

    private static func bool(
        _ defaults: UserDefaults,
        key: String,
        defaultValue: Bool
    ) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }
}
