/// Source SDK 2013 `RenderMode_t` values retained by one canonical Entity.
///
/// The renderer may not implement every blend path yet, but the authoritative
/// value must survive SERVER mutation and CLIENT replication without being
/// collapsed to a renderer-specific fallback.
public enum SourceEntityRenderMode: UInt8, CaseIterable, Equatable, Sendable {
    case normal = 0
    case transColor = 1
    case transTexture = 2
    case glow = 3
    case transAlpha = 4
    case transAdd = 5
    case environmental = 6
    case transAddFrameBlend = 7
    case transAlphaAdd = 8
    case worldGlow = 9
    case none = 10
}

/// Source SDK 2013 `RenderFx_t` values retained by one canonical Entity.
///
/// This is value storage only. Time-varying RenderFX animation remains a
/// separate renderer capability and is not approximated here.
public enum SourceEntityRenderFX: UInt8, CaseIterable, Equatable, Sendable {
    case none = 0
    case pulseSlow = 1
    case pulseFast = 2
    case pulseSlowWide = 3
    case pulseFastWide = 4
    case fadeSlow = 5
    case fadeFast = 6
    case solidSlow = 7
    case solidFast = 8
    case strobeSlow = 9
    case strobeFast = 10
    case strobeFaster = 11
    case flickerSlow = 12
    case flickerFast = 13
    case noDissipation = 14
    case distort = 15
    case hologram = 16
    case explode = 17
    case glowShell = 18
    case clampMinimumScale = 19
    case environmentalRain = 20
    case environmentalSnow = 21
    case spotlight = 22
    case ragdoll = 23
    case pulseFastWider = 24
}

/// Source `color32` modulation carried by an Entity snapshot.
public struct SourceEntityRenderColor: Equatable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    public var alpha: UInt8

    public init(
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        alpha: UInt8
    ) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let white = SourceEntityRenderColor(
        red: 255,
        green: 255,
        blue: 255,
        alpha: 255
    )
}

/// Renderer-neutral appearance owned by the canonical Entity.
public struct SourceEntityRenderState: Equatable, Sendable {
    public var color: SourceEntityRenderColor
    public var mode: SourceEntityRenderMode
    public var fx: SourceEntityRenderFX

    public init(
        color: SourceEntityRenderColor = .white,
        mode: SourceEntityRenderMode = .normal,
        fx: SourceEntityRenderFX = .none
    ) {
        self.color = color
        self.mode = mode
        self.fx = fx
    }
}
