import Dispatch
import Foundation
import XCTest
import GModEngine
import GModLua
@testable import GModMetal
#if canImport(GModApp)
@testable import GModApp
#endif

final class GModMetalSurfaceSceneTests: XCTestCase {
    func testDrawCommandBudgetIsBoundedAndReportsDroppedTail() {
        let budget = GModMetalSurfaceDrawCommandBudget(
            maximumCommandCount: 2
        )
        let admission = budget.admission(for: 5)

        XCTAssertEqual(admission.admittedCommandCount, 2)
        XCTAssertEqual(admission.droppedCommandCount, 3)
        let reset = budget.admission(for: 1)
        XCTAssertEqual(reset.admittedCommandCount, 1)
        XCTAssertEqual(reset.droppedCommandCount, 0)
    }

    func testLogicalViewportIsInvariantAcrossOneAndTwoTimesDrawableScale() throws {
        let oneX = try XCTUnwrap(GModMetalViewportDimensions(
            logicalSize: CGSize(width: 810, height: 1_080),
            drawableSize: CGSize(width: 810, height: 1_080)
        ))
        let twoX = try XCTUnwrap(GModMetalViewportDimensions(
            logicalSize: CGSize(width: 810, height: 1_080),
            drawableSize: CGSize(width: 1_620, height: 2_160)
        ))

        XCTAssertEqual(oneX.logicalWidth, twoX.logicalWidth)
        XCTAssertEqual(oneX.logicalHeight, twoX.logicalHeight)
        XCTAssertEqual(twoX.drawableWidth, oneX.drawableWidth * 2)
        XCTAssertEqual(twoX.drawableHeight, oneX.drawableHeight * 2)
        XCTAssertEqual(
            oneX.logicalAspectRatio,
            twoX.logicalAspectRatio,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            oneX.drawableAspectRatio,
            twoX.drawableAspectRatio,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            twoX.logicalAspectRatio,
            twoX.drawableAspectRatio,
            accuracy: 0.000_001
        )
    }

    func testSceneCommandLimitDropsTailWithAggregateOverflowDiagnostics() throws {
        let snapshot = try makeSnapshot()
        let scene = try GModMetalSurfaceScene(
            snapshot: snapshot,
            maximumCommandCount: 1
        )

        XCTAssertEqual(scene.commands.count, 1)
        XCTAssertEqual(scene.diagnostics.snapshotCommandCount, 3)
        XCTAssertEqual(scene.diagnostics.processedSnapshotCommandCount, 1)
        XCTAssertEqual(scene.diagnostics.droppedSnapshotCommandCount, 2)
        XCTAssertEqual(scene.diagnostics.maximumSnapshotCommandCount, 1)
        XCTAssertEqual(
            scene.diagnostics.captureDiagnostics,
            snapshot.captureDiagnostics
        )
        XCTAssertFalse(scene.diagnostics.captureDiagnostics.overflowed)
        XCTAssertTrue(scene.diagnostics.overflowed)
    }

    func testSolidRectangleIsClippedAndUnsupportedResourcesStayDiagnostic() throws {
        let snapshot = try makeSnapshot()
        let scene = try GModMetalSurfaceScene(snapshot: snapshot)

        XCTAssertEqual(scene.commands.count, 1)
        guard case let .solidRectangle(rectangle) = scene.commands[0] else {
            return XCTFail("resolved command was not a solid rectangle")
        }
        XCTAssertEqual(
            rectangle.frame,
            GModMetalSurfaceRect(x: 0, y: 20, width: 40, height: 40)
        )
        XCTAssertEqual(rectangle.color.red, 10 / 255, accuracy: 0.000_01)
        XCTAssertEqual(rectangle.color.alpha, 128 / 255, accuracy: 0.000_01)
        XCTAssertEqual(scene.diagnostics.snapshotCommandCount, 3)
        XCTAssertEqual(scene.diagnostics.solidRectangleCount, 1)
        XCTAssertEqual(scene.diagnostics.clippedCommandCount, 1)
        XCTAssertEqual(
            scene.diagnostics.unresolvedCommands.map(\.kind),
            [.texturedRectangle, .text]
        )
    }

    func testResolvedTextureAndTextRetainOrderAndAdjustUVForClip() throws {
        let snapshot = try makeSnapshot()
        let scene = try GModMetalSurfaceScene(
            snapshot: snapshot,
            textureResolver: FixtureTextureResolver(),
            textRasterizer: FixtureTextRasterizer()
        )

        XCTAssertEqual(scene.commands.count, 3)
        guard case .solidRectangle = scene.commands[0],
              case let .texturedRectangle(texture) = scene.commands[1],
              case let .text(text) = scene.commands[2] else {
            return XCTFail("surface command order was not preserved")
        }
        XCTAssertEqual(
            texture.frame,
            GModMetalSurfaceRect(x: 80, y: 80, width: 20, height: 20)
        )
        XCTAssertEqual(
            texture.uv,
            GModMetalSurfaceRect(x: 0, y: 0, width: 0.5, height: 0.5)
        )
        XCTAssertEqual(texture.bitmap.width, 2)
        XCTAssertEqual(
            text.frame,
            GModMetalSurfaceRect(x: 90, y: 90, width: 10, height: 10)
        )
        XCTAssertEqual(
            text.uv,
            GModMetalSurfaceRect(x: 0, y: 0, width: 0.5, height: 0.5)
        )
        XCTAssertEqual(scene.diagnostics.clippedCommandCount, 3)
        XCTAssertEqual(scene.diagnostics.unresolvedCommands, [])
        XCTAssertEqual(scene.diagnostics.resolvedCommandCount, 3)
    }

