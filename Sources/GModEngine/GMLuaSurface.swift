import Foundation
import GModLua

public enum GMLuaFontOrigin: String, Sendable, Equatable {
    case builtInUnresolved
    case customUnresolved
}

/// Normalized `FontData` retained independently of the platform text backend.
/// `hasPlatformFontBacking` remains false until the iPad renderer resolves the
/// requested face through UIKit/CoreText and creates glyph resources.
public struct GMLuaFontDescriptor: Sendable, Equatable {
    public let name: LuaString
    public let font: LuaString
    public let extended: Bool
    public let size: Int
    public let weight: Int
    public let blurSize: Int
    public let scanlines: Int
    public let antialias: Bool
    public let underline: Bool
    public let italic: Bool
    public let strikeout: Bool
    public let symbol: Bool
    public let rotary: Bool
    public let shadow: Bool
    public let additive: Bool
    public let outline: Bool
    public let origin: GMLuaFontOrigin
    public let hasPlatformFontBacking: Bool
}

public enum GMLuaTextMeasurementFidelity: String, Sendable, Equatable {
    /// Deterministic layout-only estimate. It is not UIKit/CoreText glyph
    /// measurement and must not be reported as pixel-exact rendering output.
    case logicalEstimate
    case platformGlyphMetrics
}

public struct GMLuaTextMeasurement: Sendable, Equatable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Host boundary for replacing deterministic layout estimates with the real
/// iPad text backend without changing GLua's surface API.
public protocol GMLuaTextMeasurer: Sendable {
    var fidelity: GMLuaTextMeasurementFidelity { get }
    func measure(_ text: LuaString, using font: GMLuaFontDescriptor) -> GMLuaTextMeasurement
}

public struct GMLuaLogicalTextMeasurer: GMLuaTextMeasurer {
    public init() {}

    public let fidelity = GMLuaTextMeasurementFidelity.logicalEstimate

    public func measure(
        _ text: LuaString,
        using font: GMLuaFontDescriptor
    ) -> GMLuaTextMeasurement {
        let decoded = String(decoding: text.bytes, as: UTF8.self)
        let lines = decoded.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        let lineCount = max(1, lines.count)
        let longestLine = lines.map { $0.count }.max() ?? 0
        // This cell-width approximation is deliberately simple and stable.
        // UIKit/CoreText injection owns kerning, fallback glyphs, blur, and
        // outline expansion when platformGlyphMetrics becomes available.
        let width = Int(ceil(Double(longestLine * font.size) * 0.5))
        return GMLuaTextMeasurement(
            width: width,
            height: lineCount * font.size
        )
    }
}

/// State retained by the client/menu portion of GLua's `surface` API.
///
/// Texture IDs and fonts are logical descriptors only. Resolving VMT/VTF
/// assets, rasterizing glyphs, and submitting draw commands to Metal are
/// deliberately outside this layer.
public final class GMLuaSurfaceCommandState: @unchecked Sendable {
    private let lock = NSLock()
    private var textureIDs: [LuaString: Int] = [:]
    private var nextTextureID = 1
    private var selectedTexture: Int?
    private var fontDescriptors: [LuaString: GMLuaFontDescriptor] = [:]
    private var customFontKeys: Set<LuaString> = []
    private var selectedFontKey: LuaString?
    private let textMeasurer: any GMLuaTextMeasurer

    fileprivate init(textMeasurer: any GMLuaTextMeasurer) {
        self.textMeasurer = textMeasurer
        installBuiltInFontDescriptors()
        selectedFontKey = Self.canonicalFontName("Default")
    }

    public var selectedTextureID: Int? {
        lock.lock()
        defer { lock.unlock() }
        return selectedTexture
    }

