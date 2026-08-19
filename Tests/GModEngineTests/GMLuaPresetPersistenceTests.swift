import Foundation
import XCTest
import GModEngine
import GModLua

final class GMLuaPresetPersistenceTests: XCTestCase {
    func testLoadsDesktopPerFileKeyValuesInNumericOrder() throws {
        let fileSystem = try LuaMemoryFileSystem(initialFiles: [
            "Settings/Presets/Bloom/1-warm.txt": preset(
                "Warm",
                ["Amount": "1.25", "Label": "café"]
            ),
            "Settings/Presets/Bloom/2-earlier.txt": preset(
                "Duplicate",
                ["value": "earlier"]
            ),
            "Settings/Presets/Bloom/10-later.TXT": preset(
                "Duplicate",
                ["value": "later"]
            ),
            "Settings/Presets/Bloom/readme.md": Data("ignored".utf8),
        ])
        let state = LuaState(output: { _ in }, virtualFileSystem: fileSystem)
        let store = GMLuaPresets.install(into: state, fileSystem: fileSystem)

        try state.execute(
            """
            local loaded = LoadPresets()
            assert(loaded.Bloom.Warm.Amount == "1.25")
            assert(loaded.Bloom.Warm.Label == "café")
            assert(loaded.Bloom.Duplicate.value == "later")
            assert(loaded.Bloom["readme"] == nil)
            """,
            sourceName: "@DesktopPresetImport.lua"
        )
        XCTAssertTrue(store.hasStoredPresets)
    }

    func testSaveUsesDesktopFilenamesKeyValuesAndReplacesOnlySuppliedGroup() throws {
        let fileSystem = try LuaMemoryFileSystem(initialFiles: [
            "settings/presets/keep/1-existing.txt": preset("Existing", ["x": "yes"]),
            "settings/presets/bloom/1-old.txt": preset("Old", ["x": "old"]),
        ])
        let state = LuaState(output: { _ in }, virtualFileSystem: fileSystem)
        _ = GMLuaPresets.install(into: state, fileSystem: fileSystem)

        try state.execute(
            """
            SavePresets({ bloom = {
                ["Snow"] = { z = "2", a = "1" },
                ["I'm Sunny!"] = { quote = "a\\\"b", enabled = "1", amount = "2.5" },
                ["A!B.C'D@E+F(1),;=[]^~"] = { value = "ascii transform" }
            } })
            local loaded = LoadPresets()
            assert(loaded.bloom["I'm Sunny!"].quote == "a\\\"b")
            assert(loaded.bloom["I'm Sunny!"].enabled == "1")
            assert(loaded.bloom["I'm Sunny!"].amount == "2.5")
            assert(loaded.bloom.Snow.a == "1")
            assert(loaded.bloom.Old == nil)
            assert(loaded.keep.Existing.x == "yes")
            """,
            sourceName: "@DesktopPresetSave.lua"
        )

        let snapshot = fileSystem.snapshot()
        XCTAssertEqual(Set(snapshot.keys), [
            "settings/presets/bloom/1-snow.txt",
            "settings/presets/bloom/2-i_m sunny_.txt",
            "settings/presets/bloom/3-a_b_c_d_e+f(1),;=[]^~.txt",
            "settings/presets/keep/1-existing.txt",
        ])
        XCTAssertEqual(
            String(data: try XCTUnwrap(snapshot["settings/presets/bloom/1-snow.txt"]), encoding: .utf8),
            "\"Snow\"\n{\n\t\"a\"\t\t\"1\"\n\t\"z\"\t\t\"2\"\n}\n"
        )

        // Rename/delete are represented by the complete replacement group
        // passed by the stock presets.lua module.
        try state.execute(
            """
            SavePresets({ bloom = { Renamed = { value = "new" } } })
            local renamed = LoadPresets()
            assert(renamed.bloom.Renamed.value == "new")
            assert(renamed.bloom.Snow == nil and renamed.bloom["I'm Sunny!"] == nil)
            SavePresets({ bloom = {} })
            assert(next(LoadPresets().bloom) == nil)
            """,
            sourceName: "@DesktopPresetReplace.lua"
        )
        XCTAssertEqual(Set(fileSystem.snapshot().keys), [
            "settings/presets/keep/1-existing.txt",
        ])
    }

