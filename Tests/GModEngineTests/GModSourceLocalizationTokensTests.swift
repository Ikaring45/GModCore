import Foundation
import XCTest
import GModEngine
import GModGameAssets
import GModLua
@testable import GModGameSession

final class GModSourceLocalizationTokensTests: XCTestCase {
    func testUTF8AndUTF16TokensPreserveAuthoredValuesAndCase() throws {
        let text = #"""
        "lang" { "Language" "Japanese" "Tokens" {
            "weapon_frag" "手榴弾"
            "GameUI_Cancel" "キャンセル"
            "escaped" "Say \"hello\""
            "conditional" "unselected" [$WIN32]
        } }
        """#
        let dataValues = [Data(text.utf8), Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!,
            Data([0xFE, 0xFF]) + text.data(using: .utf16BigEndian)!]
        for data in dataValues {
            let tokens = try GModSourceLocalizationTokens.parse(data: data)
            XCTAssertEqual(tokens["weapon_frag"], "手榴弾")
            XCTAssertEqual(tokens["GameUI_Cancel"], "キャンセル")
            XCTAssertEqual(tokens["escaped"], "Say \"hello\"")
            XCTAssertNil(tokens["conditional"])
            XCTAssertNil(tokens["GameUI_Canncel"])
        }
    }

    func testMalformedCatalogCannotBecomePhrases() {
        for data in [Data("\"Tokens\" { \"key\" \"value\" }".utf8),
                     Data("\"lang\" { \"Tokens\" { \"key\" { \"nested\" \"value\" } } }".utf8),
                     Data([0xFF, 0xFE, 0x00]), Data([0xFF])] {
            XCTAssertThrowsError(try GModSourceLocalizationTokens.parse(data: data))
        }
    }

    func testOwnedContentNativeWeaponAndGameUITokens() throws {
        guard let path = ProcessInfo.processInfo.environment["GMOD_CONTENT_PACK_DIAGNOSTIC_PATH"] else {
            throw XCTSkip("owned content ZIP not supplied")
        }
        let pack = try GarrysPADContentPack(url: URL(fileURLWithPath: path))
        let source = try GModContentPackAssetSource(pack: pack)
        var diagnostics: [String] = []
        let english = GModSourceLocalizationTokens.load(languageCode: "en", source: source, diagnostic: { diagnostics.append($0) })
        let japanese = GModSourceLocalizationTokens.load(languageCode: "ja", source: source, diagnostic: { diagnostics.append($0) })
        XCTAssertTrue(diagnostics.isEmpty, diagnostics.joined(separator: "\n"))
        XCTAssertNotNil(english["weapon_frag"])
        XCTAssertNotNil(english["GameUI_Cancel"])
        XCTAssertFalse(japanese.isEmpty)
        XCTAssertEqual(english["weapon_frag"], "Frag Grenade")
        XCTAssertEqual(japanese["weapon_frag"], "手榴弾")
        XCTAssertEqual(japanese["GameUI_Cancel"], "キャンセル")
        let runtime = GMLuaRuntime(realm: .client, logger: { _ in },
            languageConfiguration: .init(phrases: japanese))
        try runtime.execute("""
            assert(language.GetPhrase("#weapon_frag") == "手榴弾")
            assert(language.GetPhrase("#GameUI_Cancel") == "キャンセル")
            GRENADE_LABEL = assert(vgui.Create("Label"))
            GRENADE_LABEL:SetText("#weapon_frag")
            GRENADE_LABEL:SizeToContents()
            CANCEL_LABEL = assert(vgui.Create("Label"))
            CANCEL_LABEL:SetPos(0, 40)
            CANCEL_LABEL:SetText("#GameUI_Cancel")
            CANCEL_LABEL:SizeToContents()
            """, sourceName: "@OwnedWeaponAndCancelLocalization.lua")
        let frame = try XCTUnwrap(runtime.vguiRegistry).renderFrame(
            surface: try XCTUnwrap(runtime.surfaceCommandState), viewportWidth: 640, viewportHeight: 480)
        let drawn = frame.commands.compactMap { command -> String? in
            guard case let .text(text, _, _, _, _) = command else { return nil }
            return text.utf8String
        }
        XCTAssertTrue(drawn.contains("手榴弾"))
        XCTAssertTrue(drawn.contains("キャンセル"))
        XCTAssertFalse(drawn.contains("#weapon_frag"))
        XCTAssertFalse(drawn.contains("#GameUI_Cancel"))
        print("Owned Source localization: en=\(english.count) ja=\(japanese.count) frag=\(english["weapon_frag"] ?? "MISSING") cancel=\(japanese["GameUI_Cancel"] ?? "MISSING")")
    }
}
