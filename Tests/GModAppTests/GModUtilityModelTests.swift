import Foundation
import XCTest
import GModMetal
@testable import GModApp

final class GModUtilityModelTests: XCTestCase {
    @MainActor
    func testTouchLookAndFrameRatePreferencesClampPersistAndApplyPurely() {
        let suite = "GModInputVideoSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = GModInputVideoSettingsStore(defaults: defaults)
        XCTAssertEqual(settings.touchLookSensitivity, 0.34, accuracy: 0.0001)
        XCTAssertFalse(settings.invertTouchLookY)
        XCTAssertEqual(settings.preferredFramesPerSecond, 60)

        settings.setTouchLookSensitivity(-100)
        XCTAssertEqual(settings.touchLookSensitivity, 0.05, accuracy: 0.0001)
        settings.setTouchLookSensitivity(100)
        XCTAssertEqual(settings.touchLookSensitivity, 1.50, accuracy: 0.0001)
        settings.setInvertTouchLookY(true)
        settings.setPreferredFramesPerSecond(61)
        XCTAssertEqual(settings.preferredFramesPerSecond, 120)
        settings.setPreferredFramesPerSecond(1)
        XCTAssertEqual(settings.preferredFramesPerSecond, 60)

        let restored = GModInputVideoSettingsStore(defaults: defaults)
        XCTAssertEqual(restored.touchLookSensitivity, 1.50, accuracy: 0.0001)
        XCTAssertTrue(restored.invertTouchLookY)
        XCTAssertEqual(restored.preferredFramesPerSecond, 60)

        let normal = GModTouchLookPolicy.adjustedAngles(
            current: .zero,
            deltaX: 10,
            deltaY: 4,
            sensitivity: 0.5,
            invertY: false
        )
        let inverted = GModTouchLookPolicy.adjustedAngles(
            current: .zero,
            deltaX: 10,
            deltaY: 4,
            sensitivity: 0.5,
            invertY: true
        )
        XCTAssertEqual(normal.yaw, 5, accuracy: 0.0001)
        XCTAssertEqual(normal.pitch, 2, accuracy: 0.0001)
        XCTAssertEqual(inverted.yaw, 5, accuracy: 0.0001)
        XCTAssertEqual(inverted.pitch, -2, accuracy: 0.0001)
    }

    @MainActor
    func testContentHostSettingsAreRealPersistentPreferences() {
        let suite = "GModUtilityModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let initial = GModContentSettingsStore(defaults: defaults)
        XCTAssertTrue(initial.automaticallyReloadsLastPack)
        XCTAssertTrue(initial.menuBackgroundsEnabled)
        initial.setAutomaticallyReloadsLastPack(false)
        initial.setMenuBackgroundsEnabled(false)

        let restored = GModContentSettingsStore(defaults: defaults)
        XCTAssertFalse(restored.automaticallyReloadsLastPack)
        XCTAssertFalse(restored.menuBackgroundsEnabled)
    }

    func testProblemSnapshotSeparatesVGUIMissingLuaErrorsAndCapabilities() {
        let snapshot = GModAppProblemSnapshotBuilder.build(
            retained: [],
            gameLogs: [
                "[VGUI][MISSING] class=DCheckBox method=SizeToContents " +
                    "source=lua/vgui/dcheckbox.lua:129",
                "[CLIENT] lua/vgui/dtree_node.lua:285: attempt to call method " +
                    "'SetVisible' (a nil value)\n1. Think - addons/demo/lua/test.lua:9",
                "[RENDERER] fallback material for maps/test/wall",
            ],
            consoleLogs: [],
            worldScene: nil,
            surfaceDiagnostics: nil,
            contentError: "candidate ZIP failed validation"
        )

        XCTAssertTrue(snapshot.problems.contains { $0.kind == .vguiMissing })
        XCTAssertTrue(snapshot.problems.contains { $0.kind == .luaError })
        XCTAssertTrue(snapshot.problems.contains { $0.kind == .contentPack })
        XCTAssertTrue(snapshot.problems.contains { $0.kind == .rendererFallback })
        XCTAssertFalse(snapshot.problems.contains {
            $0.id == "permissions-menu-transport-unavailable"
        })
        XCTAssertEqual(snapshot.luaErrors.count, 1)
        XCTAssertEqual(snapshot.luaErrors[0].realm, "CLIENT")
        XCTAssertEqual(snapshot.luaErrors[0].source, "lua/vgui/dtree_node.lua")
        XCTAssertEqual(snapshot.luaErrors[0].line, 285)
        XCTAssertEqual(
            snapshot.luaErrors[0].traceback,
            "1. Think - addons/demo/lua/test.lua:9"
        )
        XCTAssertTrue(snapshot.permissions.isEmpty)
    }

