import Foundation
import GModEngine
import GModGameAssets
import GModGameSession
import GModMetal

private final class GModMountedContentSource: @unchecked Sendable {
    private let lock = NSLock()
    private var source: GModContentPackAssetSource?

    func mount(_ replacement: GModContentPackAssetSource) {
        lock.lock()
        source = replacement
        lock.unlock()
    }

    func data(for logicalPath: String) throws -> Data? {
        lock.lock()
        let current = source
        lock.unlock()
        return try current?.data(for: logicalPath)
    }
}

/// Production construction seam shared by the server console runtime and the
/// retained client surface runtime. Keeping one measurer here prevents the App
/// layer from registering fonts yet accidentally leaving CLIENT on logical
/// estimates.
public final class GModAppRuntimeFactory: @unchecked Sendable {
    public let fontRegistrationReport: GModBundledFontRegistrationReport?
    public let surfaceTextureResolver: GModMetalSurfaceSourceMaterialResolver
    public let surfaceTextRasterizer: GModMetalCoreTextRasterizer

    private let textMeasurer: any GMLuaTextMeasurer

    private static let processMountedContentSource = GModMountedContentSource()

    // VMT/VTF/PNG decoding and CoreText glyph creation are relatively expensive. The
    // concrete resolvers are thread-safe and deliberately shared at process
    // scope so recreating a SwiftUI model does not discard immutable results.
    private static let processSurfaceTextureResolver =
        GModMetalSurfaceSourceMaterialResolver { logicalPath in
            if let mounted = try processMountedContentSource.data(for: logicalPath) {
                return mounted
            }
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

    @discardableResult
    public func mountContentPack(
        _ pack: GarrysPADContentPack
    ) throws -> GModContentPackAssetSource {
        let source = try prepareContentPack(pack)
        activateContentPack(source)
        return source
    }

    func prepareContentPack(
        _ pack: GarrysPADContentPack
    ) throws -> GModContentPackAssetSource {
        try GModContentPackAssetSource(pack: pack)
    }

    func activateContentPack(_ source: GModContentPackAssetSource) {
        Self.processMountedContentSource.mount(source)
        Self.processSurfaceTextureResolver.removeAllCachedTextures()
    }

    public func makePlayableSession(
        configuration: GModPlayableSessionConfiguration = .init(),
        logger: @escaping @Sendable (_ realm: GMLuaRealm, _ message: String) -> Void
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
