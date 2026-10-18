import XCTest
@testable import GModApp

final class GModMenuWebContractTests: XCTestCase {
    func testExternalURLAllowsOnlyExplicitBrowserSchemesAndNoCredentials() {
        XCTAssertEqual(GModHomeMenuCommandParser.externalURL(in:
            "gui.OpenURL( 'https://github.com/solsticegamestudios/GModPatchTool' )")?.host, "github.com")
        XCTAssertEqual(GModHomeMenuCommandParser.externalURL(in:
            "gui.OpenURL('http://gmod.facepunch.com/changes/')")?.scheme, "http")
        for command in [
            "gui.OpenURL('file:///private/data')", "gui.OpenURL('javascript:alert(1)')",
            "gui.OpenURL('garryspad://launch')", "gui.OpenURL('//example.com')",
            "gui.OpenURL('https://user:pass@example.com')", "gui.OpenURL('https://')",
            "gui.OpenURL('https://example.com', 'extra')",
            "print(\"gui.OpenURL('https://example.com')\")",
            "-- gui.OpenURL('https://example.com')",
            "gui.OpenURL('https://example.com\\nheader')"
        ] { XCTAssertNil(GModHomeMenuCommandParser.externalURL(in: command), command) }
    }

    func testZoomContractForcesViewportAndDisablesOnlyZoomGestures() {
        let script = GModMenuWebContract.zoomLockScript

        XCTAssertTrue(script.contains("width=device-width"))
        XCTAssertTrue(script.contains("initial-scale=1.0"))
        XCTAssertTrue(script.contains("minimum-scale=1.0"))
        XCTAssertTrue(script.contains("maximum-scale=1.0"))
        XCTAssertTrue(script.contains("user-scalable=no"))
        XCTAssertTrue(script.contains("MutationObserver"))
        XCTAssertTrue(script.contains("touch-action:pan-x pan-y"))
        XCTAssertTrue(script.contains("'dblclick'"))
        XCTAssertTrue(script.contains("'gesturestart'"))
        XCTAssertFalse(script.contains("touchstart"))
        XCTAssertFalse(script.contains("touchmove"))
    }

    func testLanguageFacadeContainsOnlySuppliedPackPhrases() {
        let script = GModMenuWebContract.languageFacadeScript(
            snapshot: GModMenuLanguageSnapshot(
                code: "ja",
                phrases: ["new_game": "パック由来"]
            ),
            availableLanguageCodes: ["en", "ja"]
        )

        XCTAssertTrue(script.contains("パック由来"))
        XCTAssertTrue(script.contains("en.png"))
        XCTAssertTrue(script.contains("ja.png"))
        XCTAssertTrue(script.contains("window.language.Update"))
        XCTAssertFalse(script.contains("Start New Game"))
        XCTAssertFalse(script.contains("Back to Main Menu"))
    }

    func testHTMLAudioContractInterceptsWAVAndMP3Playback() {
        let script = GModMenuWebContract.htmlAudioBridgeScript
        XCTAssertTrue(script.contains("HTMLMediaElement.prototype.play"))
        XCTAssertTrue(script.contains("action:'htmlSound'"))
        XCTAssertTrue(script.contains("wav|mp3"))
        XCTAssertTrue(script.contains("new URL(value,document.baseURI)"))
        XCTAssertTrue(script.contains("base:String(document.baseURI"))
    }

    func testProblemStatusContractUpdatesTheStockHomeBadgeTruthfully() {
        let script = GModMenuWebContract.problemStatusScript(
            count: 7,
            severity: 2
        )

        XCTAssertTrue(script.contains("__garrysPadProblemStatus"))
        XCTAssertTrue(script.contains("count:7"))
        XCTAssertTrue(script.contains("severity:2"))
        XCTAssertTrue(script.contains("window.SetProblemCount"))
        XCTAssertTrue(script.contains("window.__garrysPadProblemStatus.count"))
        XCTAssertFalse(script.contains("SetProblemCount(0"))
    }

    func testStockMenuCommandsAreParsedWithoutSubstringMapHeuristics() {
        XCTAssertEqual(
            GModHomeMenuCommandParser.parse("RunGameUICommand(\"OpenOptionsDialog\")"),
            .openOptions
        )
        XCTAssertEqual(
            GModHomeMenuCommandParser.parse("RunGameUICommand('Disconnect')"),
            .disconnect
        )
        XCTAssertNil(GModHomeMenuCommandParser.parse("print('RunGameUICommand(\"OpenOptionsDialog\")')"))
        XCTAssertNil(GModHomeMenuCommandParser.parse("RunGameUICommand('unknown')"))
        XCTAssertEqual(
            GModHomeMenuCommandParser.parse(
                "RunConsoleCommand(\"map\", \"gm_construct\")"
            ),
            .startMap("gm_construct")
        )
        XCTAssertEqual(
            GModHomeMenuCommandParser.parse(
                "RunConsoleCommand('gmod_language', 'ja')"
            ),
            .setLanguage("ja")
        )
        XCTAssertEqual(
            GModHomeMenuCommandParser.parse("gui.HideGameUI()"),
            .hideGameUI
        )
        XCTAssertEqual(
            GModHomeMenuCommandParser.parse(
                "RunConsoleCommand('gamemenucommand', 'OpenOptionsDialog')"
            ),
            .openOptions
        )
        XCTAssertEqual(
            GModHomeMenuCommandParser.parse("OpenProblemsPanel()"),
            .openProblems
        )
        XCTAssertEqual(
            GModHomeMenuCommandParser.parse("gui.ShowConsole()"),
            .openConsole
        )
        XCTAssertEqual(
            GModHomeMenuCommandParser.parse("RunConsoleCommand('disconnect')"),
            .disconnect
        )
        XCTAssertEqual(
            GModHomeMenuCommandParser.parse("RunConsoleCommand('quit')"),
            .quit
        )
        XCTAssertEqual(
            GModHomeMenuCommandParser.parse("RunConsoleCommand('exit')"),
            .quit
        )
        XCTAssertNil(GModHomeMenuCommandParser.parse(
            "print('RunConsoleCommand map gm_construct')"
        ))
        XCTAssertNil(GModHomeMenuCommandParser.parse(
            "print('RunConsoleCommand(\\\"quit\\\")')"
        ))
        XCTAssertNil(GModHomeMenuCommandParser.parse(
            "print('OpenProblemsPanel()')"
        ))
        XCTAssertNil(GModHomeMenuCommandParser.parse(
            "print('gui.HideGameUI() gui.ShowConsole()')"
        ))
    }
}
