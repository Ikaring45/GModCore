import XCTest
import GModEngine
import GModLua

final class GMLuaLanguageTests: XCTestCase {
    func testLabelKeepsRawPhraseKeyButMeasuresAndDrawsLocalizedText() throws {
        struct PhraseProbeMeasurer: GMLuaTextMeasurer {
            let fidelity = GMLuaTextMeasurementFidelity.platformGlyphMetrics

            func measure(
                _ text: LuaString,
                using font: GMLuaFontDescriptor
            ) -> GMLuaTextMeasurement {
                switch text.utf8String {
                case "武器": return GMLuaTextMeasurement(width: 40, height: 18)
                case "#spawnmenu.category.weapons":
                    return GMLuaTextMeasurement(width: 999, height: 99)
                default:
                    return GMLuaTextMeasurement(
                        width: text.bytes.count * 7,
                        height: 13
                    )
                }
            }
        }

        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            textMeasurer: PhraseProbeMeasurer(),
            languageConfiguration: GMLuaLanguageConfiguration(phrases: [
                "spawnmenu.category.weapons": "武器"
            ])
        )
        let registry = try XCTUnwrap(runtime.vguiRegistry)
        let surface = try XCTUnwrap(runtime.surfaceCommandState)

        try runtime.execute(
            """
            PHRASE_LABEL = assert(vgui.Create("Label"))
            PHRASE_LABEL:SetText("#spawnmenu.category.weapons")
            assert(PHRASE_LABEL:GetText() == "#spawnmenu.category.weapons")
            local width, height = PHRASE_LABEL:GetTextSize()
            assert(width == 40 and height == 18)
            PHRASE_LABEL:SizeToContents()
            assert(PHRASE_LABEL:GetWide() == 40 and PHRASE_LABEL:GetTall() == 18)

            UNKNOWN_LABEL = assert(vgui.Create("Label"))
            UNKNOWN_LABEL:SetPos(0, 30)
            UNKNOWN_LABEL:SetText("#unknown.phrase")
            assert(UNKNOWN_LABEL:GetText() == "#unknown.phrase")
            """,
            sourceName: "@GMLuaLocalizedLabelTextRegression.lua"
        )

        let frame = try registry.renderFrame(
            surface: surface,
            viewportWidth: 320,
            viewportHeight: 180
        )
        let renderedTexts = frame.commands.compactMap { command -> LuaString? in
            guard case let .text(value, _, _, _, _) = command else { return nil }
            return value
        }
        XCTAssertTrue(renderedTexts.contains(LuaString("武器")))
        XCTAssertTrue(renderedTexts.contains(LuaString("#unknown.phrase")))
        XCTAssertFalse(renderedTexts.contains(LuaString("#spawnmenu.category.weapons")))
    }

    func testRuntimeExposesLanguageOnlyToClientAndMenu() throws {
        for realm in [GMLuaRealm.client, .menu] {
            let runtime = GMLuaRuntime(realm: realm, logger: { _ in })
            XCTAssertNotNil(runtime.languageRegistry)
            try runtime.execute(
                "assert(type(language) == 'table'); " +
                    "assert(type(language.GetPhrase) == 'function'); " +
                    "assert(type(language.Add) == 'function')"
            )
        }

        let server = GMLuaRuntime(realm: .server, logger: { _ in })
        XCTAssertNil(server.languageRegistry)
        try server.execute("assert(language == nil)")
    }

    func testConfiguredAndAddedPhrasesResolveBothBundledLuaKeyForms() throws {
        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            languageConfiguration: GMLuaLanguageConfiguration(phrases: [
                "menubar.npcs.weapon": "NPC Weapon",
                "host.only": "Host value"
            ])
        )

        try runtime.execute(
            "assert(language.GetPhrase('menubar.npcs.weapon') == 'NPC Weapon'); " +
                "assert(language.GetPhrase('#menubar.npcs.weapon') == 'NPC Weapon'); " +
                "assert(language.GetPhrase('garryspad.unknown') == 'garryspad.unknown'); " +
                "assert(language.GetPhrase('#garryspad.unknown') == '#garryspad.unknown'); " +
                "assert(language.GetPhrase('') == ''); " +
                "assert(language.Add('addon.phrase', 'Addon value') == nil); " +
                "assert(language.GetPhrase('addon.phrase') == 'Addon value'); " +
                "assert(language.GetPhrase('#addon.phrase') == 'Addon value')"
        )

        let registry = try XCTUnwrap(runtime.languageRegistry)
        registry.replaceHostPhrases(GMLuaLanguageConfiguration(phrases: [
            "host.only": "Updated host value"
        ]))
        try runtime.execute(
            "assert(language.GetPhrase('menubar.npcs.weapon') == 'menubar.npcs.weapon'); " +
                "assert(language.GetPhrase('host.only') == 'Updated host value'); " +
                "assert(language.GetPhrase('addon.phrase') == 'Addon value')"
        )

        registry.clearHostPhrases()
        try runtime.execute(
            "assert(language.GetPhrase('host.only') == 'host.only'); " +
                "assert(language.GetPhrase('addon.phrase') == 'Addon value')"
        )
    }

    func testGetPhraseCapsEveryReturnAtDocumentedByteLimit() throws {
        let longTranslation = String(repeating: "x", count: 4_100)
        let longUnknown = String(repeating: "y", count: 4_100)
        let runtime = GMLuaRuntime(
            realm: .menu,
            logger: { _ in },
            languageConfiguration: GMLuaLanguageConfiguration(phrases: [
                "long.phrase": longTranslation
            ])
        )

        let values = try runtime.executeReturningValues(
            "local translated = language.GetPhrase('long.phrase'); " +
                "local unknown = language.GetPhrase('" + longUnknown + "'); " +
                "return #translated, translated, #unknown, unknown"
        )
        XCTAssertEqual(values[0].printable, "4000")
        XCTAssertEqual(values[1].printable, String(repeating: "x", count: 4_000))
        XCTAssertEqual(values[2].printable, "4000")
        XCTAssertEqual(values[3].printable, String(repeating: "y", count: 4_000))
    }

    func testDocumentedStringArgumentsAreEnforcedWithoutInventedCoercions() throws {
        let runtime = GMLuaRuntime(realm: .client, logger: { _ in })
        try runtime.execute(
            "local getOK = pcall(language.GetPhrase, nil); " +
                "local addKeyOK = pcall(language.Add, nil, 'value'); " +
                "local addValueOK = pcall(language.Add, 'key', nil); " +
                "assert(not getOK and not addKeyOK and not addValueOK)"
        )
    }
}