    func testTextureFilterSnapshotsReachBoundedMetalSamplerConfigurations() throws {
        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            bootstrapMode: .strict
        )
        try runtime.execute(
            """
            ROOT = vgui.Create("Panel")
            ROOT:SetSize(64, 64)
            function ROOT:Paint(w, h)
                surface.SetDrawColor(255, 255, 255, 255)
                surface.SetTexture(surface.GetTextureID("icon16/brick.png"))
                surface.DrawTexturedRect(0, 0, 16, 16)

                render.PushFilterMag(TEXFILTER.POINT)
                render.PushFilterMin(TEXFILTER.ANISOTROPIC)
                surface.DrawTexturedRect(16, 0, 16, 16)
                render.PopFilterMin()
                render.PopFilterMag()

                render.PushFilterMin(TEXFILTER.NONE)
                surface.DrawTexturedRect(32, 0, 16, 16)
                render.PopFilterMin()
                return true
            end
            """,
            sourceName: "@GModMetalSurfaceFilterPropagationTests.lua"
        )
        let snapshot = try XCTUnwrap(runtime.vguiRegistry).renderFrame(
            surface: try XCTUnwrap(runtime.surfaceCommandState),
            viewportWidth: 64,
            viewportHeight: 64
        )
        let scene = try GModMetalSurfaceScene(
            snapshot: snapshot,
            textureResolver: FixtureTextureResolver()
        )
        let rectangles = scene.commands.compactMap { command ->
            GModMetalSurfaceTexturedRectangle? in
            guard case let .texturedRectangle(rectangle) = command else {
                return nil
            }
            return rectangle
        }
        XCTAssertEqual(rectangles.count, 3)
        XCTAssertNil(rectangles[0].minificationFilter)
        XCTAssertNil(rectangles[0].magnificationFilter)
        XCTAssertEqual(rectangles[1].minificationFilter, .anisotropic)
        XCTAssertEqual(rectangles[1].magnificationFilter, .point)
        XCTAssertEqual(rectangles[2].minificationFilter, .some(.none))
        XCTAssertNil(rectangles[2].magnificationFilter)
        XCTAssertEqual(
            GModMetalSurfaceSamplerConfiguration.defaultMaximumAnisotropy,
            16
        )

