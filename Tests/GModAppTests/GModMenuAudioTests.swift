import Foundation
import XCTest
@testable import GModApp

final class GModMenuAudioTests: XCTestCase {
    func testStockLuaSoundNamesResolveInsideSoundWithoutLosingNamespace() {
        for file in ["ui_click.wav", "ui_hover.wav", "ui_return.wav"] {
            XCTAssertEqual(
                GModMenuSoundPath.normalize(
                    "garrysmod/\(file)",
                    origin: .lua
                ),
                "sound/garrysmod/\(file)"
            )
        }
        XCTAssertEqual(
            GModMenuSoundPath.normalize(
                "npc/roller/mine/rmine_chirp_answer1.wav",
                origin: .lua
            ),
            "sound/npc/roller/mine/rmine_chirp_answer1.wav"
        )
        XCTAssertEqual(
            GModMenuSoundPath.normalize(
                "sound/buttons/button15.wav",
                origin: .lua
            ),
            "sound/buttons/button15.wav"
        )
    }

    func testHTMLSoundResolutionDistinguishesLogicalAndRelativePaths() {
        let document = URL(string: "asset://garrysmod/html/menu.html")!
        XCTAssertEqual(
            GModMenuSoundPath.normalize(
                "garrysmod/ui_hover.wav",
                origin: .html,
                documentURL: document
            ),
            "sound/garrysmod/ui_hover.wav"
        )
        XCTAssertEqual(
            GModMenuSoundPath.normalize(
                "../sound/ui/buttonclick.wav",
                origin: .html,
                documentURL: document
            ),
            "sound/ui/buttonclick.wav"
        )
        XCTAssertEqual(
            GModMenuSoundPath.normalize(
                "audio/click.mp3?revision=2",
                origin: .html,
                documentURL: document
            ),
            "html/audio/click.mp3"
        )
        XCTAssertEqual(
            GModMenuSoundPath.normalize(
                "asset://garrysmod/sound/ui/click.wav",
                origin: .html
            ),
            "sound/ui/click.wav"
        )
    }

    func testSoundNormalizationRejectsTraversalRemoteAndUnsupportedMedia() {
        XCTAssertNil(GModMenuSoundPath.normalize(
            "../../escape.wav",
            origin: .html,
            documentURL: URL(string: "asset://garrysmod/html/menu.html")!
        ))
        XCTAssertNil(GModMenuSoundPath.normalize(
            "https://example.invalid/click.wav",
            origin: .html
        ))
        XCTAssertNil(GModMenuSoundPath.normalize("ui/click.ogg", origin: .lua))
    }

    func testBoundedDataCacheEvictsLeastRecentlyUsedAndRejectsOversize() {
        var cache = GModMenuBoundedDataCache(
            maximumByteCount: 6,
            maximumEntryCount: 2
        )
        XCTAssertTrue(cache.insert(Data([1, 2]), for: "a"))
        XCTAssertTrue(cache.insert(Data([3, 4]), for: "b"))
        XCTAssertEqual(cache.data(for: "a"), Data([1, 2]))
        XCTAssertTrue(cache.insert(Data([5, 6, 7]), for: "c"))

        XCTAssertNil(cache.data(for: "b"))
        XCTAssertEqual(cache.data(for: "a"), Data([1, 2]))
        XCTAssertEqual(cache.data(for: "c"), Data([5, 6, 7]))
        XCTAssertLessThanOrEqual(cache.byteCount, 6)
        XCTAssertLessThanOrEqual(cache.count, 2)
        XCTAssertFalse(cache.insert(Data(repeating: 0, count: 7), for: "large"))
    }

