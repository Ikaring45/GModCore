import Foundation
import XCTest
import GModEngine
import GModLua

final class GMLuaSpawnMenuEngineTests: XCTestCase {
    func testPopulateFromTextFilesDecodesStockKeyValuesCallbackABI() throws {
        let fixture = #"""
        "TableToKeyValues"
        {
            "parentid" "16"
            "icon" "icon16/page.png"
            "id" "19"
            "contents"
            {
                "1" { "type" "header" "text" "Combine Props" }
                "2" { "type" "model" "model" "models/props_combine/combinebutton.mdl" }
            }
            "name" "Combine"
            "needsapp" "hl2"
            "version" "3"
        }
        """#
        let fileSystem = try LuaMemoryFileSystem(initialFiles: [
            "settings/spawnlist/019-combine.txt": Data(fixture.utf8)
        ])
        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            virtualFileSystem: fileSystem
        )

        try runtime.execute(
            """
            local native = assert(spawnmenu)
            local calls = 0
            native.PopulateFromTextFiles(function(filename, name, contents, icon, id, parentid, needsapp)
                calls = calls + 1
                assert(filename == "019-combine.txt")
                assert(name == "Combine")
                assert(icon == "icon16/page.png")
                assert(id == 19 and parentid == 16 and needsapp == "hl2")
                assert(#contents == 2)
                assert(contents[1].type == "header" and contents[1].text == "Combine Props")
                assert(contents[2].type == "model")
                assert(contents[2].model == "models/props_combine/combinebutton.mdl")
            end)
            assert(calls == 1)

            local ok, message = pcall(native.SaveToTextFiles, {})
            assert(not ok)
            assert(string.find(message, "no atomic writable spawnlist store", 1, true))
            """,
            sourceName: "@GMLuaStockSpawnMenuNativeABIRegression.lua"
        )
    }

    func testPopulateFromTextFilesTreatsMissingSpawnlistDirectoryAsEmpty() throws {
        let runtime = GMLuaRuntime(realm: .client, logger: { _ in })
        try runtime.execute(
            """
            local calls = 0
            spawnmenu.PopulateFromTextFiles(function() calls = calls + 1 end)
            assert(calls == 0)
            assert(not pcall(spawnmenu.PopulateFromTextFiles, nil))
            """,
            sourceName: "@GMLuaEmptySpawnMenuNativeABIRegression.lua"
        )
    }
}
