import GModEngine

/// Production construction seam shared by the server console runtime and the
/// retained client surface runtime. Keeping one measurer here prevents the App
/// layer from registering fonts yet accidentally leaving CLIENT on logical
/// estimates.
public final class GModAppRuntimeFactory: @unchecked Sendable {
    public let fontRegistrationReport: GModBundledFontRegistrationReport?

    private let textMeasurer: any GMLuaTextMeasurer

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
}