        XCTAssertEqual(
            GModMetalSurfaceSamplerConfiguration.source(
                minification: rectangles[0].minificationFilter,
                magnification: rectangles[0].magnificationFilter
            ),
            GModMetalSurfaceSamplerConfiguration(
                minification: .linear,
                magnification: .linear,
                maximumAnisotropy: 1
            )
        )
        XCTAssertEqual(
            GModMetalSurfaceSamplerConfiguration.source(
                minification: rectangles[1].minificationFilter,
                magnification: rectangles[1].magnificationFilter
            ),
            GModMetalSurfaceSamplerConfiguration(
                minification: .linear,
                magnification: .point,
                maximumAnisotropy:
                    GModMetalSurfaceSamplerConfiguration.defaultMaximumAnisotropy
            )
        )
        XCTAssertEqual(
            GModMetalSurfaceSamplerConfiguration.source(
                minification: rectangles[2].minificationFilter,
                magnification: rectangles[2].magnificationFilter
            ),
            GModMetalSurfaceSamplerConfiguration(
                minification: .linear,
                magnification: .linear,
                maximumAnisotropy: 1
            ),
            "TEXFILTER.NONE disables the override rather than becoming point sampling"
        )
        XCTAssertLessThanOrEqual(
            GModMetalSurfaceSamplerConfiguration.allSourceConfigurations.count,
            6
        )
    }

    func testPNGResolverRequiresRealBytesAndPremultipliesStraightAlpha() throws {
        let encoded = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAF0lEQVR42mP4z8DwHwgbGIC0g6CS8X8AOTAGIm/J6C0AAAAASUVORK5CYII="
        ))
        let resolver = GModMetalSurfacePNGResolver(
            maximumCachedEntryCount: 2,
            maximumCachedByteCount: 16
        ) { path in
            path.lowercased() == "materials/icon16/brick.png" ? encoded : nil
        }
        let bitmap = try XCTUnwrap(
            resolver.resolveSurfaceTexture(named: "icon16\\brick.png")
        )

        XCTAssertEqual(bitmap.width, 2)
        XCTAssertEqual(bitmap.height, 2)
        XCTAssertEqual(bitmap.premultipliedRGBA8[0], 255)
        XCTAssertEqual(bitmap.premultipliedRGBA8[4], 0)
        XCTAssertEqual(bitmap.premultipliedRGBA8[5], 128)
        XCTAssertEqual(bitmap.premultipliedRGBA8[7], 128)
        XCTAssertEqual(bitmap.premultipliedRGBA8[10], 64)
        XCTAssertEqual(bitmap.premultipliedRGBA8[11], 64)
        XCTAssertEqual(
            try resolver.resolveSurfaceTexture(
                named: "Materials/ICON16/BRICK.PNG"
            ),
            bitmap,
            "case and slash aliases must share one canonical cache entry"
        )
        XCTAssertEqual(resolver.cachedEntryCount, 1)
        XCTAssertEqual(resolver.cachedTextureCount, 1)
        XCTAssertEqual(resolver.cachedTextureByteCount, 16)
        XCTAssertNil(try resolver.resolveSurfaceTexture(named: "missing"))
        XCTAssertEqual(
            resolver.cachedEntryCount,
            1,
            "syntactically invalid extensionless names must not consume cache"
        )
        XCTAssertNil(try resolver.resolveSurfaceTexture(named: "missing-a.png"))
        XCTAssertNil(try resolver.resolveSurfaceTexture(named: "missing-b.png"))
        XCTAssertEqual(resolver.cachedEntryCount, 2)
        XCTAssertEqual(resolver.cachedTextureCount, 0)
        XCTAssertEqual(resolver.cachedTextureByteCount, 0)
        _ = try XCTUnwrap(
            resolver.resolveSurfaceTexture(named: "icon16/brick.png")
        )
        XCTAssertEqual(resolver.cachedEntryCount, 2)
        XCTAssertEqual(resolver.cachedTextureCount, 1)
        XCTAssertLessThanOrEqual(resolver.cachedTextureByteCount, 16)
        XCTAssertEqual(
            GModMetalSurfacePNGResolver.logicalPNGCandidates(
                for: "Materials/VGUI/Icon.VMT"
            ),
            []
        )
        XCTAssertEqual(
            GModMetalSurfacePNGResolver.logicalPNGCandidates(
                for: "../escape.png"
            ),
            []
        )
    }

    func testPNGResolverRejectsUnsafeHeadersBeforePlatformDecode() throws {
        let encodedBudgetResolver = GModMetalSurfacePNGResolver(
            maximumEncodedPNGByteCount: 32
        ) { _ in
            makePNGHeader(width: 1, height: 1)
        }
        XCTAssertThrowsError(
            try encodedBudgetResolver.resolveSurfaceTexture(named: "large.png")
        ) { error in
            XCTAssertEqual(
                error as? GModMetalSurfacePNGResolverError,
                .encodedByteCountExceeded(actual: 33, maximum: 32)
            )
        }

        var invalidSignature = makePNGHeader(width: 1, height: 1)
        invalidSignature[0] = 0
        let invalidSignatureData = invalidSignature
        let signatureResolver = GModMetalSurfacePNGResolver { _ in
            invalidSignatureData
        }
        XCTAssertThrowsError(
            try signatureResolver.resolveSurfaceTexture(named: "invalid.png")
        ) { error in
            XCTAssertEqual(
                error as? GModMetalSurfacePNGResolverError,
                .invalidPNGSignature
            )
        }

        var invalidIHDR = makePNGHeader(width: 1, height: 1)
        invalidIHDR[11] = 12
        let invalidIHDRData = invalidIHDR
        let ihdrResolver = GModMetalSurfacePNGResolver { _ in
            invalidIHDRData
        }
        XCTAssertThrowsError(
            try ihdrResolver.resolveSurfaceTexture(named: "ihdr.png")
        ) { error in
            XCTAssertEqual(
                error as? GModMetalSurfacePNGResolverError,
                .invalidIHDR
            )
        }

        let widthResolver = GModMetalSurfacePNGResolver(
            maximumPNGWidth: 32
        ) { _ in
            makePNGHeader(width: 33, height: 1)
        }
        XCTAssertThrowsError(
            try widthResolver.resolveSurfaceTexture(named: "wide.png")
        ) { error in
            XCTAssertEqual(
                error as? GModMetalSurfacePNGResolverError,
                .widthExceeded(actual: 33, maximum: 32)
            )
        }
        let diagnosticScene = try GModMetalSurfaceScene(
            snapshot: try makeSnapshot(),
            textureResolver: widthResolver
        )
        XCTAssertTrue(
            diagnosticScene.diagnostics.unresolvedCommands.contains {
                $0.kind == .texturedRectangle &&
                    $0.reason.contains(
                        "PNG IHDR width 33 exceeds maximum 32"
                    )
            }
        )

        let heightResolver = GModMetalSurfacePNGResolver(
            maximumPNGHeight: 32
        ) { _ in
            makePNGHeader(width: 1, height: 33)
        }
        XCTAssertThrowsError(
            try heightResolver.resolveSurfaceTexture(named: "tall.png")
        ) { error in
            XCTAssertEqual(
                error as? GModMetalSurfacePNGResolverError,
                .heightExceeded(actual: 33, maximum: 32)
            )
        }

        let pixelResolver = GModMetalSurfacePNGResolver(
            maximumPNGWidth: 16,
            maximumPNGHeight: 16,
            maximumPNGPixelCount: 80
        ) { _ in
            makePNGHeader(width: 9, height: 9)
        }
        XCTAssertThrowsError(
            try pixelResolver.resolveSurfaceTexture(named: "pixels.png")
        ) { error in
            XCTAssertEqual(
                error as? GModMetalSurfacePNGResolverError,
                .pixelCountExceeded(actual: 81, maximum: 80)
            )
        }

        let decodedBudgetResolver = GModMetalSurfacePNGResolver(
            maximumPNGPixelCount: 16,
            maximumDecodedPNGByteCount: 63
        ) { _ in
            makePNGHeader(width: 4, height: 4)
        }
        XCTAssertThrowsError(
            try decodedBudgetResolver.resolveSurfaceTexture(
                named: "decoded.png"
            )
        ) { error in
            XCTAssertEqual(
                error as? GModMetalSurfacePNGResolverError,
                .decodedByteCountExceeded(actual: 64, maximum: 63)
            )
        }
    }

    func testSourceMaterialResolverFeedsExtensionlessVMTSurfaceCommand() throws {
        let files: [String: Data] = [
            "materials/gui/synthetic_toggle.vmt": Data(
                "\"UnlitGeneric\" { \"$basetexture\" \"gui/synthetic_toggle\" }".utf8
            ),
            "materials/gui/synthetic_toggle.vtf": makeSurfaceRGBA8888VTF(
                width: 2,
                height: 1,
                pixels: [255, 0, 0, 128, 0, 200, 0, 255]
            ),
        ]
        let resolver = GModMetalSurfaceSourceMaterialResolver(
            maximumCachedEntryCount: 2,
            maximumCachedByteCount: 8
        ) { files[$0.lowercased()] }
        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            bootstrapMode: .strict
        )
        try runtime.execute(
            """
            ROOT = vgui.Create("Panel")
            ROOT:SetSize(32, 32)
            function ROOT:Paint(w, h)
                surface.SetDrawColor(255, 255, 255, 255)
                surface.SetTexture(surface.GetTextureID("gui/synthetic_toggle"))
                surface.DrawTexturedRect(0, 0, 16, 16)
            end
            """,
            sourceName: "@GModMetalSourceMaterialResolverTests.lua"
        )
        let snapshot = try XCTUnwrap(runtime.vguiRegistry).renderFrame(
            surface: try XCTUnwrap(runtime.surfaceCommandState),
            viewportWidth: 32,
            viewportHeight: 32
        )
        let scene = try GModMetalSurfaceScene(
            snapshot: snapshot,
            textureResolver: resolver
        )

        XCTAssertEqual(scene.diagnostics.unresolvedCommands, [])
        guard case let .texturedRectangle(command) = try XCTUnwrap(
            scene.commands.first
        ) else {
            return XCTFail("expected a VMT-backed textured rectangle")
        }
        XCTAssertEqual(command.textureName, "gui/synthetic_toggle")
        XCTAssertEqual(command.bitmap.resourceIdentifier, "materials/gui/synthetic_toggle.vtf")
        XCTAssertEqual(command.bitmap.width, 2)
        XCTAssertEqual(command.bitmap.height, 1)
        XCTAssertEqual(
            command.bitmap.premultipliedRGBA8,
            Data([128, 0, 0, 128, 0, 200, 0, 255])
        )
        XCTAssertEqual(
            try resolver.resolveSurfaceTexture(named: "GUI\\SYNTHETIC_TOGGLE"),
            command.bitmap
        )
        XCTAssertEqual(resolver.cachedEntryCount, 1)
        XCTAssertEqual(resolver.cachedTextureByteCount, 8)
    }

    func testSourceMaterialCachesCannotPublishDelayedOldMountAfterSwap() throws {
        let materialPath = "materials/gui/epoch_race.vmt"
        let texturePath = "materials/gui/epoch_race.vtf"
        let material = Data(
            "\"UnlitGeneric\" { \"$basetexture\" \"gui/epoch_race\" }".utf8
        )
        let oldPixels = [UInt8](arrayLiteral: 255, 0, 0, 255)
        let newPixels = [UInt8](arrayLiteral: 0, 0, 255, 255)
        let source = DelayedMapMaterialSource(
            files: [
                materialPath: material,
                texturePath: makeSurfaceRGBA8888VTF(
                    width: 1,
                    height: 1,
                    pixels: oldPixels
                ),
            ],
            delayedPath: texturePath
        )
        let resolver = GModMetalSurfaceSourceMaterialResolver(
            maximumCachedEntryCount: 1,
            maximumCachedByteCount: 64,
            contentEpochProvider: { source.contentEpoch },
            loader: { source.data(for: $0) }
        )
        let oldResolution = SurfaceBitmapAsyncResult()
        let workerFinished = DispatchSemaphore(value: 0)

        DispatchQueue(
            label: "GModMetalSurfaceSceneTests.oldMountDecode"
        ).async {
            oldResolution.record(Result {
                try resolver.resolveSurfaceTexture(named: "gui/epoch_race")
            })
            workerFinished.signal()
        }
        guard source.delayedReadStarted.wait(timeout: .now() + 10) == .success
        else {
            source.releaseDelayedRead.signal()
            return XCTFail("old-map VTF decode did not reach its deterministic gate")
        }

        source.swap(to: [
            materialPath: material,
            texturePath: makeSurfaceRGBA8888VTF(
                width: 1,
                height: 1,
                pixels: newPixels
            ),
        ])
        resolver.removeAllCachedTextures()
        let newMountBitmap = try XCTUnwrap(
            resolver.resolveSurfaceTexture(named: "gui/epoch_race")
        )
        XCTAssertEqual(newMountBitmap.premultipliedRGBA8, Data(newPixels))

        source.releaseDelayedRead.signal()
        guard workerFinished.wait(timeout: .now() + 10) == .success else {
            return XCTFail("delayed old-map decode did not finish")
        }
        XCTAssertEqual(
            try XCTUnwrap(
                try XCTUnwrap(oldResolution.value).get()
            ).premultipliedRGBA8,
            Data(oldPixels)
        )

        // The delayed old entries are allowed to remain in the bounded LRUs,
        // but neither resolver may return them under the new mount epoch.
        let currentBitmap = try XCTUnwrap(
            resolver.resolveSurfaceTexture(named: "gui/epoch_race")
        )
        XCTAssertEqual(currentBitmap.premultipliedRGBA8, Data(newPixels))
        XCTAssertLessThanOrEqual(resolver.cachedEntryCount, 1)
        XCTAssertLessThanOrEqual(resolver.cachedTextureByteCount, 64)
        XCTAssertLessThanOrEqual(
            resolver.sourceMaterialResolver.cachedEntryCount,
            512
        )
    }

    func testSourceMaterialResolverSeparatesWorldMipChainFromSurfaceMipZero() throws {
        let base = [UInt8](repeating: 0x40, count: 4 * 4 * 4)
        let mip1 = [UInt8](repeating: 0x80, count: 2 * 2 * 4)
        let mip2 = [UInt8](repeating: 0xC0, count: 1 * 1 * 4)
        let files: [String: Data] = [
            "materials/gui/mipped.vmt": Data(
                "\"UnlitGeneric\" { \"$basetexture\" \"gui/mipped\" }".utf8
            ),
            "materials/gui/mipped.vtf": makeSurfaceRGBA8888VTF(
                width: 4,
                height: 4,
                pixels: base,
                mipPixelsByLevel: [mip1, mip2]
            ),
        ]
        let resolver = GModMetalSurfaceSourceMaterialResolver(
            maximumCachedEntryCount: 4,
            maximumCachedByteCount: 256
        ) { files[$0.lowercased()] }

        let surface = try XCTUnwrap(
            resolver.resolveSurfaceTexture(named: "gui/mipped")
        )
        XCTAssertEqual(surface.mipLevels.count, 1)
        XCTAssertEqual(surface.totalByteCount, base.count)
        XCTAssertEqual(surface.alphaRepresentation, .premultiplied)
        XCTAssertEqual(resolver.sourceMaterialResolver.cachedEntryCount, 1)
        XCTAssertEqual(
            resolver.sourceMaterialResolver.cachedImageByteCount,
            base.count
        )
        XCTAssertEqual(
            GModMetalSurfaceTextureUploadContract.mipmapLevelCount,
            1
        )
        let world = try XCTUnwrap(
            resolver.resolveWorldTexture(named: "gui/mipped")
        )
        XCTAssertEqual(world.mipLevels.map(\.width), [4, 2, 1])
        XCTAssertEqual(world.totalByteCount, base.count + mip1.count + mip2.count)
        XCTAssertEqual(world.alphaRepresentation, .straight)
        XCTAssertEqual(world.mipLevels[0].premultipliedRGBA8, Data(base))
        XCTAssertNotEqual(surface.premultipliedRGBA8, world.mipLevels[0].premultipliedRGBA8)
        XCTAssertNotEqual(surface.cacheIdentifier, world.cacheIdentifier)
        XCTAssertEqual(resolver.sourceMaterialResolver.cachedEntryCount, 2)
        XCTAssertEqual(
            resolver.sourceMaterialResolver.cachedImageByteCount,
            base.count * 2 + mip1.count + mip2.count
        )
        XCTAssertEqual(resolver.cachedEntryCount, 2)
        XCTAssertEqual(
            resolver.cachedTextureByteCount,
            surface.totalByteCount + world.totalByteCount
        )
    }

    func testSourceMaterialResolverDeduplicatesVMTAliasesByVTFIdentity() throws {
        let pixels = [UInt8](repeating: 0x7F, count: 2 * 2 * 4)
        let files: [String: Data] = [
            "materials/alias/first.vmt": Data(
                "\"UnlitGeneric\" { \"$basetexture\" \"shared/payload\" }".utf8
            ),
            "materials/alias/second.vmt": Data(
                (
                    "\"LightmappedGeneric\" { \"$basetexture\" " +
                        "\"MATERIALS/SHARED/PAYLOAD.VTF\" }"
                ).utf8
            ),
            "materials/shared/payload.vtf": makeSurfaceRGBA8888VTF(
                width: 2,
                height: 2,
                pixels: pixels
            ),
        ]
        let resolver = GModMetalSurfaceSourceMaterialResolver {
            files[$0.lowercased()]
        }

        let first = try XCTUnwrap(
            resolver.resolveWorldTexture(named: "alias/first")
        )
        let second = try XCTUnwrap(
            resolver.resolveWorldTexture(named: "alias/second")
        )

        XCTAssertEqual(first.resourceIdentifier, "materials/shared/payload.vtf")
        XCTAssertEqual(second.resourceIdentifier, first.resourceIdentifier)
        XCTAssertEqual(second.cacheIdentifier, first.cacheIdentifier)
        XCTAssertEqual(second, first)
        var budget = GModMetalWorldBitmapRetentionBudget(
            maximumByteCount: first.totalByteCount
        )
        XCTAssertTrue(budget.retain(first))
        XCTAssertTrue(budget.retain(second))
        XCTAssertEqual(budget.retainedByteCount, first.totalByteCount)
    }

    func testSourceMaterialResolverRetainsOnlyMipZeroForNoMipVTF() throws {
        let base = [UInt8](repeating: 0x40, count: 4 * 4 * 4)
        let mip1 = [UInt8](repeating: 0x80, count: 2 * 2 * 4)
        let mip2 = [UInt8](repeating: 0xC0, count: 1 * 1 * 4)
        let files: [String: Data] = [
            "materials/gui/no_mip.vmt": Data(
                "\"LightmappedGeneric\" { \"$basetexture\" \"gui/no_mip\" }".utf8
            ),
            "materials/gui/no_mip.vtf": makeSurfaceRGBA8888VTF(
                width: 4,
                height: 4,
                pixels: base,
                mipPixelsByLevel: [mip1, mip2],
                flags: [.noMip]
            ),
        ]
        let resolver = GModMetalSurfaceSourceMaterialResolver {
            files[$0.lowercased()]
        }

        let world = try XCTUnwrap(
            resolver.resolveWorldTexture(named: "gui/no_mip")
        )

        XCTAssertEqual(world.resourceIdentifier, "materials/gui/no_mip.vtf")
        XCTAssertEqual(world.mipLevels.map(\.width), [4])
        XCTAssertEqual(world.mipLevels[0].premultipliedRGBA8, Data(base))
        XCTAssertEqual(world.totalByteCount, base.count)
        XCTAssertTrue(try XCTUnwrap(world.sourceTextureFlags).contains(.noMip))
        XCTAssertEqual(resolver.cachedTextureByteCount, base.count)
    }

    func testSceneBoundsUniqueBitmapRetentionWithoutReordering() throws {
        let snapshot = try makeTextureBudgetSnapshot()
        let countBoundScene = try GModMetalSurfaceScene(
            snapshot: snapshot,
            textureResolver: NamedFixtureTextureResolver(),
            maximumRetainedBitmapCount: 2,
            maximumRetainedBitmapByteCount: 32
        )

        XCTAssertEqual(
            countBoundScene.commands.compactMap { command in
                guard case let .texturedRectangle(texture) = command else {
                    return nil
                }
                return texture.textureName
            },
            ["one.png", "one.png", "two.png"]
        )
        XCTAssertEqual(countBoundScene.diagnostics.texturedRectangleCount, 3)
        XCTAssertEqual(countBoundScene.diagnostics.retainedBitmapCount, 2)
        XCTAssertEqual(countBoundScene.diagnostics.retainedBitmapByteCount, 32)
        XCTAssertEqual(
            countBoundScene.diagnostics.unresolvedCommands.map(\.commandIndex),
            [3]
        )
        XCTAssertTrue(
            countBoundScene.diagnostics.unresolvedCommands[0].reason.contains(
                "scene bitmap retention limit"
            )
        )

        let byteBoundScene = try GModMetalSurfaceScene(
            snapshot: snapshot,
            textureResolver: NamedFixtureTextureResolver(),
            maximumRetainedBitmapCount: 10,
            maximumRetainedBitmapByteCount: 16
        )
        XCTAssertEqual(byteBoundScene.commands.count, 2)
        XCTAssertEqual(byteBoundScene.diagnostics.retainedBitmapCount, 1)
        XCTAssertEqual(byteBoundScene.diagnostics.retainedBitmapByteCount, 16)
        XCTAssertEqual(
            byteBoundScene.diagnostics.unresolvedCommands.map(\.commandIndex),
            [2, 3]
        )
    }

