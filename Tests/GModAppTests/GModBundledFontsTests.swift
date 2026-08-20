import Foundation
import XCTest
@testable import GModApp
import GModEngine
import GModLua

final class GModBundledFontsTests: XCTestCase {
    func testRuntimeFactoriesShareProcessSurfaceCachesAndResolveBundledPNG()
        throws
    {
        let first = GModAppRuntimeFactory()
        let second = GModAppRuntimeFactory()

        XCTAssertTrue(
            first.surfaceTextureResolver === second.surfaceTextureResolver
        )
        XCTAssertTrue(
            first.surfaceTextRasterizer === second.surfaceTextRasterizer
        )
        let bitmap = try XCTUnwrap(
            first.surfaceTextureResolver.resolveSurfaceTexture(
                named: "widgets/arrow.png"
            )
        )
        XCTAssertGreaterThan(bitmap.width, 0)
        XCTAssertGreaterThan(bitmap.height, 0)
    }

    func testProductionRuntimeFactoryDrivesClientSurfaceButNotServerSurface() throws {
        struct ProbeMeasurer: GMLuaTextMeasurer {
            let fidelity = GMLuaTextMeasurementFidelity.platformGlyphMetrics

            func measure(
                _ text: LuaString,
                using font: GMLuaFontDescriptor
            ) -> GMLuaTextMeasurement {
                GMLuaTextMeasurement(width: text.count, height: font.size)
            }
        }

        let factory = GModAppRuntimeFactory(textMeasurer: ProbeMeasurer())
        let client = factory.makeRuntime(realm: .client, logger: { _ in })
        let server = factory.makeRuntime(realm: .server, logger: { _ in })

        XCTAssertEqual(
            try XCTUnwrap(client.surfaceCommandState).textMeasurementFidelity,
            .platformGlyphMetrics
        )
        XCTAssertNil(server.surfaceCommandState)
    }