    func testMountedReadOnlyDefaultsStayDeletedAcrossMountedInstances() throws {
        let lower = try LuaMemoryFileSystem(initialFiles: [
            "settings/presets/bloom/1-default.txt": preset("Default", ["value": "lower"]),
            "settings/presets/bloom/2-other.txt": preset("Other", ["value": "lower"]),
        ])
        let overlay = try LuaMemoryFileSystem()
        let firstMounted = try mounted(overlay: overlay, lower: lower)
        let first = LuaState(output: { _ in }, virtualFileSystem: firstMounted)
        _ = GMLuaPresets.install(into: first, fileSystem: firstMounted)

        try first.execute(
            """
            assert(LoadPresets().bloom.Default.value == "lower")
            SavePresets({ bloom = { Custom = { value = "upper" } } })
            local replaced = LoadPresets().bloom
            assert(replaced.Custom.value == "upper")
            assert(replaced.Default == nil and replaced.Other == nil)
            """,
            sourceName: "@PresetWhiteoutWriter.lua"
        )

        XCTAssertEqual(
            try firstMounted.listDirectory(at: "settings/presets/bloom").map(\.name),
            ["1-custom.txt"]
        )
        XCTAssertFalse(
            try firstMounted.listDirectory(at: "").contains {
                $0.name.lowercased().contains("whiteout")
            }
        )
        XCTAssertTrue(overlay.snapshot().keys.contains {
            $0.contains(".garrys-pad-vfs-whiteouts/v1/settings/presets/bloom/1-default.txt.deleted")
        })

        // Whiteouts live in the overlay itself, not only in the mounted
        // wrapper, so rebuilding runtime/VFS objects cannot resurrect defaults.
        let secondMounted = try mounted(overlay: overlay, lower: lower)
        let second = LuaState(output: { _ in }, virtualFileSystem: secondMounted)
        _ = GMLuaPresets.install(into: second, fileSystem: secondMounted)
        try second.execute(
            """
            local loaded = LoadPresets().bloom
            assert(loaded.Custom.value == "upper")
            assert(loaded.Default == nil and loaded.Other == nil)
            SavePresets({ bloom = { Default = { value = "restored upper" } } })
            assert(LoadPresets().bloom.Default.value == "restored upper")
            """,
            sourceName: "@PresetWhiteoutReader.lua"
        )
        XCTAssertTrue(secondMounted.fileExists(at: "SETTINGS/PRESETS/BLOOM/1-DEFAULT.TXT"))
    }

    func testUnsafeGroupsAndUnsupportedGraphsFailBeforeMutation() throws {
        let fileSystem = try LuaMemoryFileSystem(initialFiles: [
            "settings/presets/safe/1-original.txt": preset("Original", ["value": "kept"]),
        ])
        let state = LuaState(output: { _ in }, virtualFileSystem: fileSystem)
        _ = GMLuaPresets.install(into: state, fileSystem: fileSystem)

        try state.execute(
            """
            local ok, message = pcall(SavePresets, {
                ["../escape"] = { Bad = { value = "no" } }
            })
            assert(not ok and string.find(message, "unsafe preset group", 1, true))

            ok, message = pcall(SavePresets, { safe = { Broken = { value = true } } })
            assert(not ok and string.find(message, "keyvalue value is a boolean", 1, true))
            local cyclic = {}
            cyclic.self = cyclic
            ok, message = pcall(SavePresets, { safe = { Broken = cyclic } })
            assert(not ok and string.find(message, "keyvalue value is a table", 1, true))
            assert(LoadPresets().safe.Original.value == "kept")
            """,
            sourceName: "@PresetSafety.lua"
        )
        XCTAssertEqual(Set(fileSystem.snapshot().keys), [
            "settings/presets/safe/1-original.txt",
        ])
    }

    func testClientAndMenuRuntimePersistDesktopFilesButServerHasNoPresetAPI() throws {
        let overlay = try LuaMemoryFileSystem()
        let mounted = try self.mounted(overlay: overlay, lower: try LuaMemoryFileSystem())
        let client = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            virtualFileSystem: mounted,
            bootstrapMode: .strict
        )
        try client.execute(
            "SavePresets({ shared = { First = { value = 'persisted' } } })",
            sourceName: "@PresetWriter.lua"
        )

        let menu = GMLuaRuntime(
            realm: .menu,
            logger: { _ in },
            virtualFileSystem: mounted,
            bootstrapMode: .strict
        )
        try menu.execute(
            "assert(LoadPresets().shared.First.value == 'persisted')",
            sourceName: "@PresetReader.lua"
        )
        XCTAssertNotNil(overlay.snapshot()["settings/presets/shared/1-first.txt"])

        let server = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            bootstrapMode: .strict
        )
        try server.execute(
            "assert(LoadPresets == nil and SavePresets == nil)",
            sourceName: "@PresetServerAbsence.lua"
        )
        XCTAssertNil(server.presetStore)
    }

    func testInstalledGModDesktopPresetImportWhenAvailable() throws {
        let install = URL(fileURLWithPath:
            "C:/Program Files (x86)/Steam/steamapps/common/GarrysMod/garrysmod"
        )
        guard FileManager.default.fileExists(atPath: install.path) else {
            throw XCTSkip("Garry's Mod desktop install is not available")
        }
        let fileSystem = try GMLuaHostDirectoryFileSystem(rootURL: install, writable: false)
        let state = LuaState(output: { _ in }, virtualFileSystem: fileSystem)
        _ = GMLuaPresets.install(into: state, fileSystem: fileSystem)
        try state.execute(
            "assert(LoadPresets().bloom['Really Sunny'].pp_bloom_color == '3.136000')",
            sourceName: "@InstalledDesktopPresetImport.lua"
        )
    }

    private func mounted(
        overlay: LuaVirtualFileSystem,
        lower: LuaVirtualFileSystem
    ) throws -> GMLuaMountedFileSystem {
        GMLuaMountedFileSystem(mounts: [
            try GMLuaFileMount(
                name: "writable-overlay",
                priority: 100,
                writable: true,
                fileSystem: overlay
            ),
            try GMLuaFileMount(
                name: "read-only-lower",
                priority: 0,
                writable: false,
                fileSystem: lower
            ),
        ])
    }

    private func preset(_ name: String, _ values: [String: String]) -> Data {
        var text = "\"\(name)\"\n{\n"
        for key in values.keys.sorted() {
            text += "\t\"\(key)\"\t\t\"\(values[key]!)\"\n"
        }
        text += "}\n"
        return Data(text.utf8)
    }
}