    public var allocatedTextureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return textureIDs.count
    }

    public var customFontCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return customFontKeys.count
    }

    public var registeredFontCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return fontDescriptors.count
    }

    public var selectedFontName: LuaString? {
        lock.lock()
        defer { lock.unlock() }
        guard let selectedFontKey else { return nil }
        return fontDescriptors[selectedFontKey]?.name
    }

    public var textMeasurementFidelity: GMLuaTextMeasurementFidelity {
        textMeasurer.fidelity
    }

    public func fontDescriptor(named name: LuaString) -> GMLuaFontDescriptor? {
        lock.lock()
        defer { lock.unlock() }
        return fontDescriptors[Self.canonicalFontName(name)]
    }

    public func measureText(_ text: LuaString) throws -> GMLuaTextMeasurement {
        let descriptor: GMLuaFontDescriptor
        lock.lock()
        if let selectedFontKey, let selected = fontDescriptors[selectedFontKey] {
            descriptor = selected
            lock.unlock()
        } else {
            lock.unlock()
            throw LuaError.runtime("surface.GetTextSize called without a selected font")
        }
        return textMeasurer.measure(text, using: descriptor)
    }

    fileprivate func textureID(for name: LuaString) throws -> Int {
        lock.lock()
        defer { lock.unlock() }

        if let existing = textureIDs[name] {
            return existing
        }
        guard nextTextureID <= Int(Int32.max) else {
            throw LuaError.runtime("surface texture ID space exhausted")
        }
        let identifier = nextTextureID
        nextTextureID += 1
        textureIDs[name] = identifier
        return identifier
    }

    fileprivate func selectTexture(_ identifier: Int) {
        lock.lock()
        selectedTexture = identifier
        lock.unlock()
    }

    fileprivate func registerFont(_ descriptor: GMLuaFontDescriptor) {
        let key = Self.canonicalFontName(descriptor.name)
        lock.lock()
        fontDescriptors[key] = descriptor
        customFontKeys.insert(key)
        lock.unlock()
    }

    fileprivate func selectFont(_ name: LuaString) throws {
        let key = Self.canonicalFontName(name)
        lock.lock()
        guard fontDescriptors[key] != nil else {
            lock.unlock()
            throw LuaError.runtime(
                "surface.SetFont: invalid font '\(name.utf8String)'"
            )
        }
        selectedFontKey = key
        lock.unlock()
    }

    private func installBuiltInFontDescriptors() {
        for (name, size) in Self.builtInFontSizes {
            let luaName = LuaString(name)
            fontDescriptors[Self.canonicalFontName(luaName)] = GMLuaFontDescriptor(
                name: luaName,
                font: "Arial",
                extended: false,
                size: size,
                weight: 500,
                blurSize: 0,
                scanlines: 0,
                antialias: true,
                underline: false,
                italic: false,
                strikeout: false,
                symbol: false,
                rotary: false,
                shadow: false,
                additive: false,
                outline: false,
                origin: .builtInUnresolved,
                hasPlatformFontBacking: false
            )
        }
    }

    /// Publicly documented ClientScheme/Derma font names. Exact platform face
    /// metadata is unresolved; named numeric fonts retain their documented
    /// height while the remaining logical descriptors use FontData's 13px
    /// default until a real scheme parser/text backend is connected.
    private static let builtInFontSizes: [String: Int] = [
        "BudgetLabel": 13,
        "CenterPrintText": 13,
        "ChatFont": 13,
        "CloseCaption_Bold": 13,
        "CloseCaption_BoldItalic": 13,
        "CloseCaption_Italic": 13,
        "CloseCaption_Normal": 13,
        "CreditsOutroText": 13,
        "CreditsText": 13,
        "DebugFixed": 13,
        "DebugFixedSmall": 13,
        "DebugOverlay": 13,
        "Default": 13,
        "DefaultFixed": 13,
        "DefaultFixedDropShadow": 13,
        "DefaultSmall": 13,
        "DefaultUnderline": 13,
        "DefaultVerySmall": 13,
        "HudDefault": 13,
        "HudHintTextLarge": 13,
        "HudHintTextSmall": 13,
        "HudSelectionNumbers": 13,
        "HudSelectionText": 13,
        "TargetID": 13,
        "TargetIDSmall": 13,
        "Trebuchet18": 18,
        "Trebuchet24": 24,
        "ClientTitleFont": 13,
        "CreditsLogo": 13,
        "CreditsOutroLogos": 13,
        "Crosshairs": 13,
        "HDRDemoText": 13,
        "HudNumbers": 13,
        "HudNumbersGlow": 13,
        "HudNumbersSmall": 13,
        "Marlett": 13,
        "QuickInfo": 13,
        "WeaponIcons": 13,
        "WeaponIconsSelected": 13,
        "WeaponIconsSmall": 13,
        "HL2MPTypeDeath": 13,
        "DermaDefault": 13,
        "DermaDefaultBold": 13,
        "DermaLarge": 32,
        "GModNotify": 13
    ]

    /// Source's font-name dictionaries are ASCII case-insensitive. Preserve
    /// arbitrary non-ASCII Lua bytes and fold only A-Z so behavior is stable
    /// across Windows and iPad locales.
    private static func canonicalFontName(_ name: LuaString) -> LuaString {
        LuaString(bytes: name.bytes.map { byte in
            (65...90).contains(byte) ? byte + 32 : byte
        })
    }
}

