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

public struct GMLuaSurfaceColor: Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

public enum GMLuaSurfaceDrawCommand: Sendable, Equatable {
    case rectangle(
        frame: GMLuaPanelRect,
        color: GMLuaSurfaceColor,
        clip: GMLuaPanelRect
    )
    case texturedRectangle(
        frame: GMLuaPanelRect,
        uv: GMLuaPanelRect,
        textureName: LuaString,
        color: GMLuaSurfaceColor,
        clip: GMLuaPanelRect
    )
    case text(
        value: LuaString,
        position: GMLuaCursorPosition,
        font: GMLuaFontDescriptor,
        color: GMLuaSurfaceColor,
        clip: GMLuaPanelRect
    )
}

public struct GMLuaSurfaceCommandCaptureDiagnostics: Sendable, Equatable {
    public let attemptedCommandCount: Int
    public let retainedCommandCount: Int
    public let droppedCommandCount: Int
    public let estimatedRetainedByteCount: Int
    public let maximumCommandCount: Int
    public let maximumEstimatedByteCount: Int

    public var overflowed: Bool { droppedCommandCount > 0 }
}

/// Persistent surface registries cannot silently substitute a different
/// texture or font without breaking GLua identity semantics. Once a registry
/// is full, only a new unique registration is rejected; existing handles and
/// same-name font redefinitions remain valid.
public enum GMLuaSurfacePersistentResourceOverflowPolicy: String, Sendable, Equatable {
    case rejectNewUniqueRegistrationWithLuaRuntimeError
}

public struct GMLuaSurfacePersistentResourceDiagnostics: Sendable, Equatable {
    public let allocatedTextureCount: Int
    public let maximumTextureCount: Int
    public let registeredFontCount: Int
    public let maximumRegisteredFontCount: Int
    public let customFontCount: Int
    public let maximumCustomFontCount: Int
    public let rejectedTextureRegistrationCount: Int
    public let rejectedFontRegistrationCount: Int
    public let overflowPolicy: GMLuaSurfacePersistentResourceOverflowPolicy

    public var rejectedRegistrationCount: Int {
        let sum = rejectedTextureRegistrationCount.addingReportingOverflow(
            rejectedFontRegistrationCount
        )
        return sum.overflow ? Int.max : sum.partialValue
    }

    public var overflowed: Bool { rejectedRegistrationCount > 0 }
}

public struct GMLuaSurfaceFrameSnapshot: Sendable, Equatable {
    public let viewportWidth: Int
    public let viewportHeight: Int
    public let commands: [GMLuaSurfaceDrawCommand]
    public let textureCount: Int
    public let captureDiagnostics: GMLuaSurfaceCommandCaptureDiagnostics

    public var drawCallCount: Int { commands.count }
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

/// Converts Source's `FontData.size` contract (font tall in pixels) to and
/// from platform text metrics. Apple text APIs consume point sizes, whose
/// ascent/descent/leading total is not generally equal to that point size.
public enum GMLuaSourceFontTallMetrics {
    public static func scaledPointSize(
        unscaledPointSize: Double,
        unscaledLineHeight: Double,
        requestedTall: Int
    ) -> Double {
        let tall = Double(max(1, requestedTall))
        guard unscaledPointSize.isFinite,
              unscaledPointSize > 0,
              unscaledLineHeight.isFinite,
              unscaledLineHeight > 0 else {
            return tall
        }
        let scaled = unscaledPointSize * tall / unscaledLineHeight
        return scaled.isFinite && scaled > 0 ? scaled : tall
    }