#if canImport(CoreText) && canImport(GModApp)
    func testCoreTextRasterizerUsesRegisteredBundledFaceOffRenderThread() throws {
        let registry = GModBundledFontRegistry.shared
        XCTAssertTrue(registry.registerAllFonts().failures.isEmpty)
        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            bootstrapMode: .strict
        )
        try runtime.execute(
            """
            surface.CreateFont("SurfaceRoboto20", {
                font = "Roboto",
                size = 20,
                weight = 400
            })
            """,
            sourceName: "@GModMetalCoreTextRasterizerTests.lua"
        )
        let descriptor = try XCTUnwrap(
            runtime.surfaceCommandState?.fontDescriptor(named: "SurfaceRoboto20")
        )
        let rasterizer = GModMetalCoreTextRasterizer(
            maximumCachedGlyphCount: 1,
            maximumCachedByteCount: 1_024 * 1_024,
            fontNameResolver: {
                registry.resolvedPostScriptName(
                    requestedName: $0,
                    weight: $1,
                    italic: $2
                )
            }
        )
        let bitmap = try XCTUnwrap(
            rasterizer.rasterizeSurfaceText("Sandbox", font: descriptor)
        )

        XCTAssertGreaterThan(bitmap.width, 0)
        XCTAssertEqual(bitmap.height, 20)
        XCTAssertTrue(
            stride(from: 3, to: bitmap.premultipliedRGBA8.count, by: 4)
                .contains { bitmap.premultipliedRGBA8[$0] > 0 }
        )
        XCTAssertGreaterThanOrEqual(
            alphaOccupiedRows(in: bitmap).count,
            bitmap.height / 2,
            "a full CoreText line must not collapse to a clipped alpha strip"
        )
        XCTAssertEqual(
            try rasterizer.rasterizeSurfaceText("Sandbox", font: descriptor),
            bitmap,
            "the immutable glyph cache should return identical pixels"
        )

        let japanese = try XCTUnwrap(
            rasterizer.rasterizeSurfaceText("武器", font: descriptor)
        )
        XCTAssertGreaterThan(japanese.width, 0)
        XCTAssertEqual(japanese.height, 20)
        XCTAssertGreaterThanOrEqual(
            alphaOccupiedRows(in: japanese).count,
            japanese.height / 3,
            "CoreText fallback must rasterize CJK across meaningful rows"
        )
        _ = try XCTUnwrap(
            rasterizer.rasterizeSurfaceText("A different label", font: descriptor)
        )
        XCTAssertEqual(rasterizer.cachedGlyphCount, 1)
        XCTAssertLessThanOrEqual(
            rasterizer.cachedGlyphByteCount,
            1_024 * 1_024
        )
    }

    private func alphaOccupiedRows(
        in bitmap: GModMetalSurfaceBitmap
    ) -> Set<Int> {
        var rows: Set<Int> = []
        for pixelIndex in 0..<(bitmap.width * bitmap.height) {
            let alphaIndex = pixelIndex * 4 + 3
            if bitmap.premultipliedRGBA8[alphaIndex] > 0 {
                rows.insert(pixelIndex / bitmap.width)
            }
        }
        return rows
    }