/// Installs the client/menu logical surface boundary used by draw.lua and the
/// Base/Sandbox UI bootstrap.
public enum GMLuaSurface {
    @discardableResult
    public static func install(
        into state: LuaState,
        textMeasurer: any GMLuaTextMeasurer = GMLuaLogicalTextMeasurer()
    ) throws -> GMLuaSurfaceCommandState {
        let commandState = GMLuaSurfaceCommandState(textMeasurer: textMeasurer)
        let surfaceTable: LuaTable
        if case let .table(existing) = state.getGlobal("surface") {
            surfaceTable = existing
        } else {
            surfaceTable = LuaTable()
        }

        let getTextureID = LuaNativeFunctionBox(
            { [commandState] arguments in
                guard let first = arguments.first, case let .string(name) = first else {
                    throw LuaError.runtime("bad argument #1 to 'GetTextureID' (string expected)")
                }
                return [.number(Double(try commandState.textureID(for: name)))]
            },
            debugName: "surface.GetTextureID"
        )
        try state.setRawTableValue(
            .nativeFunction(getTextureID),
            for: .string("GetTextureID"),
            in: surfaceTable
        )

        let setTexture = LuaNativeFunctionBox(
            { [commandState] arguments in
                guard let first = arguments.first, case let .number(rawIdentifier) = first else {
                    throw LuaError.runtime("bad argument #1 to 'SetTexture' (number expected)")
                }
                let truncated = rawIdentifier.rounded(.towardZero)
                guard truncated.isFinite,
                      truncated >= Double(Int32.min),
                      truncated <= Double(Int32.max) else {
                    throw LuaError.runtime("bad argument #1 to 'SetTexture' (valid texture ID expected)")
                }
                commandState.selectTexture(Int(truncated))
                return []
            },
            debugName: "surface.SetTexture"
        )
        try state.setRawTableValue(
            .nativeFunction(setTexture),
            for: .string("SetTexture"),
            in: surfaceTable
        )

        let createFont = LuaNativeFunctionBox(
            { [unowned state, commandState] arguments in
                guard let first = arguments.first, case let .string(name) = first else {
                    throw LuaError.runtime("bad argument #1 to 'CreateFont' (string expected)")
                }
                guard !name.isEmpty else {
                    throw LuaError.runtime("bad argument #1 to 'CreateFont' (non-empty string expected)")
                }
                guard arguments.count >= 2, case let .table(data) = arguments[1] else {
                    throw LuaError.runtime("bad argument #2 to 'CreateFont' (table expected)")
                }
                let descriptor = try fontDescriptor(name: name, data: data, state: state)
                commandState.registerFont(descriptor)
                return []
            },
            debugName: "surface.CreateFont"
        )
        try state.setRawTableValue(
            .nativeFunction(createFont),
            for: .string("CreateFont"),
            in: surfaceTable
        )

        let setFont = LuaNativeFunctionBox(
            { [commandState] arguments in
                guard let first = arguments.first, case let .string(name) = first else {
                    throw LuaError.runtime("bad argument #1 to 'SetFont' (string expected)")
                }
                try commandState.selectFont(name)
                return []
            },
            debugName: "surface.SetFont"
        )
        try state.setRawTableValue(
            .nativeFunction(setFont),
            for: .string("SetFont"),
            in: surfaceTable
        )

        let getTextSize = LuaNativeFunctionBox(
            { [commandState] arguments in
                guard let first = arguments.first, case let .string(text) = first else {
                    throw LuaError.runtime("bad argument #1 to 'GetTextSize' (string expected)")
                }
                let measurement = try commandState.measureText(text)
                return [
                    .number(Double(measurement.width)),
                    .number(Double(measurement.height))
                ]
            },
            debugName: "surface.GetTextSize"
        )
        try state.setRawTableValue(
            .nativeFunction(getTextSize),
            for: .string("GetTextSize"),
            in: surfaceTable
        )

        state.setGlobal("surface", value: .table(surfaceTable))
        return commandState
    }

