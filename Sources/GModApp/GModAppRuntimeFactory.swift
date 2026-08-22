import Foundation
import GModEngine
import GModGameAssets
import GModGameSession
import GModLua
import GModMetal

private final class GModMountedContentSource: @unchecked Sendable {
    private let lock = NSLock()
    private var source: GModContentPackAssetSource?

    func mount(_ replacement: GModContentPackAssetSource) {
        lock.lock()
        source = replacement
        lock.unlock()
    }

    func unmount() {
        lock.lock()
        source = nil
        lock.unlock()
    }

    func data(
        for logicalPath: String,
        maximumByteCount: UInt64 = 64 * 1_024 * 1_024
    ) throws -> Data? {
        lock.lock()
        let current = source
        lock.unlock()
        return try current?.data(
            for: logicalPath,
            maximumByteCount: maximumByteCount
        )
    }

    func mountedArchiveURL() -> URL? {
        lock.lock()
        let url = source?.pack.archiveURL
        lock.unlock()
        return url
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

    /// Resolves a bounded generic asset through the exact active content-pack
    /// mount used by Metal: loose ZIP files first, then nested VPKs, then the
    /// audited package fallback. The active source changes transactionally
    /// only after ContentModel validates a replacement ZIP.
    func mountedContentData(
        for logicalPath: String,
        maximumByteCount: UInt64
    ) throws -> Data? {
        if let mounted = try Self.processMountedContentSource.data(
            for: logicalPath,
            maximumByteCount: maximumByteCount
        ) {
            return mounted
        }
        do {
            let bundled = try GModGameAssets.clientContentData(
                for: logicalPath
            )
            return UInt64(bundled.count) <= maximumByteCount
                ? bundled
                : nil
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

    /// Builds the trusted MENU realm with the same CoreText measurement
    /// boundary used by gameplay VGUI. Home, Options, Problems, and Console
    /// therefore share one Derma layout contract instead of falling back to
    /// logical glyph estimates.
    public func makeMenuSession(
        fileSystem: any LuaVirtualFileSystem & Sendable,
        initialViewport: GMLuaViewportSize = .logicalDesktopDefault,
        languageConfiguration: GMLuaLanguageConfiguration = .empty,
        permissionsHost: GMLuaPermissionsHost? = nil,
        logger: @escaping (String) -> Void
    ) -> GMLuaMenuSession {
        GMLuaMenuSession(
            fileSystem: fileSystem,
            initialViewport: initialViewport,
            textMeasurer: textMeasurer,
            languageConfiguration: languageConfiguration,
            permissionsHost: permissionsHost,
            logger: logger
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
        clearContentCaches()
    }

    func unmountContentPack() {
        Self.processMountedContentSource.unmount()
        clearContentCaches()
    }

    func clearContentCaches() {
        Self.processSurfaceTextureResolver.removeAllCachedTextures()
        Self.processSurfaceTextRasterizer.removeAllCachedGlyphs()
        NotificationCenter.default.post(
            name: GModMenuAudioSettingsStore.clearContentCachesNotification,
            object: nil
        )
    }

    func cacheDiagnostics() -> (textures: Int, textureBytes: Int, glyphs: Int,
        glyphBytes: Int) {
        (
            Self.processSurfaceTextureResolver.cachedEntryCount,
            Self.processSurfaceTextureResolver.cachedTextureByteCount,
            Self.processSurfaceTextRasterizer.cachedGlyphCount,
            Self.processSurfaceTextRasterizer.cachedGlyphByteCount
        )
    }

    func mountedContentPackURLForTesting() -> URL? {
        Self.processMountedContentSource.mountedArchiveURL()
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