#endif

    private func makeSnapshot() throws -> GMLuaSurfaceFrameSnapshot {
        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            bootstrapMode: .strict
        )
        try runtime.execute(
            """
            ROOT = vgui.Create("Panel")
            ROOT:SetSize(100, 100)
            function ROOT:Paint(w, h)
                surface.SetDrawColor(10, 20, 30, 128)
                surface.DrawRect(-10, 20, 50, 40)

                surface.SetDrawColor(255, 255, 255, 255)
                surface.SetTexture(surface.GetTextureID("icon16/brick.png"))
                surface.DrawTexturedRectUV(80, 80, 40, 40, 0, 0, 1, 1)

                surface.SetFont("Default")
                surface.SetTextColor(200, 210, 220, 230)
                surface.SetTextPos(90, 90)
                surface.DrawText("clip me")
            end
            """,
            sourceName: "@GModMetalSurfaceSceneTests.lua"
        )
        return try XCTUnwrap(runtime.vguiRegistry).renderFrame(
            surface: try XCTUnwrap(runtime.surfaceCommandState),
            viewportWidth: 100,
            viewportHeight: 100
        )
    }

    private func makeTextureBudgetSnapshot() throws
        -> GMLuaSurfaceFrameSnapshot
    {
        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            bootstrapMode: .strict
        )
        try runtime.execute(
            """
            ROOT = vgui.Create("Panel")
            ROOT:SetSize(100, 100)
            function ROOT:Paint(w, h)
                local names = { "one.png", "one.png", "two.png", "three.png" }
                surface.SetDrawColor(255, 255, 255, 255)
                for index, name in ipairs(names) do
                    surface.SetTexture(surface.GetTextureID(name))
                    surface.DrawTexturedRectUV(
                        (index - 1) * 20, 0, 16, 16, 0, 0, 1, 1
                    )
                end
            end
            """,
            sourceName: "@GModMetalSurfaceSceneBitmapBudgetTests.lua"
        )
        return try XCTUnwrap(runtime.vguiRegistry).renderFrame(
            surface: try XCTUnwrap(runtime.surfaceCommandState),
            viewportWidth: 100,
            viewportHeight: 100
        )
    }
}

private final class SurfaceBitmapAsyncResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<GModMetalSurfaceBitmap?, Error>?

    func record(_ result: Result<GModMetalSurfaceBitmap?, Error>) {
        lock.lock()
        storage = result
        lock.unlock()
    }

    var value: Result<GModMetalSurfaceBitmap?, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class DelayedMapMaterialSource: @unchecked Sendable {
    let delayedReadStarted = DispatchSemaphore(value: 0)
    let releaseDelayedRead = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private let delayedPath: String
    private var files: [String: Data]
    private var epochStorage: UInt64 = 1
    private var shouldDelay = true

    init(files: [String: Data], delayedPath: String) {
        self.files = Dictionary(
            uniqueKeysWithValues: files.map { ($0.key.lowercased(), $0.value) }
        )
        self.delayedPath = delayedPath.lowercased()
    }

    var contentEpoch: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return epochStorage
    }

    func data(for logicalPath: String) -> Data? {
        let key = logicalPath.lowercased()
        lock.lock()
        let result = files[key]
        let delayThisRead = key == delayedPath && shouldDelay
        if delayThisRead {
            shouldDelay = false
        }
        lock.unlock()

        if delayThisRead {
            delayedReadStarted.signal()
            releaseDelayedRead.wait()
        }
        return result
    }

    func swap(to replacement: [String: Data]) {
        lock.lock()
        precondition(epochStorage < UInt64.max)
        files = Dictionary(
            uniqueKeysWithValues: replacement.map {
                ($0.key.lowercased(), $0.value)
            }
        )
        epochStorage += 1
        lock.unlock()
    }
}