    private static func fontDescriptor(
        name: LuaString,
        data: LuaTable,
        state: LuaState
    ) throws -> GMLuaFontDescriptor {
        GMLuaFontDescriptor(
            name: name,
            font: try stringField("font", default: "Arial", data: data, state: state),
            extended: try booleanField("extended", default: false, data: data, state: state),
            size: try integerField(
                "size", default: 13, range: 4...255, data: data, state: state
            ),
            weight: try integerField(
                "weight", default: 500, range: Int(Int32.min)...Int(Int32.max),
                data: data, state: state
            ),
            blurSize: try integerField(
                "blursize", default: 0, range: 0...80, data: data, state: state
            ),
            scanlines: try integerField(
                "scanlines", default: 0, range: Int(Int32.min)...Int(Int32.max),
                data: data, state: state
            ),
            antialias: try booleanField("antialias", default: true, data: data, state: state),
            underline: try booleanField("underline", default: false, data: data, state: state),
            italic: try booleanField("italic", default: false, data: data, state: state),
            strikeout: try booleanField("strikeout", default: false, data: data, state: state),
            symbol: try booleanField("symbol", default: false, data: data, state: state),
            rotary: try booleanField("rotary", default: false, data: data, state: state),
            shadow: try booleanField("shadow", default: false, data: data, state: state),
            additive: try booleanField("additive", default: false, data: data, state: state),
            outline: try booleanField("outline", default: false, data: data, state: state),
            origin: .customUnresolved,
            hasPlatformFontBacking: false
        )
    }

    private static func rawField(
        _ name: String,
        data: LuaTable,
        state: LuaState
    ) throws -> LuaValue {
        try state.rawTableValue(for: .string(LuaString(name)), in: data)
    }

    private static func stringField(
        _ name: String,
        default defaultValue: LuaString,
        data: LuaTable,
        state: LuaState
    ) throws -> LuaString {
        switch try rawField(name, data: data, state: state) {
        case .nilValue:
            return defaultValue
        case let .string(value):
            guard value.count <= 31 else {
                throw LuaError.runtime("FontData.\(name) exceeds the 31-byte engine limit")
            }
            return value
        default:
            throw LuaError.runtime("FontData.\(name) must be a string")
        }
    }

    private static func booleanField(
        _ name: String,
        default defaultValue: Bool,
        data: LuaTable,
        state: LuaState
    ) throws -> Bool {
        switch try rawField(name, data: data, state: state) {
        case .nilValue:
            return defaultValue
        case let .boolean(value):
            return value
        default:
            throw LuaError.runtime("FontData.\(name) must be a boolean")
        }
    }

    private static func integerField(
        _ name: String,
        default defaultValue: Int,
        range: ClosedRange<Int>,
        data: LuaTable,
        state: LuaState
    ) throws -> Int {
        switch try rawField(name, data: data, state: state) {
        case .nilValue:
            return defaultValue
        case let .number(value):
            let truncated = value.rounded(.towardZero)
            guard truncated.isFinite,
                  truncated >= Double(Int.min),
                  truncated <= Double(Int.max) else {
                throw LuaError.runtime("FontData.\(name) must be a finite integer")
            }
            return min(max(Int(truncated), range.lowerBound), range.upperBound)
        default:
            throw LuaError.runtime("FontData.\(name) must be a number")
        }
    }
}
