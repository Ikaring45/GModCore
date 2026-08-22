import Foundation
import GModEngine
import GModGameAssets
import GModLua
import XCTest

final class GMLuaScriptedWeaponSelectionMetadataTests: XCTestCase {
    func testReadsExactFieldsFromInheritedWeaponsGetResult() throws {
        let runtime = GMLuaRuntime(realm: .client, logger: { _ in })
        defer { _ = runtime.close() }
        try runtime.execute(
            """
            weapons = {}
            local inherited = {
                Slot = 5,
                SlotPos = 6,
                PrintName = "#gmod_tool"
            }
            function weapons.Get(name)
                assert(name == "gmod_tool")
                return inherited
            end
            """
        )

        XCTAssertEqual(
            try runtime.scriptedWeaponSelectionMetadata(className: "gmod_tool"),
            GMLuaScriptedWeaponSelectionMetadata(
                className: "gmod_tool",
                slot: 5,
                slotPosition: 6,
                printName: "#gmod_tool"
            )
        )
    }

    func testMissingAndMalformedFieldsFailClosedWithTypedErrors() throws {
        let runtime = GMLuaRuntime(realm: .client, logger: { _ in })
        defer { _ = runtime.close() }
        try runtime.execute(
            """
            weapons = {}
            function weapons.Get(name)
                if name == "missing_name" then
                    return { Slot = 0, SlotPos = 10 }
                elseif name == "string_slot" then
                    return { Slot = "5", SlotPos = 1, PrintName = "Wrong" }
                elseif name == "fractional_position" then
                    return { Slot = 5, SlotPos = 1.5, PrintName = "Wrong" }
                end
            end
            """
        )

        XCTAssertThrowsError(
            try runtime.scriptedWeaponSelectionMetadata(className: "missing_name")
        ) { error in
            XCTAssertEqual(
                error as? GMLuaScriptedWeaponSelectionMetadataError,
                .missingField(className: "missing_name", field: "PrintName")
            )
        }
        XCTAssertThrowsError(
            try runtime.scriptedWeaponSelectionMetadata(className: "string_slot")
        ) { error in
            XCTAssertEqual(
                error as? GMLuaScriptedWeaponSelectionMetadataError,
                .invalidFieldType(
                    className: "string_slot",
                    field: "Slot",
                    actualType: "string"
                )
            )
        }
        XCTAssertThrowsError(
            try runtime.scriptedWeaponSelectionMetadata(
                className: "fractional_position"
            )
        ) { error in
            XCTAssertEqual(
                error as? GMLuaScriptedWeaponSelectionMetadataError,
                .invalidIntegerField(
                    className: "fractional_position",
                    field: "SlotPos",
                    value: 1.5
                )
            )
        }
    }

    func testBundledOriginalLuaProvidesBaseToolAndCameraValues() throws {
        let installed = try GMLuaHostDirectoryFileSystem(
            rootURL: GModGameAssets.clientContentRootURL(),
            writable: false
        )
        let mounted = GMLuaMountedFileSystem(mounts: [
            try GMLuaFileMount(
                name: "bundled-original-client-content",
                priority: 0,
                writable: false,
                fileSystem: installed
            ),
        ])
        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            virtualFileSystem: mounted,
            bootstrapMode: .strict,
            gameEnvironmentConfiguration: try GMLuaGameEnvironmentConfiguration(
                maxPlayers: 32,
                mapName: "gm_construct",
                sessionKind: .listenServer,
                hostName: "SWEP selection metadata test"
            ),
            engineConfiguration: GMLuaEngineConfiguration(
                games: [],
                isPlayingDemo: false,
                isRecordingDemo: false
            ),
            engineConVarCatalog: try GMLuaEngineConVarCatalog(descriptors: [
                GMLuaEngineConVarDescriptor(
                    name: "gmod_language",
                    defaultValue: "en"
                ),
            ])
        )
        defer { _ = runtime.close() }

        try runtime.loadFile("lua/includes/init.lua")
        let report = try GMLuaScriptedWeaponLoader(
            runtime: runtime,
            fileSystem: mounted
        ).load(targetGamemodeNamed: "sandbox")
        XCTAssertTrue(report.classes.contains { $0.className == "weapon_base" })
        XCTAssertTrue(report.classes.contains { $0.className == "gmod_tool" })
        XCTAssertTrue(report.classes.contains { $0.className == "gmod_camera" })

        XCTAssertEqual(
            try runtime.scriptedWeaponSelectionMetadata(className: "weapon_base"),
            GMLuaScriptedWeaponSelectionMetadata(
                className: "weapon_base",
                slot: 0,
                slotPosition: 10,
                printName: "Scripted Weapon"
            )
        )
        XCTAssertEqual(
            try runtime.scriptedWeaponSelectionMetadata(className: "gmod_tool"),
            GMLuaScriptedWeaponSelectionMetadata(
                className: "gmod_tool",
                slot: 5,
                slotPosition: 6,
                printName: "#gmod_tool"
            )
        )
        XCTAssertEqual(
            try runtime.scriptedWeaponSelectionMetadata(className: "gmod_camera"),
            GMLuaScriptedWeaponSelectionMetadata(
                className: "gmod_camera",
                slot: 5,
                slotPosition: 1,
                printName: "#gmod_camera"
            )
        )
    }
}