private func makePNGHeader(width: UInt32, height: UInt32) -> Data {
    var bytes: [UInt8] = [
        137, 80, 78, 71, 13, 10, 26, 10,
        0, 0, 0, 13,
        73, 72, 68, 82,
        0, 0, 0, 0,
        0, 0, 0, 0,
        8, 6, 0, 0, 0,
        0, 0, 0, 0
    ]
    func writeBigEndian(_ value: UInt32, at offset: Int) {
        bytes[offset] = UInt8((value >> 24) & 0xFF)
        bytes[offset + 1] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 3] = UInt8(value & 0xFF)
    }
    writeBigEndian(width, at: 16)
    writeBigEndian(height, at: 20)
    return Data(bytes)
}

private func makeSurfaceRGBA8888VTF(
    width: Int,
    height: Int,
    pixels: [UInt8],
    mipPixelsByLevel: [[UInt8]] = [],
    flags: SourceVTFTextureFlags = []
) -> Data {
    precondition(width > 0 && height > 0 && pixels.count == width * height * 4)
    for (offset, mip) in mipPixelsByLevel.enumerated() {
        let level = offset + 1
        precondition(
            mip.count == max(1, width >> level) * max(1, height >> level) * 4
        )
    }
    var bytes = [UInt8](repeating: 0, count: 80)
    func write(_ value: UInt16, at offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }
    func write(_ value: UInt32, at offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
    bytes.replaceSubrange(0..<4, with: [0x56, 0x54, 0x46, 0x00])
    write(UInt32(7), at: 4)
    write(UInt32(2), at: 8)
    write(UInt32(80), at: 12)
    write(UInt16(width), at: 16)
    write(UInt16(height), at: 18)
    write(flags.rawValue, at: 20)
    write(UInt16(1), at: 24)
    write(Float(1).bitPattern, at: 48)
    write(UInt32(bitPattern: SourceVTFImageFormat.rgba8888.rawValue), at: 52)
    bytes[56] = UInt8(1 + mipPixelsByLevel.count)
    write(UInt32(bitPattern: SourceVTFImageFormat.unknown.rawValue), at: 57)
    write(UInt16(1), at: 63)
    for mip in mipPixelsByLevel.reversed() {
        bytes.append(contentsOf: mip)
    }
    bytes.append(contentsOf: pixels)
    return Data(bytes)
}

private struct FixtureTextureResolver: GModMetalSurfaceTextureResolving {
    func resolveSurfaceTexture(
        named logicalName: String
    ) throws -> GModMetalSurfaceBitmap? {
        guard logicalName == "icon16/brick.png" else { return nil }
        return try GModMetalSurfaceBitmap(
            resourceIdentifier: logicalName,
            width: 2,
            height: 2,
            premultipliedRGBA8: Data(repeating: 255, count: 16)
        )
    }
}

private struct FixtureTextRasterizer: GModMetalSurfaceTextRasterizing {
    func rasterizeSurfaceText(
        _ text: String,
        font: GMLuaFontDescriptor
    ) throws -> GModMetalSurfaceBitmap? {
        try GModMetalSurfaceBitmap(
            resourceIdentifier: "fixture-text",
            width: 20,
            height: 20,
            premultipliedRGBA8: Data(repeating: 255, count: 20 * 20 * 4)
        )
    }
}

private struct NamedFixtureTextureResolver: GModMetalSurfaceTextureResolving {
    func resolveSurfaceTexture(
        named logicalName: String
    ) throws -> GModMetalSurfaceBitmap? {
        try GModMetalSurfaceBitmap(
            resourceIdentifier: logicalName,
            width: 2,
            height: 2,
            premultipliedRGBA8: Data(repeating: 255, count: 16)
        )
    }
}
