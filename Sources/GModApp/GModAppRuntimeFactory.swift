import GModEngine
import GModGameAssets
import GModGameSession
import GModMetal

/// Production construction seam shared by the server console runtime and the
/// retained client surface runtime. Keeping one measurer here prevents the App
/// layer from registering fonts yet accidentally leaving CLIENT on logical
/// estimates.
public final class GModAppRuntimeFactory: @unchecked Sendable {
    public let fontRegistrationReport: GModBundledFontRegistrationReport?
    public let surfaceTextureResolver: GModMetalSurfaceSourceMaterialResolver
    public let surfaceTextRasterizer: GModMetalCoreTextRasterizer

    private let textMeasurer: any GMLuaTextMeasurer

    // VMT/VTF/PNG decoding and CoreText glyph creation are relatively expensive. The
    // concrete resolvers are thread-safe and deliberately shared at process
    // scope so recreating a SwiftUI model does not discard immutable results.
    private static let processSurfaceTextureResolver =
        GModMetalSurfaceSourceMaterialResolver { logicalPath in
            do {
                return try GModGameAssets.clientContentData(
                    for: logicalPath
                )
            } catch let error as GModGameAssetError {
                switch error {
                case .missingResource:
                    return nil
                case .invalidManifest, .invalidContentPath:
                    throw error
                }
            }
        }

    private static let processSurfaceTextRasterizer =
        GModMetalCoreTextRasterizer(
            fontNameResolver: { requestedName, weight, italic in
                GModBundledFontRegistry.shared.resolvedPostScriptName(
                    requestedName: requestedName,
                    weight: weight,
                    italic: italic
                )
            }
        )

    public convenience init() {
        let measurer = GModCoreTextMeasurer()
        self.init(
            textMeasurer: measurer,
            fontRegistrationReport: measurer.registrationReport
        )
    }

    public init(
        textMeasurer: any GMLuaTextMeasurer,
        fontRegistrationReport: GModBundledFontRegistrationReport? = nil
    ) {
        self.textMeasurer = textMeasurer
        self.fontRegistrationReport = fontRegistrationReport
        surfaceTextureResolver = Self.processSurfaceTextureResolver
        surfaceTextRasterizer = Self.processSurfaceTextRasterizer
    }

    public func makeRuntime(
        realm: GMLuaRealm,
        logger: @escaping (String) -> Void,
        bootstrapMode: GMLuaBootstrapMode = .strict,
        initialViewport: GMLuaViewportSize = .logicalDesktopDefault
    ) -> GMLuaRuntime {
        GMLuaRuntime(
            realm: realm,
            logger: logger,
            bootstrapMode: bootstrapMode,
            initialViewport: initialViewport,
            textMeasurer: textMeasurer
        )
    }

    public func makePlayableSession(
        configuration: GModPlayableSessionConfiguration = .init(),
        logger: @escaping (_ realm: GMLuaRealm, _ message: String) -> Void
    ) throws -> GModPlayableSession {
        try GModPlayableSession(
            configuration: configuration,
            textMeasurer: textMeasurer,
            logger: logger
        )
    }

    public func makePlayableSessionLane() -> GModPlayableSessionLane {
        GModPlayableSessionLane(textMeasurer: textMeasurer)
    }
}