    public static func exactTextHeight(
        lineCount: Int,
        requestedTall: Int
    ) -> Int {
        let normalizedLineCount = max(1, lineCount)
        let normalizedTall = max(1, requestedTall)
        let (height, overflow) = normalizedLineCount
            .multipliedReportingOverflow(by: normalizedTall)
        return overflow ? Int.max : height
    }
}

/// State retained by the client/menu portion of GLua's `surface` API.
///
/// Texture IDs and fonts are logical descriptors only. Resolving VMT/VTF
/// assets, rasterizing glyphs, and submitting draw commands to Metal are
/// deliberately outside this layer.
public final class GMLuaSurfaceCommandState: @unchecked Sendable {
    /// Large enough for the stock Spawn Menu with ample headroom, while still
    /// preventing an addon Paint loop from allocating an unbounded command
    /// stream or issuing an unbounded number of Metal draws.
    public static let defaultMaximumDrawCommandCount = 16_384
    public static let defaultMaximumEstimatedCommandByteCount = 8 * 1_024 * 1_024
    /// Persistent registries deliberately have separate limits from a frame's
    /// draw-command budget. These defaults leave ample room for stock Derma
    /// while bounding a long-running addon's unique-name churn.
    public static let defaultMaximumPersistentTextureCount = 16_384
    public static let defaultMaximumCustomFontCount = 4_096

    private struct PaintContext {
        let originX: Double
        let originY: Double
        let clip: GMLuaPanelRect
        let alphaMultiplier: Double
    }

    private let lock = NSLock()
    private var textureIDs: [LuaString: Int] = [:]
    private var textureNames: [Int: LuaString] = [:]
    private var nextTextureID = 1
    private var selectedTexture: Int?
    private var fontDescriptors: [LuaString: GMLuaFontDescriptor] = [:]
    private var customFontKeys: Set<LuaString> = []
    private var builtInFontDescriptorCount = 0
    private var rejectedTextureRegistrationCount = 0
    private var rejectedFontRegistrationCount = 0
    private var selectedFontKey: LuaString?
    private var drawColor = GMLuaSurfaceColor(red: 255, green: 255, blue: 255, alpha: 255)
    private var textColor = GMLuaSurfaceColor(red: 255, green: 255, blue: 255, alpha: 255)
    private var textPosition = GMLuaCursorPosition(x: 0, y: 0)
    private var contexts: [PaintContext] = []
    private var commands: [GMLuaSurfaceDrawCommand] = []
    private var attemptedCommandCount = 0
    private var droppedCommandCount = 0
    private var estimatedCommandByteCount = 0
    private var viewportWidth = 0
    private var viewportHeight = 0
    private var clippingDisabled = false
    private let textMeasurer: any GMLuaTextMeasurer
    private let maximumDrawCommandCount: Int
    private let maximumEstimatedCommandByteCount: Int
    private let maximumPersistentTextureCount: Int
    private let maximumCustomFontCount: Int

