import Foundation
import XCTest
@testable import GModApp

final class GModMenuLocalizationTests: XCTestCase {
    func testJavaPropertiesEscapesSeparatorsUnicodeAndContinuations() throws {
        let source = #"""
        # comment
        ! another comment
        escaped\ key\:\==value\nnext
        japanese=\u65E5\u672C\u8A9E
        emoji=\uD83D\uDE00
        continued=first\
             second\
        \tthird
        whitespace\ key : spaced\ value
        """#

        let parsed = try GModJavaPropertiesParser.parse(source)

        XCTAssertEqual(parsed["escaped key:="], "value\nnext")
        XCTAssertEqual(parsed["japanese"], "日本語")
        XCTAssertEqual(parsed["emoji"], "😀")
        XCTAssertEqual(parsed["continued"], "firstsecond\tthird")
        XCTAssertEqual(parsed["whitespace key"], "spaced value")
    }

    func testJavaPropertiesDataFallsBackToLatin1() throws {
        let data = Data([0x6B, 0x65, 0x79, 0x3D, 0xE9])
        XCTAssertEqual(
            try GModJavaPropertiesParser.parse(data: data)["key"],
            "é"
        )
    }

    func testJavaPropertiesRejectsMalformedUnicodeEscape() {
        XCTAssertThrowsError(try GModJavaPropertiesParser.parse("key=\\u12Q4")) {
            XCTAssertEqual(
                $0 as? GModJavaPropertiesParserError,
                .invalidUnicodeEscape(line: 1, escape: "\\u12Q4")
            )
        }
    }

    func testCatalogUsesRealEnglishAsFallbackAndJapaneseAsOverride() {
        let catalog = GModMenuLocalizationCatalog(phrasesByLanguage: [
            "en": [
                "new_game": "English from pack",
                "start_game": "English fallback from pack",
            ],
            "ja": [
                "new_game": "日本語パック",
            ],
        ])

        let snapshot = catalog.snapshot(languageCode: "ja-JP")
        XCTAssertEqual(snapshot.code, "ja")
        XCTAssertEqual(snapshot.phrase("new_game"), "日本語パック")
        XCTAssertEqual(snapshot.phrase("start_game"), "English fallback from pack")
        XCTAssertEqual(snapshot.phrase("missing.key"), "missing.key")
        XCTAssertEqual(snapshot.appText(.startingGame), "English fallback from pack")
    }

    func testLanguagePreferencePersistsOnlyAvailableNormalizedCodes() {
        let suite = "GModMenuLanguagePreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GModMenuLanguagePreferenceStore(defaults: defaults)

        XCTAssertEqual(
            store.resolvedLanguageCode(
                availableLanguageCodes: ["en", "ja"],
                preferredLanguages: ["ja-JP"]
            ),
            "ja"
        )
        XCTAssertTrue(store.persist(
            languageCode: "EN-us",
            availableLanguageCodes: ["en", "ja"]
        ))
        XCTAssertEqual(defaults.string(forKey: GModMenuLanguagePreferenceStore.key), "en")
        XCTAssertEqual(
            store.resolvedLanguageCode(
                availableLanguageCodes: ["en", "ja"],
                preferredLanguages: ["ja-JP"]
            ),
            "en"
        )
        XCTAssertFalse(store.persist(
            languageCode: "fr",
            availableLanguageCodes: ["en", "ja"]
        ))
        XCTAssertEqual(defaults.string(forKey: GModMenuLanguagePreferenceStore.key), "en")
    }

    func testBundledAppCatalogHasEnglishAndJapaneseForEveryLoadingStage() {
        let catalogs = GModBundledAppLocalization.load()
        let identifiers = [
            "read-bsp",
            "parse-world",
            "build-world-geometry",
            "prepare-collision",
            "start-server-lua",
            "load-server-gamemode",
            "start-client-lua",
            "load-client-gamemode",
            "prepare-materials-textures",
            "await-first-metal-frame",
            "complete",
        ]

        for code in ["en", "ja"] {
            let phrases = catalogs[code] ?? [:]
            for identifier in identifiers {
                XCTAssertFalse(
                    phrases["garryspad.loading.\(identifier)", default: ""].isEmpty,
                    "missing \(code) phrase for \(identifier)"
                )
            }
            for key in [
                "garryspad.control.pause",
                "garryspad.control.jump",
                "garryspad.control.undo",
                "garryspad.control.spawn-menu",
                "garryspad.control.close-spawn-menu",
                "garryspad.control.context-menu",
                "garryspad.control.close-context-menu",
                "garryspad.control.ok",
                "garryspad.ios.quit-unavailable",
            ] {
                XCTAssertFalse(
                    phrases[key, default: ""].isEmpty,
                    "missing \(code) phrase for \(key)"
                )
            }
        }
    }

    func testBundledPermissionCatalogHasExactEnglishJapaneseKeyParity() throws {
        let catalogs = GModBundledAppLocalization.load()
        let english = try XCTUnwrap(catalogs["en"])
        let japanese = try XCTUnwrap(catalogs["ja"])
        XCTAssertEqual(Set(english.keys), Set(japanese.keys))

        for key in [
            "permission.connect",
            "garryspad.permissions.server",
            "garryspad.permissions.connect",
            "garryspad.permissions.temporary",
            "garryspad.permissions.permanent",
            "garryspad.permissions.not-granted",
            "garryspad.permissions.grant-temporary",
            "garryspad.permissions.grant-permanent",
            "garryspad.permissions.revoke",
            "garryspad.permissions.none",
            "garryspad.permissions.connect-unavailable-action",
            "garryspad.permissions.native-boundary",
            "garryspad.problem.permissions-limited",
            "garryspad.problem.permissions-limited-detail",
            "garryspad.problem.permissions-storage",
        ] {
            XCTAssertFalse(english[key, default: ""].isEmpty, "missing en \(key)")
            XCTAssertFalse(japanese[key, default: ""].isEmpty, "missing ja \(key)")
        }
    }

    @MainActor
    func testHomeLanguageCallbackPublishesPackCatalogToNativeSurfaces() {
        let suite = "GModHomeLanguagePublicationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferenceStore = GModMenuLanguagePreferenceStore(defaults: defaults)
        let catalog = GModMenuLocalizationCatalog(phrasesByLanguage: [
            "en": [
                "garryspad.loading.read-bsp": "EN loading from catalog",
                "garryspad.options.title": "EN options from catalog",
                "garryspad.control.pause": "EN pause from catalog",
            ],
            "ja": [
                "garryspad.loading.read-bsp": "JA loading from catalog",
                "garryspad.options.title": "JA options from catalog",
                "garryspad.control.pause": "JA pause from catalog",
            ],
        ])
        let selection = GModMenuLocalizationSelectionStore(
            catalog: catalog,
            preferenceStore: preferenceStore,
            preferredLanguages: ["en-US"]
        )
        XCTAssertEqual(selection.snapshot.code, "en")

        let homeCallback: @MainActor (GModMenuLanguageSnapshot) -> Void = {
            requested in
            XCTAssertTrue(selection.publishHomeSelection(
                requested,
                catalog: catalog,
                preferenceStore: preferenceStore
            ))
        }
        // A callback may only request a code. Native strings must be rebuilt
        // from the validated catalog, never copied from an arbitrary payload.
        homeCallback(GModMenuLanguageSnapshot(
            code: "ja-JP",
            phrases: ["garryspad.control.pause": "untrusted callback phrase"]
        ))

        XCTAssertEqual(selection.snapshot.code, "ja")
        XCTAssertEqual(
            selection.snapshot.phrase("garryspad.loading.read-bsp"),
            "JA loading from catalog"
        )
        XCTAssertEqual(
            selection.snapshot.phrase("garryspad.options.title"),
            "JA options from catalog"
        )
        XCTAssertEqual(
            selection.snapshot.appText(.pauseButton),
            "JA pause from catalog"
        )
        XCTAssertEqual(
            defaults.string(forKey: GModMenuLanguagePreferenceStore.key),
            "ja"
        )
        XCTAssertFalse(selection.snapshot.phrases.values.contains(
            "untrusted callback phrase"
        ))
    }
}