    func testVoicePolicyCreatesConcurrentSameSoundVoicesBeforeStealing() {
        let first = GModMenuVoiceSlot(
            id: 1,
            path: "sound/ui/click.wav",
            bus: .menu,
            isPlaying: true,
            lastUse: 1
        )
        XCTAssertEqual(
            GModMenuVoicePoolPolicy.decision(
                for: first.path,
                bus: .menu,
                slots: [first],
                maximumVoiceCount: 16,
                maximumVoicesPerSound: 4
            ),
            .create
        )

        let fourPlaying = (1...4).map {
            GModMenuVoiceSlot(
                id: $0,
                path: first.path,
                bus: .menu,
                isPlaying: true,
                lastUse: UInt64($0)
            )
        }
        XCTAssertEqual(
            GModMenuVoicePoolPolicy.decision(
                for: first.path,
                bus: .menu,
                slots: fourPlaying,
                maximumVoiceCount: 16,
                maximumVoicesPerSound: 4
            ),
            .steal(1)
        )

        var idle = first
        idle = GModMenuVoiceSlot(
            id: idle.id,
            path: idle.path,
            bus: idle.bus,
            isPlaying: false,
            lastUse: idle.lastUse
        )
        XCTAssertEqual(
            GModMenuVoicePoolPolicy.decision(
                for: first.path,
                bus: .menu,
                slots: [idle],
                maximumVoiceCount: 16,
                maximumVoicesPerSound: 4
            ),
            .reuse(1)
        )

        XCTAssertEqual(
            GModMenuVoicePoolPolicy.decision(
                for: first.path,
                bus: .gameplay,
                slots: [first],
                maximumVoiceCount: 16,
                maximumVoicesPerSound: 4
            ),
            .create
        )
    }

    func testAudioAndDeveloperSettingsPersistWithSafeDefaults() {
        let suite = "GModMenuSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let audio = GModMenuAudioSettingsStore(defaults: defaults)
        XCTAssertEqual(audio.settings, GModMenuAudioSettings())
        audio.save(GModMenuAudioSettings(
            masterVolume: 1.5,
            menuVolume: -1,
            gameplayVolume: 0.4
        ))
        XCTAssertEqual(audio.settings.masterVolume, 1)
        XCTAssertEqual(audio.settings.menuVolume, 0)
        XCTAssertEqual(audio.settings.gameplayVolume, 0.4)
        XCTAssertEqual(
            GModMenuAudioSettingsStore(defaults: defaults).settings,
            GModMenuAudioSettings(
                masterVolume: 1,
                menuVolume: 0,
                gameplayVolume: 0.4
            )
        )

        let volumes = GModMenuAudioSettings(
            masterVolume: 0.5,
            menuVolume: 0.4,
            gameplayVolume: 0.8
        )
        XCTAssertEqual(volumes.effectiveMenuVolume, 0.2, accuracy: 0.0001)
        XCTAssertEqual(
            volumes.effectiveGameplayVolume,
            0.4,
            accuracy: 0.0001
        )

        let developer = GModDeveloperDiagnosticsSettingsStore(defaults: defaults)
        XCTAssertFalse(developer.isEnabled)
        developer.setEnabled(true)
        XCTAssertTrue(
            GModDeveloperDiagnosticsSettingsStore(defaults: defaults).isEnabled
        )
    }

    func testTypedAudioDiagnosticsOnlyCreateProblemsForFailures() throws {
        XCTAssertNil(GModAudioProblemMapper.record(for: GModAudioDiagnostic(
            code: .playing,
            severity: .info,
            bus: .gameplay,
            message: "playing",
            logicalPath: "sound/ui/click.wav"
        )))

        let warning = try XCTUnwrap(GModAudioProblemMapper.record(
            for: GModAudioDiagnostic(
                code: .cacheBypassed,
                severity: .warning,
                bus: .gameplay,
                message: "bounded cache bypass",
                logicalPath: "sound/ui/large.wav"
            )
        ))
        XCTAssertEqual(warning.kind, .audio)
        XCTAssertEqual(warning.severity, .warning)
        XCTAssertEqual(warning.source, "CLIENT surface.PlaySound")
        XCTAssertTrue(warning.detail.contains("sound/ui/large.wav"))
    }
}