    fileprivate init(
        textMeasurer: any GMLuaTextMeasurer,
        maximumDrawCommandCount: Int,
        maximumEstimatedCommandByteCount: Int,
        maximumPersistentTextureCount: Int,
        maximumCustomFontCount: Int
    ) {
        self.textMeasurer = textMeasurer
        self.maximumDrawCommandCount = max(0, maximumDrawCommandCount)
        self.maximumEstimatedCommandByteCount = max(
            0,
            maximumEstimatedCommandByteCount
        )
        self.maximumPersistentTextureCount = max(
            0,
            maximumPersistentTextureCount
        )
        self.maximumCustomFontCount = max(0, maximumCustomFontCount)
        installBuiltInFontDescriptors()
        builtInFontDescriptorCount = fontDescriptors.count
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

    /// Cumulative lifetime diagnostics. Unlike command-capture diagnostics,
    /// these counts intentionally survive `beginFrame` because the underlying
    /// texture/font registries survive it too.
    public var persistentResourceDiagnostics: GMLuaSurfacePersistentResourceDiagnostics {
        lock.lock()
        defer { lock.unlock() }
        return GMLuaSurfacePersistentResourceDiagnostics(
            allocatedTextureCount: textureIDs.count,
            maximumTextureCount: maximumPersistentTextureCount,
            registeredFontCount: fontDescriptors.count,
            maximumRegisteredFontCount: Self.saturatingAdd(
                builtInFontDescriptorCount,
                maximumCustomFontCount
            ),
            customFontCount: customFontKeys.count,
            maximumCustomFontCount: maximumCustomFontCount,
            rejectedTextureRegistrationCount: rejectedTextureRegistrationCount,
            rejectedFontRegistrationCount: rejectedFontRegistrationCount,
            overflowPolicy: .rejectNewUniqueRegistrationWithLuaRuntimeError
        )
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

    /// Measures with a named font without changing `surface`'s selected font.
    /// VGUI controls own their font selection independently from the immediate
    /// mode surface API, so consulting a Label must not leak into later draws.
    public func measureText(
        _ text: LuaString,
        usingFontNamed name: LuaString,
        fallbackFontNamed fallbackName: LuaString? = nil
    ) throws -> GMLuaTextMeasurement {
        let descriptor: GMLuaFontDescriptor
        lock.lock()
        if let selected = fontDescriptors[Self.canonicalFontName(name)] {
            descriptor = selected
            lock.unlock()
        } else if let fallbackName,
                  let fallback = fontDescriptors[Self.canonicalFontName(fallbackName)] {
            descriptor = fallback
            lock.unlock()
        } else {
            lock.unlock()
            throw LuaError.runtime(
                "surface text measurement: invalid font '\(name.utf8String)'"
            )
        }
        return textMeasurer.measure(text, using: descriptor)
    }

    public func beginFrame(viewportWidth: Int, viewportHeight: Int) {
        lock.lock()
        self.viewportWidth = max(0, viewportWidth)
        self.viewportHeight = max(0, viewportHeight)
        commands.removeAll(keepingCapacity: true)
        attemptedCommandCount = 0
        droppedCommandCount = 0
        estimatedCommandByteCount = 0
        contexts.removeAll(keepingCapacity: true)
        clippingDisabled = false
        lock.unlock()
    }

    public var frameSnapshot: GMLuaSurfaceFrameSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return GMLuaSurfaceFrameSnapshot(
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            commands: commands,
            textureCount: textureIDs.count,
            captureDiagnostics: GMLuaSurfaceCommandCaptureDiagnostics(
                attemptedCommandCount: attemptedCommandCount,
                retainedCommandCount: commands.count,
                droppedCommandCount: droppedCommandCount,
                estimatedRetainedByteCount: estimatedCommandByteCount,
                maximumCommandCount: maximumDrawCommandCount,
                maximumEstimatedByteCount: maximumEstimatedCommandByteCount
            )
        )
    }

    func pushPanelContext(frame: GMLuaPanelRect, clip: GMLuaPanelRect, alpha: Double) {
        lock.lock()
        contexts.append(PaintContext(
            originX: frame.x,
            originY: frame.y,
            clip: clip,
            alphaMultiplier: min(1, max(0, alpha / 255))
        ))
        lock.unlock()
    }

    func popPanelContext() {
        lock.lock()
        if !contexts.isEmpty { contexts.removeLast() }
        lock.unlock()
    }

    func appendPanelText(_ panel: GMLuaPanelRenderSnapshot) {
        guard !panel.text.isEmpty else { return }
        lock.lock()
        let descriptor = fontDescriptors[Self.canonicalFontName(panel.fontName)]
            ?? fontDescriptors[Self.canonicalFontName("Default")]
        guard let descriptor else {
            lock.unlock()
            return
        }
        let color = panel.foregroundColor.map {
            GMLuaSurfaceColor(red: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha)
        } ?? GMLuaSurfaceColor(red: 230, green: 230, blue: 230, alpha: 255)
        let measurement = textMeasurer.measure(panel.text, using: descriptor)
        // Valve Label::Paint applies the horizontal inset from the aligned
        // edge (add for west, subtract for east, ignore for centered text),
        // and always adds the vertical inset after vertical alignment.
        // Integer center division truncates toward zero. Preserve negative
        // aligned origins so oversized text clips at the panel edge instead
        // of being incorrectly pinned to its top-left.
        let horizontal: Double
        switch panel.contentAlignment {
        case 2, 5, 8:
            horizontal = (
                (panel.frame.width - Double(measurement.width)) * 0.5
            ).rounded(.towardZero)
        case 3, 6, 9:
            horizontal = panel.frame.width - Double(measurement.width)
                - Double(panel.textInsetX)
        default:
            horizontal = Double(panel.textInsetX)
        }
        let vertical: Double
        switch panel.contentAlignment {
        case 4, 5, 6:
            vertical = (
                (panel.frame.height - Double(measurement.height)) * 0.5
            ).rounded(.towardZero)
        case 1, 2, 3:
            vertical = panel.frame.height - Double(measurement.height)
        default:
            vertical = 0
        }
        let position = GMLuaCursorPosition(
            x: panel.frame.x + horizontal,
            y: panel.frame.y + vertical + Double(panel.textInsetY)
        )
        var pendingCommands: [GMLuaSurfaceDrawCommand] = []
        if let shadow = panel.expensiveShadow, shadow.distance != 0 {
            let shadowColor = GMLuaSurfaceColor(
                red: shadow.color.red,
                green: shadow.color.green,
                blue: shadow.color.blue,
                alpha: shadow.color.alpha
            )
            pendingCommands.append(.text(
                value: panel.text,
                position: GMLuaCursorPosition(
                    x: position.x + shadow.distance,
                    y: position.y + shadow.distance
                ),
                font: descriptor,
                color: multipliedAlpha(shadowColor, panel.alpha / 255),
                clip: panel.clipRect
            ))
        }
        pendingCommands.append(.text(
            value: panel.text,
            position: position,
            font: descriptor,
            color: multipliedAlpha(color, panel.alpha / 255),
            clip: panel.clipRect
        ))
        appendCommandsWithinBudget(pendingCommands)
        lock.unlock()
    }

    func appendPanelImage(_ panel: GMLuaPanelRenderSnapshot) throws {
        guard let imageName = panel.imageName else { return }
        try selectTexture(named: imageName)
        try appendTexturedRectangle(
            x: 0,
            y: 0,
            width: panel.frame.width,
            height: panel.frame.height,
            uv: GMLuaPanelRect(x: 0, y: 0, width: 1, height: 1)
        )
    }

    fileprivate func textureID(for name: LuaString) throws -> Int {
        lock.lock()
        defer { lock.unlock() }

        if let existing = textureIDs[name] {
            return existing
        }
        guard textureIDs.count < maximumPersistentTextureCount else {
            rejectedTextureRegistrationCount = Self.saturatingAdd(
                rejectedTextureRegistrationCount,
                1
            )
            throw LuaError.runtime(
                "surface.GetTextureID: persistent texture registry limit " +
                    "(\(maximumPersistentTextureCount)) exceeded"
            )
        }
        guard nextTextureID <= Int(Int32.max) else {
            throw LuaError.runtime("surface texture ID space exhausted")
        }
        let identifier = nextTextureID
        nextTextureID += 1
        textureIDs[name] = identifier
        textureNames[identifier] = name
        return identifier
    }

    fileprivate func selectTexture(_ identifier: Int) {
        lock.lock()
        selectedTexture = identifier
        lock.unlock()
    }

    fileprivate func selectTexture(named name: LuaString) throws {
        let identifier = try textureID(for: name)
        lock.lock()
        selectedTexture = identifier
        lock.unlock()
    }

    fileprivate func setDrawColor(_ color: GMLuaSurfaceColor) {
        lock.lock()
        drawColor = color
        lock.unlock()
    }

    fileprivate func setTextColor(_ color: GMLuaSurfaceColor) {
        lock.lock()
        textColor = color
        lock.unlock()
    }

    fileprivate func setTextPosition(x: Double, y: Double) {
        lock.lock()
        textPosition = GMLuaCursorPosition(x: x, y: y)
        lock.unlock()
    }

    fileprivate func setClippingDisabled(_ disabled: Bool) -> Bool {
        lock.lock()
        let previous = clippingDisabled
        clippingDisabled = disabled
        lock.unlock()
        return previous
    }

    fileprivate func appendRectangle(x: Double, y: Double, width: Double, height: Double) {
        lock.lock()
        guard let context = contexts.last, width > 0, height > 0 else {
            lock.unlock()
            return
        }
        appendCommandsWithinBudget([.rectangle(
            frame: GMLuaPanelRect(
                x: context.originX + x,
                y: context.originY + y,
                width: width,
                height: height
            ),
            color: multipliedAlpha(drawColor, context.alphaMultiplier),
            clip: effectiveClip(context)
        )])
        lock.unlock()
    }

    fileprivate func appendTexturedRectangle(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        uv: GMLuaPanelRect
    ) throws {
        lock.lock()
        guard let context = contexts.last, width > 0, height > 0,
              let selectedTexture, let textureName = textureNames[selectedTexture] else {
            lock.unlock()
            return
        }
        appendCommandsWithinBudget([.texturedRectangle(
            frame: GMLuaPanelRect(
                x: context.originX + x,
                y: context.originY + y,
                width: width,
                height: height
            ),
            uv: uv,
            textureName: textureName,
            color: multipliedAlpha(drawColor, context.alphaMultiplier),
            clip: effectiveClip(context)
        )])
        lock.unlock()
    }

    fileprivate func appendText(_ value: LuaString) throws {
        let descriptor: GMLuaFontDescriptor
        lock.lock()
        guard let context = contexts.last,
              let selectedFontKey,
              let selected = fontDescriptors[selectedFontKey] else {
            lock.unlock()
            throw LuaError.runtime("surface.DrawText called without a selected font or panel paint context")
        }
        descriptor = selected
        appendCommandsWithinBudget([.text(
            value: value,
            position: GMLuaCursorPosition(
                x: context.originX + textPosition.x,
                y: context.originY + textPosition.y
            ),
            font: descriptor,
            color: multipliedAlpha(textColor, context.alphaMultiplier),
            clip: effectiveClip(context)
        )])
        lock.unlock()
    }

    private func effectiveClip(_ context: PaintContext) -> GMLuaPanelRect {
        if clippingDisabled {
            return GMLuaPanelRect(
                x: 0,
                y: 0,
                width: Double(viewportWidth),
                height: Double(viewportHeight)
            )
        }
        return context.clip
    }

    private func multipliedAlpha(_ color: GMLuaSurfaceColor, _ multiplier: Double) -> GMLuaSurfaceColor {
        GMLuaSurfaceColor(
            red: color.red,
            green: color.green,
            blue: color.blue,
            alpha: color.alpha * min(1, max(0, multiplier))
        )
    }

    /// Requires `lock` to be held. A multi-command logical operation (for
    /// example Label shadow + main glyphs) is admitted atomically so overflow
    /// never leaves only the decorative half of the operation in the frame.
    private func appendCommandsWithinBudget(
        _ candidates: [GMLuaSurfaceDrawCommand]
    ) {
        guard !candidates.isEmpty else { return }
        attemptedCommandCount = Self.saturatingAdd(
            attemptedCommandCount,
            candidates.count
        )

        var candidateBytes = 0
        for candidate in candidates {
            candidateBytes = Self.saturatingAdd(
                candidateBytes,
                Self.estimatedByteCount(of: candidate)
            )
        }
        let countFits = candidates.count <= maximumDrawCommandCount &&
            commands.count <= maximumDrawCommandCount - candidates.count
        let bytesFit = candidateBytes <= maximumEstimatedCommandByteCount &&
            estimatedCommandByteCount <=
                maximumEstimatedCommandByteCount - candidateBytes
        guard countFits, bytesFit else {
            droppedCommandCount = Self.saturatingAdd(
                droppedCommandCount,
                candidates.count
            )
            return
        }
        commands.append(contentsOf: candidates)
        estimatedCommandByteCount += candidateBytes
    }

    private static func estimatedByteCount(
        of command: GMLuaSurfaceDrawCommand
    ) -> Int {
        switch command {
        case .rectangle:
            return 128
        case let .texturedRectangle(_, _, textureName, _, _):
            return saturatingAdd(160, textureName.count)
        case let .text(value, _, font, _, _):
            return saturatingAdd(
                192,
                saturatingAdd(
                    value.count,
                    saturatingAdd(font.name.count, font.font.count)
                )
            )
        }
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let sum = lhs.addingReportingOverflow(rhs)
        return sum.overflow ? Int.max : sum.partialValue
    }

    fileprivate func registerFont(_ descriptor: GMLuaFontDescriptor) throws {
        let key = Self.canonicalFontName(descriptor.name)
        lock.lock()
        if customFontKeys.contains(key) {
            fontDescriptors[key] = descriptor
            lock.unlock()
            return
        }
        guard customFontKeys.count < maximumCustomFontCount else {
            rejectedFontRegistrationCount = Self.saturatingAdd(
                rejectedFontRegistrationCount,
                1
            )
            lock.unlock()
            throw LuaError.runtime(
                "surface.CreateFont: persistent custom font registry limit " +
                    "(\(maximumCustomFontCount)) exceeded"
            )
        }
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
        textMeasurer: any GMLuaTextMeasurer = GMLuaLogicalTextMeasurer(),
        maximumDrawCommandCount: Int =
            GMLuaSurfaceCommandState.defaultMaximumDrawCommandCount,
        maximumEstimatedCommandByteCount: Int =
            GMLuaSurfaceCommandState.defaultMaximumEstimatedCommandByteCount,
        maximumPersistentTextureCount: Int =
            GMLuaSurfaceCommandState.defaultMaximumPersistentTextureCount,
        maximumCustomFontCount: Int =
            GMLuaSurfaceCommandState.defaultMaximumCustomFontCount
    ) throws -> GMLuaSurfaceCommandState {
        let commandState = GMLuaSurfaceCommandState(
            textMeasurer: textMeasurer,
            maximumDrawCommandCount: maximumDrawCommandCount,
            maximumEstimatedCommandByteCount: maximumEstimatedCommandByteCount,
            maximumPersistentTextureCount: maximumPersistentTextureCount,
            maximumCustomFontCount: maximumCustomFontCount
        )
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
                try commandState.registerFont(descriptor)
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

        let setDrawColor = LuaNativeFunctionBox(
            { [unowned state, commandState] arguments in
                commandState.setDrawColor(try surfaceColor(arguments, state: state, function: "SetDrawColor"))
                return []
            },
            debugName: "surface.SetDrawColor"
        )
        let setTextColor = LuaNativeFunctionBox(
            { [unowned state, commandState] arguments in
                commandState.setTextColor(try surfaceColor(arguments, state: state, function: "SetTextColor"))
                return []
            },
            debugName: "surface.SetTextColor"
        )
        let drawRect = LuaNativeFunctionBox(
            { [commandState] arguments in
                let values = try finiteNumbers(arguments, count: 4, function: "DrawRect")
                commandState.appendRectangle(
                    x: values[0], y: values[1], width: values[2], height: values[3]
                )
                return []
            },
            debugName: "surface.DrawRect"
        )
        let setTextPos = LuaNativeFunctionBox(
            { [commandState] arguments in
                let values = try finiteNumbers(arguments, count: 2, function: "SetTextPos")
                commandState.setTextPosition(x: values[0], y: values[1])
                return []
            },
            debugName: "surface.SetTextPos"
        )
        let drawText = LuaNativeFunctionBox(
            { [commandState] arguments in
                guard let first = arguments.first, case let .string(value) = first else {
                    throw LuaError.runtime("bad argument #1 to 'DrawText' (string expected)")
                }
                try commandState.appendText(value)
                return []
            },
            debugName: "surface.DrawText"
        )
        let drawTexturedRect = LuaNativeFunctionBox(
            { [commandState] arguments in
                let values = try finiteNumbers(arguments, count: 4, function: "DrawTexturedRect")
                try commandState.appendTexturedRectangle(
                    x: values[0], y: values[1], width: values[2], height: values[3],
                    uv: GMLuaPanelRect(x: 0, y: 0, width: 1, height: 1)
                )
                return []
            },
            debugName: "surface.DrawTexturedRect"
        )
        let drawTexturedRectUV = LuaNativeFunctionBox(
            { [commandState] arguments in
                let values = try finiteNumbers(arguments, count: 8, function: "DrawTexturedRectUV")
                try commandState.appendTexturedRectangle(
                    x: values[0], y: values[1], width: values[2], height: values[3],
                    uv: GMLuaPanelRect(
                        x: values[4], y: values[5],
                        width: values[6] - values[4], height: values[7] - values[5]
                    )
                )
                return []
            },
            debugName: "surface.DrawTexturedRectUV"
        )
        let setMaterial = LuaNativeFunctionBox(
            { [commandState] arguments in
                guard let first = arguments.first,
                      let descriptor = GMLuaTypeSystem.typedObject(from: first)?.payload
                        as? GMLuaMaterialDescriptor else {
                    throw LuaError.runtime("bad argument #1 to 'SetMaterial' (IMaterial expected)")
                }
                try commandState.selectTexture(named: descriptor.path)
                return []
            },
            debugName: "surface.SetMaterial"
        )
        let disableClipping = LuaNativeFunctionBox(
            { [commandState] arguments in
                guard let first = arguments.first, case let .boolean(disabled) = first else {
                    throw LuaError.runtime("bad argument #1 to 'DisableClipping' (boolean expected)")
                }
                return [.boolean(commandState.setClippingDisabled(disabled))]
            },
            debugName: "DisableClipping"
        )
        for (name, function) in [
            ("SetDrawColor", setDrawColor), ("SetTextColor", setTextColor),
            ("DrawRect", drawRect), ("SetTextPos", setTextPos),
            ("DrawText", drawText), ("DrawTexturedRect", drawTexturedRect),
            ("DrawTexturedRectUV", drawTexturedRectUV), ("SetMaterial", setMaterial),
            ("DisableClipping", disableClipping)
        ] {
            try state.setRawTableValue(
                .nativeFunction(function),
                for: .string(LuaString(name)),
                in: surfaceTable
            )
        }

        // DisableClipping is a global engine function in GMod. Keep the
        // surface alias as a compatibility convenience, but do not require
        // shipped Derma Lua to call a non-existent namespaced API.
        state.setGlobal("DisableClipping", value: .nativeFunction(disableClipping))
        state.setGlobal("surface", value: .table(surfaceTable))
        return commandState
    }

    private static func finiteNumbers(
        _ arguments: [LuaValue],
        count: Int,
        function: String
    ) throws -> [Double] {
        guard arguments.count >= count else {
            throw LuaError.runtime("bad argument count to '\(function)'")
        }
        return try (0..<count).map { index in
            guard case let .number(value) = arguments[index], value.isFinite else {
                throw LuaError.runtime(
                    "bad argument #\(index + 1) to '\(function)' (finite number expected)"
                )
            }
            return value
        }
    }

    private static func surfaceColor(
        _ arguments: [LuaValue],
        state: LuaState,
        function: String
    ) throws -> GMLuaSurfaceColor {
        if let first = arguments.first, case let .table(table) = first {
            func component(_ name: String) throws -> Double {
                guard case let .number(value) = try state.rawTableValue(
                    for: .string(LuaString(name)), in: table
                ), value.isFinite else {
                    throw LuaError.runtime("bad Color.\(name) passed to '\(function)'")
                }
                return value
            }
            return try GMLuaSurfaceColor(
                red: component("r"), green: component("g"),
                blue: component("b"), alpha: component("a")
            )
        }
        let values = try finiteNumbers(arguments, count: 3, function: function)
        let alpha: Double
        if arguments.indices.contains(3) {
            guard case let .number(value) = arguments[3], value.isFinite else {
                throw LuaError.runtime(
                    "bad argument #4 to '\(function)' (finite number expected)"
                )
            }
            alpha = value
        } else {
            alpha = 255
        }
        return GMLuaSurfaceColor(
            red: values[0], green: values[1], blue: values[2], alpha: alpha
        )
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
            guard truncated.isFinite else {
                throw LuaError.runtime("FontData.\(name) must be a finite integer")
            }
            // Clamp in Double space before converting so very large finite
            // Lua numbers cannot overflow Swift's fixed-width Int.
            let clamped = min(
                max(truncated, Double(range.lowerBound)),
                Double(range.upperBound)
            )
            return Int(clamped)
        default:
            throw LuaError.runtime("FontData.\(name) must be a number")
        }
    }
}