    func testBundledRobotoUsesSourceFontTallForSingleAndMultilineText() throws {
        let factory = GModAppRuntimeFactory()
        let client = factory.makeRuntime(realm: .client, logger: { _ in })
        let values = try client.executeReturningValues(
            #"""
            surface.CreateFont("RobotoTall13", {
                font = "Roboto",
                size = 13,
                weight = 400
            })
            surface.SetFont("RobotoTall13")
            local _, empty13 = surface.GetTextSize("")
            local _, h13 = surface.GetTextSize("A")
            local _, h26 = surface.GetTextSize("A\nB")

            surface.CreateFont("RobotoTall20", {
                font = "Roboto",
                size = 20,
                weight = 400
            })
            surface.SetFont("RobotoTall20")
            local _, empty20 = surface.GetTextSize("")
            local _, h20 = surface.GetTextSize("A")
            local _, h40 = surface.GetTextSize("A\nB")
            return empty13, h13, h26, empty20, h20, h40
            """#,
            sourceName: "@GModBundledRobotoTall.lua"
        )
        guard values.count == 6,
              case let .number(emptyHeight13) = values[0],
              case let .number(height13) = values[1],
              case let .number(height26) = values[2],
              case let .number(emptyHeight20) = values[3],
              case let .number(height20) = values[4],
              case let .number(height40) = values[5] else {
            return XCTFail("Roboto tall measurements were not numeric")
        }
        XCTAssertEqual(emptyHeight13, 13)
        XCTAssertEqual(height13, 13)
        XCTAssertEqual(height26, 26)
        XCTAssertEqual(emptyHeight20, 20)
        XCTAssertEqual(height20, 20)
        XCTAssertEqual(height40, 40)
        XCTAssertEqual(
            GModBundledFontRegistry.shared.resolvedPostScriptName(
                requestedName: "Roboto",
                weight: 400,
                italic: false
            ),
            "Roboto-Regular"
        )
        XCTAssertFalse(
            factory.fontRegistrationReport?.failures.contains {
                $0.bundleFile == "Roboto-Regular.ttf"
            } ?? true
        )
    }

    func testStockDermaTahomaUsesTheSameBundledFallbackForLayoutAndPixels()
        throws
    {
        let factory = GModAppRuntimeFactory()
        let regular = try XCTUnwrap(
            GModBundledFontRegistry.shared.resolvedPostScriptName(
                requestedName: "Tahoma",
                weight: 500,
                italic: false
            )
        )
        let bold = try XCTUnwrap(
            GModBundledFontRegistry.shared.resolvedPostScriptName(
                requestedName: "Tahoma",
                weight: 800,
                italic: false
            )
        )
        XCTAssertTrue(regular.hasPrefix("Roboto-"))
        XCTAssertTrue(bold.hasPrefix("Roboto-"))

        let client = factory.makeRuntime(realm: .client, logger: { _ in })
        try client.execute(
            """
            surface.CreateFont("DermaFallbackRegular", {
                font = "Tahoma", size = 13, weight = 500, extended = true
            })
            surface.CreateFont("DermaFallbackBold", {
                font = "Tahoma", size = 13, weight = 800, extended = true
            })
            """,
            sourceName: "@GModDermaTahomaFallback.lua"
        )
        let surface = try XCTUnwrap(client.surfaceCommandState)
        for name in ["DermaFallbackRegular", "DermaFallbackBold"] {
            let descriptor = try XCTUnwrap(
                surface.fontDescriptor(named: LuaString(name))
            )
            let bitmap = try XCTUnwrap(
                factory.surfaceTextRasterizer.rasterizeSurfaceText(
                    "Sandbox",
                    font: descriptor
                )
            )
            XCTAssertEqual(bitmap.height, 13)
            XCTAssertGreaterThan(bitmap.width, 0)
            XCTAssertTrue(
                stride(from: 3, to: bitmap.premultipliedRGBA8.count, by: 4)
                    .contains { bitmap.premultipliedRGBA8[$0] > 0 }
            )
        }
    }

    func testRegistrationReportDistinguishesRegisteredAlreadyAndFailureAndCaches() {
        let resources = SyntheticFontResources(
            manifestData: Self.registrationManifest,
            byteCounts: ["a.ttf": 10, "b.ttf": 10, "c.ttf": 10]
        )
        let registrar = SyntheticFontRegistrar(
            attempts: [
                "a.ttf": .registered,
                "b.ttf": .alreadyRegistered,
                "c.ttf": .failed("synthetic rejection")
            ],
            resolvablePostScriptNames: ["FaceB"]
        )
        let registry = GModBundledFontRegistry(
            resourceResolver: resources,
            registrar: registrar
        )

        let first = registry.registerAllFonts()
        let second = registry.registerAllFonts()
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.registeredFileCount, 1)
        XCTAssertEqual(first.alreadyRegisteredFileCount, 1)
        XCTAssertEqual(first.failures.map(\.bundleFile), ["c.ttf"])
        XCTAssertFalse(first.succeeded)
        XCTAssertEqual(registrar.registrationCallCount, 3)
    }

    func testAlreadyRegisteredWithoutExpectedPostScriptFaceIsFailure() {
        let resources = SyntheticFontResources(
            manifestData: Self.singleAlreadyRegisteredManifest,
            byteCounts: ["missing-face.ttf": 10]
        )
        let registrar = SyntheticFontRegistrar(
            attempts: ["missing-face.ttf": .alreadyRegistered],
            resolvablePostScriptNames: []
        )
        let registry = GModBundledFontRegistry(
            resourceResolver: resources,
            registrar: registrar
        )

        let report = registry.registerAllFonts()
        XCTAssertEqual(report.registeredFileCount, 0)
        XCTAssertEqual(report.alreadyRegisteredFileCount, 0)
        XCTAssertEqual(report.failures.map(\.bundleFile), ["missing-face.ttf"])
        XCTAssertTrue(
            report.failures[0].message.contains("expected PostScript face")
        )
    }

    private struct SyntheticFontResources: GModFontResourceResolving {
        let manifestData: Data
        let byteCounts: [String: Int64]

        func data(named name: String) throws -> Data {
            guard name == "GModFonts.manifest.json" else {
                throw CocoaError(.fileNoSuchFile)
            }
            return manifestData
        }

        func resourceURL(named name: String) -> URL? {
            byteCounts[name] == nil
                ? nil
                : URL(fileURLWithPath: "/synthetic/\(name)")
        }

        func byteCount(at url: URL) -> Int64? {
            byteCounts[url.lastPathComponent]
        }
    }

    private final class SyntheticFontRegistrar:
        GModFontRegistering,
        @unchecked Sendable
    {
        private let lock = NSLock()
        private let attempts: [String: GModFontRegistrationAttempt]
        private let resolvablePostScriptNames: Set<String>
        private var callCount = 0

        init(
            attempts: [String: GModFontRegistrationAttempt],
            resolvablePostScriptNames: Set<String>
        ) {
            self.attempts = attempts
            self.resolvablePostScriptNames = resolvablePostScriptNames
        }

        var registrationCallCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return callCount
        }

        func registerFont(at url: URL) -> GModFontRegistrationAttempt {
            lock.lock()
            callCount += 1
            let attempt = attempts[url.lastPathComponent]
                ?? .failed("missing synthetic attempt")
            lock.unlock()
            return attempt
        }

        func exactPostScriptFaceResolves(_ postScriptName: String) -> Bool {
            resolvablePostScriptNames.contains(postScriptName)
        }
    }

    private static let registrationManifest = Data(
        #"""
        {
          "sourceAliasCount": 3,
          "bundledFileCount": 3,
          "bundledByteCount": 30,
          "entries": [
            {
              "sourceAlias": "sourceengine/resource/a.ttf",
              "bundleFile": "a.ttf",
              "byteCount": 10,
              "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              "fontNames": {
                "family": "A", "subfamily": "Regular",
                "full": "Face A", "postScript": "FaceA"
              }
            },
            {
              "sourceAlias": "sourceengine/resource/b.ttf",
              "bundleFile": "b.ttf",
              "byteCount": 10,
              "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
              "fontNames": {
                "family": "B", "subfamily": "Regular",
                "full": "Face B", "postScript": "FaceB"
              }
            },
            {
              "sourceAlias": "sourceengine/resource/c.ttf",
              "bundleFile": "c.ttf",
              "byteCount": 10,
              "sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
              "fontNames": {
                "family": "C", "subfamily": "Regular",
                "full": "Face C", "postScript": "FaceC"
              }
            }
          ]
        }
        """#.utf8
    )

    private static let singleAlreadyRegisteredManifest = Data(
        #"""
        {
          "sourceAliasCount": 1,
          "bundledFileCount": 1,
          "bundledByteCount": 10,
          "entries": [
            {
              "sourceAlias": "sourceengine/resource/missing-face.ttf",
              "bundleFile": "missing-face.ttf",
              "byteCount": 10,
              "sha256": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
              "fontNames": {
                "family": "Missing", "subfamily": "Regular",
                "full": "Missing Face", "postScript": "MissingFace"
              }
            }
          ]
        }
        """#.utf8
    )
}