    func testProblemSnapshotReportsOnlyCapacityExceededLightmapFallback() throws {
        let capacityScene = makeWorldScene(lightmapStatus: .capacityExceeded(
            requiredWidth: 2_048,
            requiredHeight: 4_100,
            requiredByteCount: 67_174_400,
            maximumWidth: 2_048,
            maximumHeight: 4_096,
            maximumByteCount: 67_108_864
        ))
        let snapshot = GModAppProblemSnapshotBuilder.build(
            retained: [],
            gameLogs: [],
            consoleLogs: [],
            worldScene: capacityScene,
            surfaceDiagnostics: nil,
            contentError: nil
        )
        let problem = try XCTUnwrap(snapshot.problems.first {
            $0.id.hasPrefix("world-lightmap-capacity|")
        })
        XCTAssertEqual(problem.kind, .rendererFallback)
        XCTAssertEqual(problem.severity, .warning)
        XCTAssertEqual(
            problem.localizationArguments,
            [
                "requiredWidth": "2048",
                "requiredHeight": "4100",
                "requiredByteCount": "67174400",
                "maximumWidth": "2048",
                "maximumHeight": "4096",
                "maximumByteCount": "67108864",
            ]
        )

        let catalogs = GModBundledAppLocalization.load()
        let english = GModMenuLanguageSnapshot(
            code: "en",
            phrases: try XCTUnwrap(catalogs["en"])
        )
        let japanese = GModMenuLanguageSnapshot(
            code: "ja",
            phrases: try XCTUnwrap(catalogs["ja"])
        )
        XCTAssertEqual(
            problem.localizedDetail(using: english),
            "Lightmap atlas requires 2048x4100 / 67174400 bytes; " +
                "renderer limit is 2048x4096 / 67108864 bytes."
        )
        XCTAssertEqual(
            problem.localizedDetail(using: japanese),
            "ライトマップアトラスには2048x4100 / 67174400バイトが必要ですが、" +
                "レンダラー上限は2048x4096 / 67108864バイトです。"
        )

        for status in [
            GModMetalWorldLightmapAtlasStatus.unavailableNoLightmaps,
            .built(width: 2_048, height: 128, byteCount: 2_097_152),
        ] {
            let nonFallback = GModAppProblemSnapshotBuilder.build(
                retained: [],
                gameLogs: [],
                consoleLogs: [],
                worldScene: makeWorldScene(lightmapStatus: status),
                surfaceDiagnostics: nil,
                contentError: nil
            )
            XCTAssertFalse(nonFallback.problems.contains {
                $0.id.hasPrefix("world-lightmap-capacity|")
            })
        }
    }

    func testProblemSnapshotKeepsTypedMaterialAndRendererFailures() {
        let scene = GModMetalWorldScene(
            meshIdentifier: "session-11:gm_construct",
            sourcePositions: [],
            sourceNormals: [],
            indices: [],
            materialRanges: [
                GModMetalWorldMaterialRange(
                    materialName: "missing/wall",
                    firstIndex: 0,
                    indexCount: 0,
                    materialResolution: .sourceMissing
                ),
                GModMetalWorldMaterialRange(
                    materialName: "broken/wall",
                    firstIndex: 0,
                    indexCount: 0,
                    materialResolution: .decodeFailed("bad VTF")
                ),
                GModMetalWorldMaterialRange(
                    materialName: "large/wall",
                    firstIndex: 0,
                    indexCount: 0,
                    materialResolution: .retentionCapacityExceeded(
                        requiredByteCount: 4_096,
                        retainedByteCount: 134_217_728,
                        maximumByteCount: 134_217_728
                    )
                ),
            ],
            cameraEye: .zero,
            cameraForward: SIMD3<Float>(1, 0, 0)
        )
        let rendererFailure = GModMetalWorldRendererFailure(
            meshIdentifier: scene.meshIdentifier,
            reason: .sceneRejected("invalid index 7")
        )
        let snapshot = GModAppProblemSnapshotBuilder.build(
            retained: [],
            gameLogs: [],
            consoleLogs: [],
            worldScene: scene,
            surfaceDiagnostics: nil,
            contentError: nil,
            rendererFailure: rendererFailure
        )

        XCTAssertTrue(snapshot.problems.contains {
            $0.kind == .missingMaterial && $0.detail == "missing/wall"
        })
        XCTAssertTrue(snapshot.problems.contains {
            $0.kind == .missingTexture && $0.detail == "broken/wall: bad VTF"
        })
        XCTAssertTrue(snapshot.problems.contains {
            $0.id.hasPrefix("world-material-retention-capacity|") &&
                $0.detail.contains("4096 bytes") &&
                $0.detail.contains("134217728 cap")
        })
        XCTAssertTrue(snapshot.problems.contains {
            $0.id.hasPrefix("renderer-failure|") &&
                $0.detail == "Metal world scene rejected: invalid index 7"
        })
    }

    private func makeWorldScene(
        lightmapStatus: GModMetalWorldLightmapAtlasStatus
    ) -> GModMetalWorldScene {
        GModMetalWorldScene(
            meshIdentifier: "diagnostic-lightmap-scene",
            sourcePositions: [],
            sourceNormals: [],
            indices: [],
            lightmapDiagnostics: GModMetalWorldLightmapDiagnostics(
                atlasStatus: lightmapStatus
            ),
            cameraEye: .zero,
            cameraForward: SIMD3<Float>(1, 0, 0)
        )
    }
}
