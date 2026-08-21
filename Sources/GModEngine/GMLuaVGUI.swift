import Foundation
import GModLua

/// Value-only foreground color retained by the logical VGUI host.
///
/// Components intentionally remain Lua numbers. The public GLua contract does
/// not define out-of-range conversion, so this layer does not invent an 8-bit
/// clamp that could disagree with the native engine.
public struct GMLuaPanelColorSnapshot: Equatable, Sendable {
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

/// Value-only copy of `Panel:SetExpensiveShadow` state for Label controls.
/// A distance of zero retains the supplied color but disables shadow drawing;
/// that disable meaning is inferred from the stock DCategoryHeader closed-state
/// call site rather than from a separately documented getter contract.
public struct GMLuaTextShadowSnapshot: Equatable, Sendable {
    public let distance: Double
    public let color: GMLuaPanelColorSnapshot

    public init(distance: Double, color: GMLuaPanelColorSnapshot) {
        self.distance = distance
        self.color = color
    }
}

/// Inspectable logical state for an engine text panel.
///
/// This is not a renderer object. Font names are kept independently from the
/// current `surface` font, matching VGUI's per-panel font selection.
public struct GMLuaTextPanelStateSnapshot: Equatable, Sendable {
    public let panelIdentifier: Int
    public let engineClassName: String
    public let requestedClassName: String
    public let text: LuaString
    public let fontName: LuaString
    public let foregroundColor: GMLuaPanelColorSnapshot?
    public let contentAlignment: Int
    public let allowsNonASCIICharacters: Bool
    /// Native TextEntry caret offset in decoded text characters. Non-TextEntry
    /// controls expose `nil` because they do not share this editing state.
    public let caretPosition: Int?
    public let textInsetX: Int
    public let textInsetY: Int
    public let wrapsText: Bool
    public let expensiveShadow: GMLuaTextShadowSnapshot?

    public init(
        panelIdentifier: Int,
        engineClassName: String,
        requestedClassName: String,
        text: LuaString,
        fontName: LuaString,
        foregroundColor: GMLuaPanelColorSnapshot?,
        contentAlignment: Int,
        allowsNonASCIICharacters: Bool,
        caretPosition: Int? = nil,
        textInsetX: Int = 0,
        textInsetY: Int = 0,
        wrapsText: Bool = false,
        expensiveShadow: GMLuaTextShadowSnapshot? = nil
    ) {
        self.panelIdentifier = panelIdentifier
        self.engineClassName = engineClassName
        self.requestedClassName = requestedClassName
        self.text = text
        self.fontName = fontName
        self.foregroundColor = foregroundColor
        self.contentAlignment = contentAlignment
        self.allowsNonASCIICharacters = allowsNonASCIICharacters
        self.caretPosition = caretPosition
        self.textInsetX = textInsetX
        self.textInsetY = textInsetY
        self.wrapsText = wrapsText
        self.expensiveShadow = expensiveShadow
    }
}

/// Renderer-neutral lifecycle for a native HTML panel's root document.
///
/// `loading` begins at `OpenURL`/`SetHTML`. A platform HTML renderer must
/// resolve that exact request through `resolveHTMLDocumentLoad`; the logical
/// Engine layer does not invent an immediate successful page load.
public enum GMLuaHTMLDocumentLoadState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed
}

public enum GMLuaHTMLDocumentLoadResult: Equatable, Sendable {
    case succeeded
    case failed(message: String)
}

/// One native JavaScript callback endpoint registered by stock `DHTML`.
/// The logical VGUI layer preserves registration identity; invocation and DOM
/// execution remain an HTML-renderer responsibility.
public struct GMLuaHTMLJavaScriptCallbackSnapshot: Equatable, Sendable {
    public let objectName: LuaString
    public let callbackName: LuaString

    public init(objectName: LuaString, callbackName: LuaString) {
        self.objectName = objectName
        self.callbackName = callbackName
    }
}

public struct GMLuaHTMLPanelStateSnapshot: Equatable, Sendable {
    public let panelIdentifier: Int
    public let requestedClassName: String
    public let state: GMLuaHTMLDocumentLoadState
    public let requestIdentifier: UInt64
    public let url: LuaString?
    public let html: LuaString?
    public let failureMessage: String?
    public let javascriptObjects: [LuaString]
    public let javascriptCallbacks: [GMLuaHTMLJavaScriptCallbackSnapshot]

    public init(
        panelIdentifier: Int,
        requestedClassName: String,
        state: GMLuaHTMLDocumentLoadState,
        requestIdentifier: UInt64,
        url: LuaString?,
        html: LuaString?,
        failureMessage: String?,
        javascriptObjects: [LuaString],
        javascriptCallbacks: [GMLuaHTMLJavaScriptCallbackSnapshot]
    ) {
        self.panelIdentifier = panelIdentifier
        self.requestedClassName = requestedClassName
        self.state = state
        self.requestIdentifier = requestIdentifier
        self.url = url
        self.html = html
        self.failureMessage = failureMessage
        self.javascriptObjects = javascriptObjects
        self.javascriptCallbacks = javascriptCallbacks
    }
}

/// Renderer-neutral state retained by native `ModelImage` panels.
///
/// The Engine target can preserve the exact model/skin/bodygroup request used
/// by stock `SpawnIcon`, but it has no 3D thumbnail renderer. Consumers must
/// treat `previewState == .unavailable` as an explicit compatibility boundary,
/// not as evidence that a preview bitmap was generated.
public enum GMLuaModelImagePreviewState: Equatable, Sendable {
    case unavailable
}

public struct GMLuaModelImageStateSnapshot: Equatable, Sendable {
    public let panelIdentifier: Int
    public let requestedClassName: String
    public let modelPath: LuaString?
    public let skin: Int
    public let bodyGroups: LuaString?
    public let spawnIconName: LuaString?
    public let previewState: GMLuaModelImagePreviewState

    public init(
        panelIdentifier: Int,
        requestedClassName: String,
        modelPath: LuaString?,
        skin: Int,
        bodyGroups: LuaString?,
        spawnIconName: LuaString?,
        previewState: GMLuaModelImagePreviewState
    ) {
        self.panelIdentifier = panelIdentifier
        self.requestedClassName = requestedClassName
        self.modelPath = modelPath
        self.skin = skin
        self.bodyGroups = bodyGroups
        self.spawnIconName = spawnIconName
        self.previewState = previewState
    }
}

/// One unknown VGUI method invocation observed by the native Panel boundary.
/// Merely reading a missing member does not append a diagnostic. The source
/// and line identify the Lua caller when the interpreter exposes both values.
public struct GMLuaVGUIMissingMethodDiagnostic: Equatable, Sendable {
    public let panelIdentifier: Int
    public let engineClassName: String
    public let requestedClassName: String
    public let methodName: String
    public let source: String
    public let line: Int?

    public var sourceLocation: String {
        guard let line else { return source }
        return "\(source):\(line)"
    }

    public var logLine: String {
        "[VGUI][MISSING] class=\(requestedClassName) method=\(methodName) " +
            "source=\(sourceLocation)"
    }
}

public struct GMLuaPanelRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func contains(x: Double, y: Double) -> Bool {
        x >= self.x && y >= self.y && x < self.x + width && y < self.y + height
    }

    public func intersection(_ other: GMLuaPanelRect) -> GMLuaPanelRect? {
        let minimumX = max(x, other.x)
        let minimumY = max(y, other.y)
        let maximumX = min(x + width, other.x + other.width)
        let maximumY = min(y + height, other.y + other.height)
        guard maximumX > minimumX, maximumY > minimumY else { return nil }
        return GMLuaPanelRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        )
    }
}

public enum GMLuaPanelDock: Int, Sendable, Equatable {
    case none = 0
    case fill = 1
    case left = 2
    case right = 3
    case top = 4
    case bottom = 5
}

/// Immutable renderer-facing state. A snapshot proves logical geometry exists;
/// it does not by itself claim that a drawable was submitted.
public struct GMLuaPanelRenderSnapshot: Equatable, Sendable {
    public let identifier: Int
    public let parentIdentifier: Int?
    public let engineClassName: String
    public let requestedClassName: String
    public let frame: GMLuaPanelRect
    /// Normal panel/ancestor intersection used by default native drawing and
    /// hit-testing. `Panel:NoClipping` deliberately does not widen this.
    public let clipRect: GMLuaPanelRect
    /// Clip used only while invoking this panel's Lua `Paint`/`PaintOver`.
    /// Garry's Mod's `Panel:NoClipping(true)` disables the parent-bound clip
    /// for those hooks without unclipping native Label text or pointer input.
    public let paintClipRect: GMLuaPanelRect
    public let paintClippingDisabled: Bool
    public let zPosition: Double
    public let alpha: Double
    public let mouseInputEnabled: Bool
    public let keyboardInputEnabled: Bool
    /// Raw `Panel:IsPopup` state. Popup tier ordering is applied by the
    /// registry before this value-only snapshot is emitted.
    public let isPopup: Bool
    /// Whether this panel permits the host to pass the same pointer through
    /// to the world. This value alone never synthesizes a world attack.
    public let worldClicker: Bool
    public let cursorName: String
    public let drawOnTop: Bool
    public let drawOnTopOrder: UInt64?
    public let text: LuaString
    public let fontName: LuaString
    public let foregroundColor: GMLuaPanelColorSnapshot?
    public let contentAlignment: Int
    public let textInsetX: Int
    public let textInsetY: Int
    public let wrapsText: Bool
    public let expensiveShadow: GMLuaTextShadowSnapshot?
    public let imageName: LuaString?
}

public enum GMLuaPointerPhase: Sendable, Equatable {
    case moved
    case began
    case ended
    case cancelled
    case scroll(delta: Double)
}

public struct GMLuaPointerDispatchResult: Sendable, Equatable {
    public let hitPanelIdentifier: Int?
    /// Effective WorldClicker state from the hit panel through its ancestor
    /// chain. Hosts can use it with `hitPanelIdentifier` to decide pass-through;
    /// dispatch itself does not create a world command or attack. Panel render
    /// snapshots and `Panel:IsWorldClicker` continue to expose raw local state.
    public let worldClicker: Bool
    public let callbackNames: [String]
    public let clicked: Bool
    public let doubleClicked: Bool
}

private final class GMLuaPanelValue: @unchecked Sendable {
    let identifier: Int
    let engineClassName: String
    let instanceTable = LuaTable()
    var requestedClassName: String
    var name: String
    var parentIdentifier: Int?
    var isParentedToHUD = false
    var x = 0.0
    var y = 0.0
    // Valve Panel::Init constructs the native control at 64x24 before any
    // scripted Init callback runs. Stock containers use this baseline while
    // their first deferred layout pass is still converging.
    var width = 64.0
    var height = 24.0
    var alpha = 255.0
    var isVisible = true
    var isEnabled = true
    var mouseInputEnabled = true
    var keyboardInputEnabled = true
    var isPopup = false
    var isWorldClicker = false
    // Panel:Remove invalidates the typed object immediately, but native VGUI
    // retains the panel until the following frame. This flag represents that
    // observable interval without pretending the panel is still valid.
    var isMarkedForDeletion = false
    var cursorName = "none"
    var drawOnTopOrder: UInt64?
    var paintBackgroundEnabled = true
    var paintBorderEnabled = true
    var zPosition = 0.0
    var siblingOrder: Int
    var isLayoutInvalidated = false
    var isPerformingLayout = false
    var text = LuaString(bytes: [])
    var fontName = LuaString("Default")
    var textInsetX = 0
    var textInsetY = 0
    var wrapsText = false
    var textImageWidth = 0
    var textImageHeight = 0
    var sizeChangeDispatchDepth = 0
    var parentChangeDispatchDepth = 0
    var foregroundColor: GMLuaPanelColorSnapshot?
    var contentAlignment = 5
    var allowsNonASCIICharacters = false
    var caretPosition = 0
    var expensiveShadow: GMLuaTextShadowSnapshot?
    var dock = GMLuaPanelDock.none
    var dockMargin = (left: 0.0, top: 0.0, right: 0.0, bottom: 0.0)
    var dockPadding = (left: 0.0, top: 0.0, right: 0.0, bottom: 0.0)
    var sizesToChildrenWidth = false
    var sizesToChildrenHeight = false
    var clipsChildren = true
    var disablesPaintClipping = false
    var imageName: LuaString?
    var modelImagePath: LuaString?
    var modelImageSkin = 0
    var modelImageBodyGroups: LuaString?
    var modelImageSpawnIconName: LuaString?
    var htmlDocumentLoadState = GMLuaHTMLDocumentLoadState.idle
    var htmlDocumentRequestIdentifier: UInt64 = 0
    var htmlDocumentURL: LuaString?
    var htmlDocumentSource: LuaString?
    var htmlDocumentFailureMessage: String?
    var htmlJavaScriptObjects: [LuaString] = []
    var htmlJavaScriptCallbacks: [GMLuaHTMLJavaScriptCallbackSnapshot] = []

    init(
        identifier: Int,
        engineClassName: String,
        requestedClassName: String,
        name: String,
        parentIdentifier: Int?
    ) {
        self.identifier = identifier
        self.engineClassName = engineClassName
        self.requestedClassName = requestedClassName
        self.name = name
        self.parentIdentifier = parentIdentifier
        siblingOrder = identifier
    }
}

private struct GMLuaPendingMissingMemberLookup {
    let panelIdentifier: Int
    let engineClassName: String
    let requestedClassName: String
    let methodName: String
    let source: String
    let line: Int?
}

private struct GMLuaPendingPanelSizeChange {
    let width: Double
    let height: Double
}

/// One ordering contract shared by drawing, hit testing and docking.
/// `SetDrawOnTop` remains a separate paint-only final pass.
private func panelComesBefore(
    _ first: GMLuaPanelValue,
    _ second: GMLuaPanelValue
) -> Bool {
    if first.isPopup != second.isPopup { return !first.isPopup }
    if first.zPosition != second.zPosition {
        return first.zPosition < second.zPosition
    }
    if first.siblingOrder != second.siblingOrder {
        return first.siblingOrder < second.siblingOrder
    }
    return first.identifier < second.identifier
}

/// State-local registry for native Panel identity and the Lua VGUI factory.
///
/// This is deliberately a logical VGUI layer. It creates real `Panel` typed
/// userdata and preserves the scripted-panel inheritance contract, but does
/// not claim that a platform view or a Metal drawable already exists.
public final class GMLuaVGUIRegistry: @unchecked Sendable {
    private static let engineClassNames: Set<String> = [
        "AchievementIcon", "AvatarImage", "CheckButton", "EditablePanel",
        "Frame", "HTML", "Label", "ModelImage", "Panel", "RadioButton",
        "RichText", "TGAImage", "TextEntry"
    ]

    private let state: LuaState
    private let typeSystem: GMLuaTypeSystem
    private let panelMetatable: LuaTable
    fileprivate let screenMetrics: GMLuaScreenMetrics?
    private let surfaceCommandState: GMLuaSurfaceCommandState?
    private let lock = NSLock()
    private var controls: [String: LuaTable] = [:]
    private var panels: [Int: LuaValue] = [:]
    private var nextPanelIdentifier = 1
    private var semanticIndex: LuaValue = .nilValue
    private var completedLayoutPasses: UInt64 = 0
    private var renderBridgeAttached = false
    private var textBridgeAttached = false
    private var hoveredPanelIdentifier: Int?
    private var pressedPanelIdentifier: Int?
    private var mouseCapturePanelIdentifier: Int?
    private var focusedPanelIdentifier: Int?
    private var logicalPointerPosition: (x: Double, y: Double)?
    private var latestDrawOnTopOrder: UInt64 = 0
    private var pendingDockSizeChanges: [Int: GMLuaPendingPanelSizeChange] = [:]
    private var pendingDependentLayoutIdentifiers: Set<Int> = []
    private var missingMethodDiagnosticsStorage: [GMLuaVGUIMissingMethodDiagnostic] = []
    private var pendingMissingMemberLookups: [GMLuaPendingMissingMemberLookup] = []

    fileprivate init(
        state: LuaState,
        typeSystem: GMLuaTypeSystem,
        panelMetatable: LuaTable,
        screenMetrics: GMLuaScreenMetrics?,
        surfaceCommandState: GMLuaSurfaceCommandState?
    ) {
        self.state = state
        self.typeSystem = typeSystem
        self.panelMetatable = panelMetatable
        self.screenMetrics = screenMetrics
        self.surfaceCommandState = surfaceCommandState
    }

    fileprivate func labelTextSize(
        _ panel: GMLuaPanelValue
    ) throws -> GMLuaTextMeasurement {
        guard let surfaceCommandState else {
            throw LuaError.runtime(
                "Panel:GetTextSize requires the shared surface text measurement boundary"
            )
        }
        return try surfaceCommandState.measureText(
            panel.text,
            usingFontNamed: panel.fontName,
            fallbackFontNamed: LuaString("Default")
        )
    }

    fileprivate func drawTextEntryText(
        _ panel: GMLuaPanelValue,
        textColor: GMLuaPanelColorSnapshot,
        highlightColor: GMLuaPanelColorSnapshot,
        cursorColor: GMLuaPanelColorSnapshot
    ) throws {
        guard !isFocused(identifier: panel.identifier) else {
            // The logical TextEntry has a real caret offset, but it still has
            // no selection range or platform glyph advances from which to
            // derive a truthful cursor rectangle. Keep that rendering gap
            // explicit instead of drawing a guessed caret/highlight.
            _ = highlightColor
            _ = cursorColor
            throw LuaError.runtime(
                "Panel:DrawTextEntryText cannot paint a focused TextEntry " +
                    "without caret and selection state"
            )
        }
        guard let surfaceCommandState else {
            throw LuaError.runtime(
                "Panel:DrawTextEntryText requires the shared surface command boundary"
            )
        }
        try surfaceCommandState.appendTextEntryText(
            value: panel.text,
            fontName: panel.fontName,
            color: textColor,
            insetX: panel.textInsetX,
            insetY: panel.textInsetY,
            panelHeight: panel.height
        )
    }

    fileprivate func drawFilledRect(_ panel: GMLuaPanelValue) throws {
        guard let surfaceCommandState else {
            throw LuaError.runtime(
                "Panel:DrawFilledRect requires the shared surface command boundary"
            )
        }
        surfaceCommandState.appendPanelFilledRectangle(
            width: panel.width,
            height: panel.height
        )
    }

    fileprivate func drawOutlinedRect(_ panel: GMLuaPanelValue) throws {
        guard let surfaceCommandState else {
            throw LuaError.runtime(
                "Panel:DrawOutlinedRect requires the shared surface command boundary"
            )
        }
        surfaceCommandState.appendPanelOutlinedRectangle(
            width: panel.width,
            height: panel.height
        )
    }

    fileprivate func labelContentSize(
        _ panel: GMLuaPanelValue
    ) throws -> GMLuaTextMeasurement {
        guard panel.imageName == nil else {
            throw LuaError.runtime(
                "Panel:GetContentSize cannot measure a Label image without a platform image boundary"
            )
        }

        let fullContentSize = try measuredLabelContent(panel)
        // Label.cpp replaces the current TextImage width with its full content
        // width. Keep the last native TextImage layout size separate because
        // wrapping and width truncation make it differ from full content.
        let currentTextImageSize = GMLuaTextMeasurement(
            width: panel.textImageWidth,
            height: panel.textImageHeight
        )
        // Native Label.cpp uses max(current aligned TextImage height + the
        // vertical inset, full content height). Original DLabel overrides the
        // native PerformLayout without sizing that TextImage, so the current
        // image height is zero throughout the bootstrap path. Do not add the
        // inset to the full glyph height: the Windows oracle returns 14, not
        // 27, for a 13px line with a 14px vertical inset.
        let alignedContentHeight = currentTextImageSize.height
        return GMLuaTextMeasurement(
            width: saturatingAdd(fullContentSize.width, panel.textInsetX),
            height: max(
                saturatingAdd(alignedContentHeight, panel.textInsetY),
                fullContentSize.height
            )
        )
    }

    /// Mirrors TextImage's width-constrained, whitespace-first wrapping while
    /// continuing to delegate every glyph measurement to the shared surface
    /// measurer. Explicit newlines always start another line; an individual
    /// word wider than the Label is split at Character boundaries.
    private func measuredLabelContent(
        _ panel: GMLuaPanelValue
    ) throws -> GMLuaTextMeasurement {
        guard panel.wrapsText else { return try labelTextSize(panel) }
        let maximumWidth = availableLabelTextWidth(panel)
        guard maximumWidth > 0 else {
            let characters = String(decoding: panel.text.bytes, as: UTF8.self)
            let lineCount = max(1, characters.reduce(into: 1) { count, character in
                if character == "\n" { count += 1 }
            })
            let empty = try measureLabelString("", panel: panel)
            return GMLuaTextMeasurement(
                width: 0,
                height: saturatingMultiply(lineCount, max(1, empty.height))
            )
        }

        let decoded = String(decoding: panel.text.bytes, as: UTF8.self)
        var lines: [String] = []
        var current = ""
        var token = ""
        var tokenIsWhitespace: Bool?

        func appendCurrentLine() {
            lines.append(current)
            current = ""
        }

        func appendToken() throws {
            guard !token.isEmpty else { return }
            let candidate = current + token
            if try measureLabelString(candidate, panel: panel).width <= maximumWidth {
                current = candidate
                token = ""
                return
            }

            if tokenIsWhitespace == true {
                if !current.isEmpty { appendCurrentLine() }
                token = ""
                return
            }

            let tokenWidth = try measureLabelString(token, panel: panel).width
            if tokenWidth <= maximumWidth {
                if !current.isEmpty { appendCurrentLine() }
                current = token
                token = ""
                return
            }

            // A single word wider than the available width has to be split.
            // Fill the remainder of the current line first; otherwise a short
            // prefix followed by whitespace manufactures an extra blank span
            // compared with TextImage's character fallback.
            for character in token {
                let characterCandidate = current + String(character)
                if !current.isEmpty,
                   try measureLabelString(characterCandidate, panel: panel).width > maximumWidth {
                    appendCurrentLine()
                }
                current.append(character)
            }
            token = ""
        }

        for character in decoded {
            if character == "\n" {
                try appendToken()
                appendCurrentLine()
                tokenIsWhitespace = nil
                continue
            }
            let whitespace = character.isWhitespace
            if let existingKind = tokenIsWhitespace, existingKind != whitespace {
                try appendToken()
            }
            tokenIsWhitespace = whitespace
            token.append(character)
        }
        try appendToken()
        lines.append(current)

        var widest = 0
        for line in lines {
            widest = max(widest, try measureLabelString(line, panel: panel).width)
        }
        let lineHeight = max(1, try measureLabelString("", panel: panel).height)
        return GMLuaTextMeasurement(
            width: min(maximumWidth, widest),
            height: saturatingMultiply(max(1, lines.count), lineHeight)
        )
    }

    private func measureLabelString(
        _ string: String,
        panel: GMLuaPanelValue
    ) throws -> GMLuaTextMeasurement {
        guard let surfaceCommandState else {
            throw LuaError.runtime(
                "Panel:GetContentSize requires the shared surface text measurement boundary"
            )
        }
        return try surfaceCommandState.measureText(
            LuaString(string),
            usingFontNamed: panel.fontName,
            fallbackFontNamed: LuaString("Default")
        )
    }

    fileprivate func performNativeLayout(_ panel: GMLuaPanelValue) throws {
        guard panel.engineClassName == "Label" else { return }
        let content = try measuredLabelContent(panel)
        let availableWidth = availableLabelTextWidth(panel)
        panel.textImageWidth = panel.wrapsText
            ? content.width
            : min(availableWidth, content.width)
        panel.textImageHeight = content.height
    }

    private func availableLabelTextWidth(_ panel: GMLuaPanelValue) -> Int {
        let availableWidth = floor(panel.width) - Double(panel.textInsetX)
        guard availableWidth.isFinite, availableWidth > 0 else { return 0 }
        guard availableWidth < Double(Int.max) else { return Int.max }
        return Int(availableWidth)
    }

    private func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let sum = lhs.addingReportingOverflow(rhs)
        guard sum.overflow else { return sum.partialValue }
        return rhs >= 0 ? Int.max : Int.min
    }

    private func saturatingMultiply(_ lhs: Int, _ rhs: Int) -> Int {
        let product = lhs.multipliedReportingOverflow(by: rhs)
        return product.overflow ? Int.max : product.partialValue
    }

    public var registeredControlCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return controls.count
    }

    public var livePanelCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return panels.values.reduce(into: 0) { count, value in
            if GMLuaTypeSystem.typedObject(from: value)?.isValid == true { count += 1 }
        }
    }

    /// Number of live logical panels waiting for the host's next VGUI frame
    /// boundary. This does not imply that UIKit or renderer layout exists.
    public var pendingLayoutCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return panels.values.reduce(into: 0) { count, value in
            guard let descriptor = panelDescriptor(from: value),
                  descriptor.isLayoutInvalidated,
                  GMLuaTypeSystem.typedObject(from: value)?.isValid == true else { return }
            count += 1
        }
    }

    /// Successful logical `PerformLayout` passes dispatched by this registry.
    /// Platform view layout remains outside this pure Swift compatibility layer.
    public var completedLayoutPassCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return completedLayoutPasses
    }

    /// Stable value snapshots for live Label/TextEntry/RichText controls.
    public var textPanelStateSnapshots: [GMLuaTextPanelStateSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return panels.keys.sorted().compactMap { identifier in
            guard let value = panels[identifier],
                  let descriptor = panelDescriptor(from: value),
                  isTextEngineClass(descriptor.engineClassName),
                  GMLuaTypeSystem.typedObject(from: value)?.isValid == true else { return nil }
            return GMLuaTextPanelStateSnapshot(
                panelIdentifier: descriptor.identifier,
                engineClassName: descriptor.engineClassName,
                requestedClassName: descriptor.requestedClassName,
                text: descriptor.text,
                fontName: descriptor.fontName,
                foregroundColor: descriptor.foregroundColor,
                contentAlignment: descriptor.contentAlignment,
                allowsNonASCIICharacters: descriptor.allowsNonASCIICharacters,
                caretPosition: descriptor.engineClassName == "TextEntry"
                    ? descriptor.caretPosition
                    : nil,
                textInsetX: descriptor.textInsetX,
                textInsetY: descriptor.textInsetY,
                wrapsText: descriptor.wrapsText,
                expensiveShadow: descriptor.expensiveShadow
            )
        }
    }

    /// Stable load-state snapshots for live native HTML controls. Page pixels,
    /// networking, JavaScript and DOM execution remain the responsibility of
    /// the platform HTML renderer.
    public var htmlPanelStateSnapshots: [GMLuaHTMLPanelStateSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return panels.keys.sorted().compactMap { identifier in
            guard let value = panels[identifier],
                  let descriptor = panelDescriptor(from: value),
                  descriptor.engineClassName == "HTML",
                  GMLuaTypeSystem.typedObject(from: value)?.isValid == true else { return nil }
            return GMLuaHTMLPanelStateSnapshot(
                panelIdentifier: descriptor.identifier,
                requestedClassName: descriptor.requestedClassName,
                state: descriptor.htmlDocumentLoadState,
                requestIdentifier: descriptor.htmlDocumentRequestIdentifier,
                url: descriptor.htmlDocumentURL,
                html: descriptor.htmlDocumentSource,
                failureMessage: descriptor.htmlDocumentFailureMessage,
                javascriptObjects: descriptor.htmlJavaScriptObjects,
                javascriptCallbacks: descriptor.htmlJavaScriptCallbacks
            )
        }
    }

    /// Stable requests for live native ModelImage controls. No preview image
    /// is fabricated at this renderer-neutral boundary.
    public var modelImageStateSnapshots: [GMLuaModelImageStateSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return panels.keys.sorted().compactMap { identifier in
            guard let value = panels[identifier],
                  let descriptor = panelDescriptor(from: value),
                  descriptor.engineClassName == "ModelImage",
                  GMLuaTypeSystem.typedObject(from: value)?.isValid == true else { return nil }
            return GMLuaModelImageStateSnapshot(
                panelIdentifier: descriptor.identifier,
                requestedClassName: descriptor.requestedClassName,
                modelPath: descriptor.modelImagePath,
                skin: descriptor.modelImageSkin,
                bodyGroups: descriptor.modelImageBodyGroups,
                spawnIconName: descriptor.modelImageSpawnIconName,
                previewState: .unavailable
            )
        }
    }

    /// Completes the renderer side of the exact HTML request represented by a
    /// snapshot. A stale completion is ignored, while type and callback errors
    /// remain explicit. On success the native callbacks observe the ready state
    /// before `OnDocumentReady`, followed by `OnFinishLoadingDocument` if that
    /// callback did not start a newer navigation.
    @discardableResult
    public func resolveHTMLDocumentLoad(
        panelIdentifier: Int,
        requestIdentifier: UInt64,
        result: GMLuaHTMLDocumentLoadResult
    ) throws -> Bool {
        let callbackURL: LuaString
        lock.lock()
        guard let value = panels[panelIdentifier],
              let descriptor = panelDescriptor(from: value),
              GMLuaTypeSystem.typedObject(from: value)?.isValid == true else {
            lock.unlock()
            return false
        }
        guard descriptor.engineClassName == "HTML" else {
            lock.unlock()
            throw unsupportedPanelMethod(descriptor, "resolveHTMLDocumentLoad")
        }
        guard descriptor.htmlDocumentLoadState == .loading,
              descriptor.htmlDocumentRequestIdentifier == requestIdentifier else {
            lock.unlock()
            return false
        }
        callbackURL = descriptor.htmlDocumentURL ?? LuaString("about:blank")
        switch result {
        case .succeeded:
            descriptor.htmlDocumentLoadState = .ready
            descriptor.htmlDocumentFailureMessage = nil
        case let .failed(message):
            descriptor.htmlDocumentLoadState = .failed
            descriptor.htmlDocumentFailureMessage = message
        }
        lock.unlock()

        guard case .succeeded = result else { return true }
        _ = try callPanelMethod(
            identifier: panelIdentifier,
            name: "OnDocumentReady",
            arguments: [.string(callbackURL)]
        )

        lock.lock()
        let requestIsStillCurrent = panels[panelIdentifier].flatMap {
            panelDescriptor(from: $0)
        }.map {
            $0.htmlDocumentRequestIdentifier == requestIdentifier &&
                $0.htmlDocumentLoadState == .ready
        } ?? false
        lock.unlock()
        if requestIsStillCurrent {
            _ = try callPanelMethod(
                identifier: panelIdentifier,
                name: "OnFinishLoadingDocument",
                arguments: [.string(callbackURL)]
            )
        }
        return true
    }

    /// Bounded, invocation-only diagnostics for unknown Panel methods. A
    /// scripted method found through the control-table inheritance chain never
    /// reaches this storage.
    public var missingMethodDiagnostics: [GMLuaVGUIMissingMethodDiagnostic] {
        lock.lock()
        defer { lock.unlock() }
        return missingMethodDiagnosticsStorage
    }

    /// `false` until the iPad view/renderer bridge is connected. The registry
    /// is still useful for loading and executing the original Derma Lua graph.
    public var hasPlatformViewBacking: Bool {
        lock.lock()
        defer { lock.unlock() }
        return renderBridgeAttached
    }

    /// Text state is logical only until a UIKit/CoreText/Metal bridge consumes
    /// the snapshots above.
    public var hasPlatformTextBacking: Bool {
        lock.lock()
        defer { lock.unlock() }
        return textBridgeAttached
    }

    /// Called by the Apple renderer when it starts consuming panel snapshots.
    /// Keeping this explicit prevents logical panels from being reported as
    /// rendered merely because they were created successfully.
    public func connectPlatformBridge(textBacking: Bool) {
        lock.lock()
        renderBridgeAttached = true
        textBridgeAttached = textBacking
        lock.unlock()
    }

    public func disconnectPlatformBridge() {
        lock.lock()
        renderBridgeAttached = false
        textBridgeAttached = false
        lock.unlock()
    }

    fileprivate func setDrawOnTop(identifier: Int, enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard let value = panels[identifier], let descriptor = panelDescriptor(from: value) else {
            return
        }
        guard enabled else {
            descriptor.drawOnTopOrder = nil
            return
        }
        latestDrawOnTopOrder &+= 1
        descriptor.drawOnTopOrder = latestDrawOnTopOrder
    }

    fileprivate func moveToStackEdge(identifier: Int, front: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard let value = panels[identifier],
              let target = panelDescriptor(from: value),
              GMLuaTypeSystem.typedObject(from: value)?.isValid == true else {
            return
        }
        moveToStackEdgeLocked(target, front: front)
    }

    fileprivate func makePopup(identifier: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let value = panels[identifier],
              let panel = panelDescriptor(from: value),
              GMLuaTypeSystem.typedObject(from: value)?.isValid == true else {
            return
        }
        panel.mouseInputEnabled = true
        panel.keyboardInputEnabled = true
        panel.isPopup = true
        moveToStackEdgeLocked(panel, front: true)
        focusedPanelIdentifier = identifier
    }

    /// Moves within one parent and one popup tier. The target adopts the
    /// tier's boundary ZPos, then siblingOrder breaks that boundary tie. This
    /// preserves `GetZPos`, paint order and dock order as one coherent state.
    private func moveToStackEdgeLocked(
        _ target: GMLuaPanelValue,
        front: Bool
    ) {
        let peers = panels.values.compactMap { value -> GMLuaPanelValue? in
            guard let panel = panelDescriptor(from: value),
                  panel.parentIdentifier == target.parentIdentifier,
                  panel.isPopup == target.isPopup,
                  GMLuaTypeSystem.typedObject(from: value)?.isValid == true else {
                return nil
            }
            return panel
        }
        guard peers.count > 1 else { return }

        let orderedPeers = peers.sorted(by: panelComesBefore)
        let remaining = orderedPeers.filter { $0.identifier != target.identifier }
        guard let boundary = front
                ? remaining.map(\.zPosition).max()
                : remaining.map(\.zPosition).min() else {
            return
        }
        target.zPosition = boundary
        let reordered = front ? remaining + [target] : [target] + remaining
        for (order, panel) in reordered.enumerated() {
            panel.siblingOrder = order
        }
    }

    /// Resolves the native dock graph without executing Lua. Top-level panels
    /// dock against VGUI's implicit world panel, represented here by the live
    /// viewport rather than by a fabricated Lua parent.
    private func resolveNativeDocking(viewportWidth: Int, viewportHeight: Int) {
        guard viewportWidth > 0, viewportHeight > 0 else { return }
        lock.lock()
        defer { lock.unlock() }

        let live = panels.compactMap { (identifier, value) -> (Int, GMLuaPanelValue)? in
            guard let descriptor = panelDescriptor(from: value),
                  GMLuaTypeSystem.typedObject(from: value)?.isValid == true else { return nil }
            return (identifier, descriptor)
        }
        applyNativeDockingLocked(
            descriptors: Dictionary(uniqueKeysWithValues: live),
            viewport: GMLuaPanelRect(
                x: 0,
                y: 0,
                width: Double(viewportWidth),
                height: Double(viewportHeight)
            )
        )
    }

    /// Delivers final dock dimensions only after the complete graph is
    /// observable. A callback that changes docking is deferred to a later
    /// layout phase rather than recursively restarting the solver.
    private func dispatchPendingDockSizeChanges() throws {
        lock.lock()
        let changes = pendingDockSizeChanges.sorted { $0.key < $1.key }
        pendingDockSizeChanges.removeAll(keepingCapacity: true)
        lock.unlock()

        for (identifier, change) in changes {
            let panel: GMLuaPanelValue?
            lock.lock()
            if let value = panels[identifier],
               GMLuaTypeSystem.typedObject(from: value)?.isValid == true,
               let descriptor = panelDescriptor(from: value),
               descriptor.width == change.width,
               descriptor.height == change.height {
                panel = descriptor
            } else {
                panel = nil
            }
            lock.unlock()
            guard let panel else { continue }
            try dispatchPanelSizeChanged(
                panel,
                width: change.width,
                height: change.height
            )
        }
    }

    /// Must be called while `lock` is held. Hidden panels do not consume dock
    /// space, while alpha-zero panels do, matching the child docking contract.
    private func applyNativeDockingLocked(
        descriptors: [Int: GMLuaPanelValue],
        viewport: GMLuaPanelRect
    ) {
        let originalBounds = Dictionary(uniqueKeysWithValues: descriptors.map {
            ($0.key, (
                x: $0.value.x,
                y: $0.value.y,
                width: $0.value.width,
                height: $0.value.height
            ))
        })

        func childrenForDocking(of parent: Int?) -> [GMLuaPanelValue] {
            descriptors.values
                .filter { $0.parentIdentifier == parent && $0.isVisible }
                .sorted(by: panelComesBefore)
        }

        func dock(_ panel: GMLuaPanelValue, into available: inout GMLuaPanelRect) {
            let margin = panel.dockMargin
            switch panel.dock {
            case .none:
                break
            case .top:
                panel.x = available.x + margin.left
                panel.y = available.y + margin.top
                panel.width = max(0, available.width - margin.left - margin.right)
                available = GMLuaPanelRect(
                    x: available.x,
                    y: panel.y + panel.height + margin.bottom,
                    width: available.width,
                    height: max(0, available.height - panel.height - margin.top - margin.bottom)
                )
            case .bottom:
                panel.x = available.x + margin.left
                panel.y = available.y + available.height - panel.height - margin.bottom
                panel.width = max(0, available.width - margin.left - margin.right)
                available = GMLuaPanelRect(
                    x: available.x,
                    y: available.y,
                    width: available.width,
                    height: max(0, available.height - panel.height - margin.top - margin.bottom)
                )
            case .left:
                panel.x = available.x + margin.left
                panel.y = available.y + margin.top
                panel.height = max(0, available.height - margin.top - margin.bottom)
                available = GMLuaPanelRect(
                    x: panel.x + panel.width + margin.right,
                    y: available.y,
                    width: max(0, available.width - panel.width - margin.left - margin.right),
                    height: available.height
                )
            case .right:
                panel.x = available.x + available.width - panel.width - margin.right
                panel.y = available.y + margin.top
                panel.height = max(0, available.height - margin.top - margin.bottom)
                available = GMLuaPanelRect(
                    x: available.x,
                    y: available.y,
                    width: max(0, available.width - panel.width - margin.left - margin.right),
                    height: available.height
                )
            case .fill:
                panel.x = available.x + margin.left
                panel.y = available.y + margin.top
                panel.width = max(0, available.width - margin.left - margin.right)
                panel.height = max(0, available.height - margin.top - margin.bottom)
            }
        }

        func applyChildDocking(to parent: GMLuaPanelValue) {
            var available = GMLuaPanelRect(
                x: parent.dockPadding.left,
                y: parent.dockPadding.top,
                width: max(0, parent.width - parent.dockPadding.left - parent.dockPadding.right),
                height: max(0, parent.height - parent.dockPadding.top - parent.dockPadding.bottom)
            )
            for child in childrenForDocking(of: parent.identifier) {
                dock(child, into: &available)
                applyChildDocking(to: child)
            }
        }

        var worldPanelAvailable = viewport
        for root in childrenForDocking(of: nil) {
            dock(root, into: &worldPanelAvailable)
            applyChildDocking(to: root)
        }

        // IPanel docking ultimately uses SetSize. Coalesce the completed dock
        // graph before queuing Lua callbacks so every OnSizeChanged observer
        // sees the final geometry of parents, siblings, and descendants.
        for (identifier, panel) in descriptors {
            guard let original = originalBounds[identifier] else { continue }
            let current = (x: panel.x, y: panel.y, width: panel.width, height: panel.height)
            invalidateSizeDependentParentLocked(
                for: panel,
                oldBounds: original,
                newBounds: current
            )
            if original.width != panel.width || original.height != panel.height {
                pendingDockSizeChanges[identifier] = GMLuaPendingPanelSizeChange(
                    width: panel.width,
                    height: panel.height
                )
                pendingDependentLayoutIdentifiers.insert(identifier)
            }
        }
    }

    /// Applies native docking and returns a stable back-to-front draw tree.
    /// Coordinates are logical host points, matching the ScrW/ScrH values
    /// supplied by the app independently from Retina drawable scale.
    public func renderTree(viewportWidth: Int, viewportHeight: Int) -> [GMLuaPanelRenderSnapshot] {
        renderTree(
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            placeDrawOnTopLast: true
        )
    }

    private func renderTree(
        viewportWidth: Int,
        viewportHeight: Int,
        placeDrawOnTopLast: Bool
    ) -> [GMLuaPanelRenderSnapshot] {
        guard viewportWidth > 0, viewportHeight > 0 else { return [] }
        lock.lock()
        defer { lock.unlock() }

        let live = panels.compactMap { (identifier, value) -> (Int, GMLuaPanelValue)? in
            guard let descriptor = panelDescriptor(from: value),
                  GMLuaTypeSystem.typedObject(from: value)?.isValid == true else { return nil }
            return (identifier, descriptor)
        }
        let descriptors = Dictionary(uniqueKeysWithValues: live)

        let viewport = GMLuaPanelRect(
            x: 0,
            y: 0,
            width: Double(viewportWidth),
            height: Double(viewportHeight)
        )
        applyNativeDockingLocked(descriptors: descriptors, viewport: viewport)

        func childrenForDrawing(of parent: Int?) -> [GMLuaPanelValue] {
            descriptors.values
                .filter { $0.parentIdentifier == parent && $0.isVisible && $0.alpha > 0 }
                .sorted(by: panelComesBefore)
        }
        var result: [GMLuaPanelRenderSnapshot] = []
        func append(
            _ panel: GMLuaPanelValue,
            originX: Double,
            originY: Double,
            ancestorClip: GMLuaPanelRect,
            ancestorAlpha: Double,
            inheritedDrawOnTopOrder: UInt64?
        ) {
            let frame = GMLuaPanelRect(
                x: originX + panel.x,
                y: originY + panel.y,
                width: panel.width,
                height: panel.height
            )
            guard let ownClip = ancestorClip.intersection(frame) else { return }
            let effectiveAlpha = ancestorAlpha * panel.alpha / 255
            guard effectiveAlpha > 0 else { return }
            let effectiveDrawOnTopOrder = panel.drawOnTopOrder ?? inheritedDrawOnTopOrder
            result.append(GMLuaPanelRenderSnapshot(
                identifier: panel.identifier,
                parentIdentifier: panel.parentIdentifier,
                engineClassName: panel.engineClassName,
                requestedClassName: panel.requestedClassName,
                frame: frame,
                clipRect: ownClip,
                paintClipRect: panel.disablesPaintClipping ? viewport : ownClip,
                paintClippingDisabled: panel.disablesPaintClipping,
                zPosition: panel.zPosition,
                alpha: effectiveAlpha,
                mouseInputEnabled: panel.mouseInputEnabled,
                keyboardInputEnabled: panel.keyboardInputEnabled,
                isPopup: panel.isPopup,
                worldClicker: panel.isWorldClicker,
                cursorName: panel.cursorName,
                drawOnTop: effectiveDrawOnTopOrder != nil,
                drawOnTopOrder: effectiveDrawOnTopOrder,
                text: panel.text,
                fontName: panel.fontName,
                foregroundColor: panel.foregroundColor,
                contentAlignment: panel.contentAlignment,
                textInsetX: panel.textInsetX,
                textInsetY: panel.textInsetY,
                wrapsText: panel.wrapsText,
                expensiveShadow: panel.expensiveShadow,
                imageName: panel.imageName
            ))
            let childClip = panel.clipsChildren ? ownClip : ancestorClip
            for child in childrenForDrawing(of: panel.identifier) {
                append(
                    child,
                    originX: frame.x,
                    originY: frame.y,
                    ancestorClip: childClip,
                    ancestorAlpha: effectiveAlpha,
                    inheritedDrawOnTopOrder: effectiveDrawOnTopOrder
                )
            }
        }
        for root in childrenForDrawing(of: nil) {
            append(
                root,
                originX: 0,
                originY: 0,
                ancestorClip: viewport,
                ancestorAlpha: 255,
                inheritedDrawOnTopOrder: nil
            )
        }
        guard placeDrawOnTopLast else { return result }
        let normal = result.filter { !$0.drawOnTop }
        let onTop = result.enumerated()
            .filter { $0.element.drawOnTop }
            .sorted {
                let firstOrder = $0.element.drawOnTopOrder ?? 0
                let secondOrder = $1.element.drawOnTopOrder ?? 0
                if firstOrder != secondOrder { return firstOrder < secondOrder }
                return $0.offset < $1.offset
            }
            .map(\.element)
        return normal + onTop
    }

    /// Routes a UIKit touch through VGUI's existing Lua callbacks. The return
    /// value records exactly which callbacks existed and ran; absence is not
    /// converted into a successful no-op.
    public func dispatchPointerEvent(
        x: Double,
        y: Double,
        phase: GMLuaPointerPhase,
        timestamp: TimeInterval,
        viewportWidth: Int,
        viewportHeight: Int
    ) throws -> GMLuaPointerDispatchResult {
        lock.lock()
        if phase == .cancelled {
            logicalPointerPosition = nil
        } else {
            logicalPointerPosition = (x: x, y: y)
        }
        lock.unlock()

        // SetDrawOnTop changes paint order only. Native VGUI keeps ordinary
        // input stacking, so a visually raised panel can still be covered for
        // hit-testing by a panel that would otherwise be in front of it.
        let tree = renderTree(
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            placeDrawOnTopLast: false
        )
        let hit = tree.reversed().first {
            $0.mouseInputEnabled && $0.clipRect.contains(x: x, y: y)
        }
        let hitIdentifier = hit?.identifier
        let treeByIdentifier = Dictionary(
            uniqueKeysWithValues: tree.map { ($0.identifier, $0) }
        )
        var effectiveWorldClicker = false
        var worldClickerCandidate = hitIdentifier
        var visitedWorldClickerPanels: Set<Int> = []
        while let identifier = worldClickerCandidate,
              visitedWorldClickerPanels.insert(identifier).inserted,
              let panel = treeByIdentifier[identifier] {
            if panel.worldClicker {
                effectiveWorldClicker = true
                break
            }
            worldClickerCandidate = panel.parentIdentifier
        }
        var callbacks: [String] = []

        let previousHover: Int?
        let nextHover = phase == .cancelled ? nil : hitIdentifier
        lock.lock()
        previousHover = hoveredPanelIdentifier
        hoveredPanelIdentifier = nextHover
        lock.unlock()

        // `Hovered` is an engine-maintained field read directly by the stock
        // DLabel/DButton release path. Update the Lua sidecars before cursor
        // callbacks and before OnMouseReleased, including the cancellation
        // transition which must never be interpreted as a click.
        if previousHover != nextHover, let previousHover {
            try setPanelHovered(identifier: previousHover, hovered: false)
        }
        if let nextHover {
            try setPanelHovered(identifier: nextHover, hovered: true)
        }
        if previousHover != nextHover {
            if let previousHover,
               try callPanelMethod(identifier: previousHover, name: "OnCursorExited") {
                callbacks.append("OnCursorExited")
            }
            if let nextHover,
               try callPanelMethod(identifier: nextHover, name: "OnCursorEntered") {
                callbacks.append("OnCursorEntered")
            }
        }

        switch phase {
        case .moved:
            lock.lock()
            let captured = mouseCapturePanelIdentifier
            lock.unlock()
            let targetIdentifier = captured ?? hitIdentifier
            let targetFrame = targetIdentifier.flatMap { identifier in
                tree.first(where: { $0.identifier == identifier })?.frame
            }
            if let targetIdentifier,
               try callPanelMethod(identifier: targetIdentifier, name: "OnCursorMoved", arguments: [
                    .number(x - (targetFrame?.x ?? 0)),
                    .number(y - (targetFrame?.y ?? 0))
               ]) {
                callbacks.append("OnCursorMoved")
            }
        case .began:
            lock.lock()
            pressedPanelIdentifier = hitIdentifier
            if let hitIdentifier { focusedPanelIdentifier = hitIdentifier }
            lock.unlock()
            if let hitIdentifier,
               try callPanelMethod(
                    identifier: hitIdentifier,
                    name: "OnMousePressed",
                    arguments: [.number(107)]
               ) {
                callbacks.append("OnMousePressed")
            }
        case .ended:
            let releaseTarget: Int?
            lock.lock()
            releaseTarget = mouseCapturePanelIdentifier ?? pressedPanelIdentifier
            pressedPanelIdentifier = nil
            lock.unlock()
            if let releaseTarget,
               try callPanelMethod(
                    identifier: releaseTarget,
                    name: "OnMouseReleased",
                    arguments: [.number(107)]
               ) {
                callbacks.append("OnMouseReleased")
            }
        case .cancelled:
            let releaseTarget: Int?
            lock.lock()
            releaseTarget = mouseCapturePanelIdentifier ?? pressedPanelIdentifier
            pressedPanelIdentifier = nil
            mouseCapturePanelIdentifier = nil
            lock.unlock()
            if let releaseTarget {
                // Lua may transfer capture to a panel other than the last hit.
                // Keep cancellation non-clicking for that sidecar as well.
                try setPanelHovered(identifier: releaseTarget, hovered: false)
            }
            if let releaseTarget,
               try callPanelMethod(
                    identifier: releaseTarget,
                    name: "OnMouseReleased",
                    arguments: [.number(107)]
               ) {
                callbacks.append("OnMouseReleased")
            }
        case let .scroll(delta):
            if let hitIdentifier,
               try callPanelMethod(
                    identifier: hitIdentifier,
                    name: "OnMouseWheeled",
                    arguments: [.number(delta)]
               ) {
                callbacks.append("OnMouseWheeled")
            }
        }
        return GMLuaPointerDispatchResult(
            hitPanelIdentifier: hitIdentifier,
            worldClicker: effectiveWorldClicker,
            callbackNames: callbacks,
            // The host only delivers raw pointer callbacks. Scripted controls
            // decide whether a release is a click/double-click; synthesizing
            // DoClick here would run it twice for shipped DLabel controls.
            clicked: false,
            doubleClicked: false
        )
    }

    private func setPanelHovered(identifier: Int, hovered: Bool) throws {
        let descriptor: GMLuaPanelValue?
        lock.lock()
        if let value = panels[identifier],
           GMLuaTypeSystem.typedObject(from: value)?.isValid == true {
            descriptor = panelDescriptor(from: value)
        } else {
            descriptor = nil
        }
        lock.unlock()
        guard let descriptor else { return }
        try state.setRawTableValue(
            .boolean(hovered),
            for: .string("Hovered"),
            in: descriptor.instanceTable
        )
    }

    /// Executes Paint/PaintOver on the original Lua panels while the surface
    /// library records renderer-neutral draw commands for Metal.
    @discardableResult
    public func renderFrame(
        surface: GMLuaSurfaceCommandState,
        viewportWidth: Int,
        viewportHeight: Int
    ) throws -> GMLuaSurfaceFrameSnapshot {
        // Native VGUI resolves Dock against the implicit world panel before
        // Lua PerformLayout. A second resolution after Lua layout captures any
        // size/dock changes the callbacks made before the final tree is built.
        resolveNativeDocking(viewportWidth: viewportWidth, viewportHeight: viewportHeight)
        try dispatchPendingDockSizeChanges()
        _ = try performPendingLayouts()
        for _ in 0..<64 {
            _ = try performDependentLayoutsToFixedPoint()
            resolveNativeDocking(viewportWidth: viewportWidth, viewportHeight: viewportHeight)
            try dispatchPendingDockSizeChanges()
            if !hasPendingDependentLayouts { break }
        }
        guard !hasPendingDependentLayouts else {
            throw LuaError.runtime(
                "VGUI dependent layout/docking fixed-point exceeded 64 iterations"
            )
        }
        let tree = renderTree(viewportWidth: viewportWidth, viewportHeight: viewportHeight)
        surface.beginFrame(viewportWidth: viewportWidth, viewportHeight: viewportHeight)
        let byParent = Dictionary(grouping: tree, by: \.parentIdentifier)

        func withinPanelContext<T>(
            _ panel: GMLuaPanelRenderSnapshot,
            clip: GMLuaPanelRect,
            _ operation: () throws -> T
        ) rethrows -> T {
            surface.pushPanelContext(frame: panel.frame, clip: clip, alpha: panel.alpha)
            defer { surface.popPanelContext() }
            return try operation()
        }

        func paint(_ panel: GMLuaPanelRenderSnapshot) throws {
            let paintResult = try withinPanelContext(panel, clip: panel.paintClipRect) {
                try callPanelMethodReturningValues(
                    identifier: panel.identifier,
                    name: "Paint",
                    arguments: [.number(panel.frame.width), .number(panel.frame.height)]
                )
            }
            let suppressesDefaultPaint: Bool
            if let first = paintResult?.first, case .boolean(true) = first {
                suppressesDefaultPaint = true
            } else {
                suppressesDefaultPaint = false
            }
            if !suppressesDefaultPaint {
                try withinPanelContext(panel, clip: panel.clipRect) {
                    try surface.appendPanelImage(panel)
                    if panel.engineClassName == "Label" { surface.appendPanelText(panel) }
                }
            }
            for child in byParent[panel.identifier] ?? [] { try paint(child) }
            _ = try withinPanelContext(panel, clip: panel.paintClipRect) {
                try callPanelMethod(
                    identifier: panel.identifier,
                    name: "PaintOver",
                    arguments: [.number(panel.frame.width), .number(panel.frame.height)]
                )
            }
        }
        for root in byParent[nil] ?? [] { try paint(root) }
        return surface.frameSnapshot
    }

    /// Minimal UITextInput boundary for engine TextEntry. It updates the same
    /// logical value returned by GetText/GetValue and then invokes the original
    /// scripted callbacks when present.
    @discardableResult
    public func insertText(_ text: String) throws -> Int? {
        let identifier: Int?
        let value: LuaValue?
        let descriptor: GMLuaPanelValue?
        var changed = false
        lock.lock()
        identifier = focusedPanelIdentifier
        value = identifier.flatMap { panels[$0] }
        descriptor = value.flatMap { panelDescriptor(from: $0) }
        if let descriptor,
           descriptor.engineClassName == "TextEntry",
           descriptor.keyboardInputEnabled {
            let supplied = Array(text.utf8)
            // Host UITextInput batching policy: when the native TextEntry is
            // restricted, preserve the US-ASCII subsequence of a mixed Swift
            // String. The public API documents the character restriction but
            // does not specify native mixed-paste aggregation behavior.
            let accepted = descriptor.allowsNonASCIICharacters
                ? supplied
                : supplied.filter { $0 <= 0x7f }
            if !accepted.isEmpty {
                let boundaries = utf8CharacterBoundaries(in: descriptor.text.bytes)
                let clampedCaret = min(
                    max(0, descriptor.caretPosition),
                    boundaries.count - 1
                )
                let insertionOffset = boundaries[clampedCaret]
                descriptor.text = LuaString(
                    bytes: Array(descriptor.text.bytes[..<insertionOffset]) +
                        accepted +
                        Array(descriptor.text.bytes[insertionOffset...])
                )
                descriptor.caretPosition = clampedCaret +
                    utf8CharacterCount(in: accepted)
                changed = true
            }
        }
        lock.unlock()
        guard let identifier, let descriptor,
              descriptor.engineClassName == "TextEntry",
              descriptor.keyboardInputEnabled else { return nil }
        if changed {
            _ = try callPanelMethod(identifier: identifier, name: "OnTextChanged")
        }
        return identifier
    }

    private func callPanelMethod(
        identifier: Int,
        name: String,
        arguments: [LuaValue] = []
    ) throws -> Bool {
        try callPanelMethodReturningValues(
            identifier: identifier,
            name: name,
            arguments: arguments
        ) != nil
    }

    private func callPanelMethodReturningValues(
        identifier: Int,
        name: String,
        arguments: [LuaValue] = []
    ) throws -> [LuaValue]? {
        let value: LuaValue
        let descriptor: GMLuaPanelValue
        lock.lock()
        guard let stored = panels[identifier],
              let storedDescriptor = panelDescriptor(from: stored),
              GMLuaTypeSystem.typedObject(from: stored)?.isValid == true else {
            lock.unlock()
            return nil
        }
        value = stored
        descriptor = storedDescriptor
        lock.unlock()
        let callback = try state.call(
            semanticIndex,
            arguments: [.table(descriptor.instanceTable), .string(LuaString(name))]
        ).first ?? .nilValue
        switch callback {
        case .luaFunction, .nativeFunction:
            return try callVGUIFunction(callback, arguments: [value] + arguments)
        default:
            return nil
        }
    }

    fileprivate func beginHTMLDocumentLoad(
        _ panel: GMLuaPanelValue,
        url: LuaString?,
        html: LuaString?
    ) throws {
        guard panel.engineClassName == "HTML" else {
            throw unsupportedPanelMethod(panel, url == nil ? "SetHTML" : "OpenURL")
        }
        panel.htmlDocumentRequestIdentifier &+= 1
        panel.htmlDocumentLoadState = .loading
        panel.htmlDocumentURL = url
        panel.htmlDocumentSource = html
        panel.htmlDocumentFailureMessage = nil

        // Native HTML events are delivered after its load state changes. The
        // renderer-neutral host mirrors that observable ordering and leaves
        // completion to resolveHTMLDocumentLoad rather than claiming that it
        // parsed a document.
        _ = try callPanelMethod(
            identifier: panel.identifier,
            name: "OnBeginLoadingDocument",
            arguments: [.string(url ?? LuaString("about:blank"))]
        )
    }

    /// Mirrors `IPanel::SetSize` delivering `Panel::OnSizeChanged` after the
    /// new integer dimensions are observable. Identical sizes are a no-op.
    /// A finite guard turns a pathological scripted resize cycle into an
    /// explicit Lua error instead of exhausting the host stack.
    fileprivate func setPanelSize(
        _ panel: GMLuaPanelValue,
        width: Double,
        height: Double
    ) throws {
        let newWidth = floor(width)
        let newHeight = floor(height)
        guard panel.width != newWidth || panel.height != newHeight else { return }

        lock.lock()
        let oldBounds = (x: panel.x, y: panel.y, width: panel.width, height: panel.height)
        pendingDockSizeChanges.removeValue(forKey: panel.identifier)
        panel.width = newWidth
        panel.height = newHeight
        invalidateSizeDependentParentLocked(
            for: panel,
            oldBounds: oldBounds,
            newBounds: (x: panel.x, y: panel.y, width: newWidth, height: newHeight)
        )
        lock.unlock()
        try dispatchPanelSizeChanged(panel, width: newWidth, height: newHeight)
    }

    fileprivate func setPanelPosition(
        _ panel: GMLuaPanelValue,
        x: Double,
        y: Double
    ) {
        guard panel.x != x || panel.y != y else { return }
        lock.lock()
        let oldBounds = (x: panel.x, y: panel.y, width: panel.width, height: panel.height)
        panel.x = x
        panel.y = y
        invalidateSizeDependentParentLocked(
            for: panel,
            oldBounds: oldBounds,
            newBounds: (x: x, y: y, width: panel.width, height: panel.height)
        )
        lock.unlock()
    }

    private func dispatchPanelSizeChanged(
        _ panel: GMLuaPanelValue,
        width: Double,
        height: Double
    ) throws {
        guard panel.sizeChangeDispatchDepth < 64 else {
            throw LuaError.runtime(
                "Panel:OnSizeChanged recursion limit exceeded for '\(panel.requestedClassName)'"
            )
        }
        panel.sizeChangeDispatchDepth += 1
        defer { panel.sizeChangeDispatchDepth -= 1 }
        _ = try callPanelMethod(
            identifier: panel.identifier,
            name: "OnSizeChanged",
            arguments: [.number(width), .number(height)]
        )
    }

    fileprivate func noteMissingMemberLookup(
        panel: GMLuaPanelValue,
        methodName: String
    ) {
        let location = currentLuaSourceLocation()
        let lookup = GMLuaPendingMissingMemberLookup(
            panelIdentifier: panel.identifier,
            engineClassName: panel.engineClassName,
            requestedClassName: panel.requestedClassName,
            methodName: methodName,
            source: location.source,
            line: location.line
        )
        lock.lock()
        if pendingMissingMemberLookups.count == 1_024 {
            pendingMissingMemberLookups.removeFirst()
        }
        pendingMissingMemberLookups.append(lookup)
        lock.unlock()
    }

    private func callVGUIFunction(
        _ callable: LuaValue,
        arguments: [LuaValue]
    ) throws -> [LuaValue] {
        do {
            return try state.call(callable, arguments: arguments)
        } catch {
            throw classifyMissingMethodCall(error)
        }
    }

    private func classifyMissingMethodCall(_ error: Error) -> Error {
        let source: String
        let line: Int?
        let message: String
        switch error {
        case let LuaError.runtimeAt(errorSource, errorLine, errorMessage):
            source = errorSource
            line = errorLine > 0 ? errorLine : nil
            message = errorMessage
        case let LuaError.runtime(errorMessage):
            source = "[unknown]"
            line = nil
            message = errorMessage
        default:
            return error
        }

        let prefix = "attempt to call method '"
        let suffix = "' (a nil value)"
        guard message.hasPrefix(prefix), message.hasSuffix(suffix) else { return error }
        let start = message.index(message.startIndex, offsetBy: prefix.count)
        let end = message.index(message.endIndex, offsetBy: -suffix.count)
        let methodName = String(message[start..<end])

        let lookup: GMLuaPendingMissingMemberLookup?
        lock.lock()
        if let index = pendingMissingMemberLookups.lastIndex(where: { candidate in
            candidate.methodName == methodName &&
                (source == "[unknown]" || candidate.source == source) &&
                (line == nil || candidate.line == nil || candidate.line == line)
        }) {
            lookup = pendingMissingMemberLookups.remove(at: index)
        } else {
            lookup = nil
        }
        lock.unlock()
        guard let lookup else { return error }

        let diagnostic = GMLuaVGUIMissingMethodDiagnostic(
            panelIdentifier: lookup.panelIdentifier,
            engineClassName: lookup.engineClassName,
            requestedClassName: lookup.requestedClassName,
            methodName: methodName,
            source: source == "[unknown]" ? lookup.source : source,
            line: line ?? lookup.line
        )
        lock.lock()
        if missingMethodDiagnosticsStorage.count == 1_024 {
            missingMethodDiagnosticsStorage.removeFirst()
        }
        missingMethodDiagnosticsStorage.append(diagnostic)
        lock.unlock()
        if let line = diagnostic.line {
            return LuaError.runtimeAt(
                source: diagnostic.source,
                line: line,
                message: diagnostic.logLine
            )
        }
        return LuaError.runtime(diagnostic.logLine)
    }

    private func currentLuaSourceLocation() -> (source: String, line: Int?) {
        var sourceName = state.luaCallerSourceName(level: 2)
        var line: Int?
        do {
            guard case let .table(debugTable) = state.getGlobal("debug") else {
                throw LuaError.runtime("debug table unavailable")
            }
            let getInfo = try state.rawTableValue(for: .string("getinfo"), in: debugTable)
            guard case let .table(info) = try state.call(
                getInfo,
                arguments: [.number(2), .string("Sl")]
            ).first ?? .nilValue else {
                throw LuaError.runtime("debug.getinfo caller unavailable")
            }
            if case let .string(source) = try state.rawTableValue(
                for: .string("source"),
                in: info
            ) {
                sourceName = source.utf8String
            }
            if case let .number(currentLine) = try state.rawTableValue(
                for: .string("currentline"),
                in: info
            ), currentLine.isFinite, currentLine > 0, currentLine < Double(Int.max) {
                line = Int(currentLine.rounded(.towardZero))
            }
        } catch {
            // Source names are still available directly from the active Lua
            // caller even when a script replaced or removed debug.getinfo.
        }
        let normalizedSource: String
        if let sourceName, sourceName.hasPrefix("@") || sourceName.hasPrefix("=") {
            normalizedSource = String(sourceName.dropFirst())
        } else {
            normalizedSource = sourceName ?? "[unknown]"
        }
        return (normalizedSource, line)
    }

    fileprivate var references: [LuaValue] {
        lock.lock()
        defer { lock.unlock() }
        let panelValues = Array(panels.values)
        // Panel userdata only exposes its Lua sidecar through the Swift payload,
        // which the collector cannot traverse. Original scriptedpanels.lua
        // merges accessors into GetTable() before Init, so keep every live
        // sidecar rooted even when child creation collects during that Init.
        let instanceTables = panelValues.compactMap { value -> LuaValue? in
            guard let descriptor = panelDescriptor(from: value) else { return nil }
            return .table(descriptor.instanceTable)
        }
        return controls.values.map(LuaValue.table)
            + panelValues
            + instanceTables
            + [.table(panelMetatable), semanticIndex]
    }

    fileprivate func registerControl(
        name: String,
        table: LuaTable,
        baseName: String
    ) throws {
        try state.setRawTableValue(
            .string(LuaString(baseName)),
            for: .string("Base"),
            in: table
        )
        if case .nilValue = try state.rawTableValue(for: .string("Init"), in: table) {
            try state.setRawTableValue(
                .nativeFunction(LuaNativeFunctionBox({ _ in [] }, debugName: "Panel:Init")),
                for: .string("Init"),
                in: table
            )
        }

        let inheritance = LuaTable()
        let baseTable: LuaTable?
        lock.lock()
        baseTable = controls[baseName]
        lock.unlock()
        try state.setRawTableValue(
            .table(baseTable ?? panelMetatable),
            for: .string("__index"),
            in: inheritance
        )
        table.metatable = inheritance

        lock.lock()
        controls[name] = table
        lock.unlock()
    }

    fileprivate func control(named name: String) -> LuaTable? {
        lock.lock()
        defer { lock.unlock() }
        return controls[name]
    }

    fileprivate func create(
        className: String,
        parent: LuaValue?,
        name: String?
    ) throws -> LuaValue {
        let parentIdentifier: Int?
        if let parent, !isNil(parent) {
            guard let descriptor = panelDescriptor(from: parent),
                  GMLuaTypeSystem.typedObject(from: parent)?.isValid == true else {
                throw LuaError.runtime("bad argument #2 to 'Create' (Panel expected)")
            }
            parentIdentifier = descriptor.identifier
        } else {
            parentIdentifier = nil
        }

        let resolution = try resolveClassChain(className)
        guard let resolution else { return .nilValue }

        lock.lock()
        let identifier = nextPanelIdentifier
        nextPanelIdentifier += 1
        lock.unlock()

        let descriptor = GMLuaPanelValue(
            identifier: identifier,
            engineClassName: resolution.engineClassName,
            requestedClassName: className,
            name: name ?? className,
            parentIdentifier: parentIdentifier
        )
        let value = try typeSystem.makeObject(metaName: "Panel", payload: descriptor)
        lock.lock()
        panels[identifier] = value
        lock.unlock()

        do {
            try state.setRawTableValue(.number(0), for: .string("x"), in: descriptor.instanceTable)
            try state.setRawTableValue(.number(0), for: .string("y"), in: descriptor.instanceTable)
            try state.setRawTableValue(
                .string(LuaString(className)),
                for: .string("ClassName"),
                in: descriptor.instanceTable
            )
            for control in resolution.controlsBaseFirst {
                try prepare(descriptor, using: control)
                let initializer = try state.call(
                    semanticIndex,
                    arguments: [.table(descriptor.instanceTable), .string("Init")]
                ).first ?? .nilValue
                if case .luaFunction = initializer {
                    _ = try callVGUIFunction(initializer, arguments: [value])
                } else if case .nativeFunction = initializer {
                    _ = try callVGUIFunction(initializer, arguments: [value])
                }
            }
            return value
        } catch {
            destroy(identifier: identifier)
            throw error
        }
    }

    /// Marks exactly this panel for native VGUI's deferred deletion pass.
    /// Descendants remain valid for the rest of the current frame, matching
    /// Panel:Remove, but the marked panel itself immediately fails IsValid.
    fileprivate func markForDeletion(identifier: Int) {
        let value: LuaValue
        lock.lock()
        guard let storedValue = panels[identifier],
              let descriptor = panelDescriptor(from: storedValue),
              GMLuaTypeSystem.typedObject(from: storedValue)?.isValid == true else {
            lock.unlock()
            return
        }
        descriptor.isMarkedForDeletion = true
        value = storedValue

        let affectedIdentifiers = Set(descendantIdentifiers(of: identifier))
        for affectedIdentifier in affectedIdentifiers {
            pendingDockSizeChanges.removeValue(forKey: affectedIdentifier)
        }
        if let hoveredPanelIdentifier,
           affectedIdentifiers.contains(hoveredPanelIdentifier) {
            self.hoveredPanelIdentifier = nil
        }
        if let pressedPanelIdentifier,
           affectedIdentifiers.contains(pressedPanelIdentifier) {
            self.pressedPanelIdentifier = nil
        }
        if let mouseCapturePanelIdentifier,
           affectedIdentifiers.contains(mouseCapturePanelIdentifier) {
            self.mouseCapturePanelIdentifier = nil
        }
        if let focusedPanelIdentifier,
           affectedIdentifiers.contains(focusedPanelIdentifier) {
            self.focusedPanelIdentifier = nil
        }
        lock.unlock()

        GMLuaTypeSystem.typedObject(from: value)?.isValid = false
    }

    /// Completes deletion after the deferred frame interval. This remains a
    /// separate operation from markForDeletion so construction failures can
    /// discard incomplete panels without exposing a fictitious live frame.
    private func destroy(identifier: Int) {
        lock.lock()
        let identifiers = descendantIdentifiers(of: identifier)
        let removed = identifiers.compactMap { panels.removeValue(forKey: $0) }
        let removedIdentifiers = Set(identifiers)
        for removedIdentifier in removedIdentifiers {
            pendingDockSizeChanges.removeValue(forKey: removedIdentifier)
        }
        if let hoveredPanelIdentifier,
           removedIdentifiers.contains(hoveredPanelIdentifier) {
            self.hoveredPanelIdentifier = nil
        }
        if let pressedPanelIdentifier,
           removedIdentifiers.contains(pressedPanelIdentifier) {
            self.pressedPanelIdentifier = nil
        }
        if let mouseCapturePanelIdentifier,
           removedIdentifiers.contains(mouseCapturePanelIdentifier) {
            self.mouseCapturePanelIdentifier = nil
        }
        if let focusedPanelIdentifier,
           removedIdentifiers.contains(focusedPanelIdentifier) {
            self.focusedPanelIdentifier = nil
        }
        lock.unlock()
        for value in removed {
            panelDescriptor(from: value)?.isMarkedForDeletion = false
            GMLuaTypeSystem.typedObject(from: value)?.isValid = false
        }
    }

    private func finalizeMarkedPanelRemovals() {
        lock.lock()
        let markedIdentifiers = panels.compactMap { identifier, value in
            panelDescriptor(from: value)?.isMarkedForDeletion == true ? identifier : nil
        }.sorted()
        lock.unlock()

        for identifier in markedIdentifiers {
            destroy(identifier: identifier)
        }
    }

    fileprivate func panel(identifier: Int?) -> LuaValue? {
        guard let identifier else { return nil }
        lock.lock()
        let value = panels[identifier]
        lock.unlock()
        guard let value,
              GMLuaTypeSystem.typedObject(from: value)?.isValid == true else { return nil }
        return value
    }

    /// GetParent must preserve the marked-but-not-yet-deleted userdata so the
    /// stock controlpanel module can inspect IsMarkedForDeletion on an invalid
    /// ancestor during the documented one-frame removal interval.
    fileprivate func retainedPanel(identifier: Int?) -> LuaValue? {
        guard let identifier else { return nil }
        lock.lock()
        let value = panels[identifier]
        lock.unlock()
        guard let value,
              let descriptor = panelDescriptor(from: value),
              GMLuaTypeSystem.typedObject(from: value)?.isValid == true ||
                descriptor.isMarkedForDeletion else { return nil }
        return value
    }

    fileprivate func hoveredPanel() -> LuaValue? {
        lock.lock()
        let identifier = hoveredPanelIdentifier
        lock.unlock()
        return panel(identifier: identifier)
    }

    fileprivate func keyboardFocusPanel() -> LuaValue? {
        lock.lock()
        let identifier = focusedPanelIdentifier
        lock.unlock()
        return panel(identifier: identifier)
    }

    /// Screen-space coordinates of the latest pointer sent through this same
    /// registry's hit tester. A missing/cancelled pointer uses GMod's hidden
    /// cursor sentinel of zero for both gui.MouseX and gui.MouseY.
    fileprivate func logicalPointerCoordinates() -> (x: Double, y: Double) {
        lock.lock()
        defer { lock.unlock() }
        return logicalPointerPosition ?? (x: 0, y: 0)
    }

    fileprivate func setParent(identifier: Int, parentIdentifier: Int?) throws {
        lock.lock()
        guard let value = panels[identifier],
              let descriptor = panelDescriptor(from: value),
              GMLuaTypeSystem.typedObject(from: value)?.isValid == true else {
            lock.unlock()
            throw LuaError.runtime("invalid Panel")
        }
        let previousParentIdentifier = descriptor.parentIdentifier
        guard previousParentIdentifier != parentIdentifier else {
            lock.unlock()
            return
        }
        if let parentIdentifier {
            guard let parentValue = panels[parentIdentifier],
                  GMLuaTypeSystem.typedObject(from: parentValue)?.isValid == true else {
                lock.unlock()
                throw LuaError.runtime("invalid parent Panel")
            }

            var current: Int? = parentIdentifier
            var visited: Set<Int> = []
            while let candidate = current {
                guard visited.insert(candidate).inserted else {
                    lock.unlock()
                    throw LuaError.runtime("cycle in Panel parent hierarchy")
                }
                guard candidate != identifier else {
                    lock.unlock()
                    throw LuaError.runtime("a Panel cannot be parented to its descendant")
                }
                current = panels[candidate].flatMap { panelDescriptor(from: $0) }?.parentIdentifier
            }
        }
        guard descriptor.parentChangeDispatchDepth < 64 else {
            lock.unlock()
            throw LuaError.runtime(
                "Panel parent-change callback recursion limit exceeded for " +
                    "'\(descriptor.requestedClassName)'"
            )
        }
        descriptor.parentIdentifier = parentIdentifier
        descriptor.isParentedToHUD = false
        descriptor.parentChangeDispatchDepth += 1
        lock.unlock()

        defer {
            lock.lock()
            descriptor.parentChangeDispatchDepth -= 1
            lock.unlock()
        }
        if let previousParentIdentifier {
            _ = try callPanelMethod(
                identifier: previousParentIdentifier,
                name: "OnChildRemoved",
                arguments: [value]
            )
        }

        // A removal callback is allowed to reparent or remove the child. Only
        // notify the requested new parent if that relationship still exists.
        lock.lock()
        let shouldNotifyAdded = descriptor.parentIdentifier == parentIdentifier &&
            panels[identifier] != nil &&
            GMLuaTypeSystem.typedObject(from: value)?.isValid == true
        lock.unlock()
        if shouldNotifyAdded, let parentIdentifier {
            _ = try callPanelMethod(
                identifier: parentIdentifier,
                name: "OnChildAdded",
                arguments: [value]
            )
        }
    }

    fileprivate func parentToHUD(identifier: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let value = panels[identifier],
              let descriptor = panelDescriptor(from: value),
              GMLuaTypeSystem.typedObject(from: value)?.isValid == true else {
            throw LuaError.runtime("invalid Panel")
        }
        descriptor.parentIdentifier = nil
        descriptor.isParentedToHUD = true
    }

    fileprivate func children(of identifier: Int) -> [LuaValue] {
        lock.lock()
        defer { lock.unlock() }
        return panels.keys.sorted().compactMap { childIdentifier in
            guard let value = panels[childIdentifier],
                  let child = panelDescriptor(from: value),
                  child.parentIdentifier == identifier,
                  GMLuaTypeSystem.typedObject(from: value)?.isValid == true else { return nil }
            return value
        }
    }

    /// Returns the documented VGUI child extent: the farthest direct child's
    /// lower-right corner measured from the parent's upper-left corner.
    /// Docking and margins affect this only after layout has updated the
    /// child's stored position and size; they are not extra extent here.
    fileprivate func childrenSize(of identifier: Int) -> (width: Double, height: Double) {
        lock.lock()
        defer { lock.unlock() }
        var width = 0.0
        var height = 0.0
        for value in panels.values {
            guard let child = panelDescriptor(from: value),
                  child.parentIdentifier == identifier,
                  GMLuaTypeSystem.typedObject(from: value)?.isValid == true else { continue }
            width = max(width, child.x + child.width)
            height = max(height, child.y + child.height)
        }
        return (width, height)
    }

    fileprivate func noteSizeToChildrenDependency(
        for panel: GMLuaPanelValue,
        width: Bool,
        height: Bool
    ) {
        lock.lock()
        if width { panel.sizesToChildrenWidth = true }
        if height { panel.sizesToChildrenHeight = true }
        lock.unlock()
    }

    /// Must be called while `lock` is held. `SizeToChildren` makes a panel's
    /// next layout dependent on the lower-right extent of its direct children.
    /// If a child changes that measured extent after its parent has already run
    /// in the current frame, queue only that dependency chain for a bounded
    /// fixed-point pass.
    private func invalidateSizeDependentParentLocked(
        for child: GMLuaPanelValue,
        oldBounds: (x: Double, y: Double, width: Double, height: Double),
        newBounds: (x: Double, y: Double, width: Double, height: Double)
    ) {
        guard let parentIdentifier = child.parentIdentifier,
              let parentValue = panels[parentIdentifier],
              let parent = panelDescriptor(from: parentValue),
              GMLuaTypeSystem.typedObject(from: parentValue)?.isValid == true else {
            return
        }
        let widthChanged = oldBounds.x + oldBounds.width != newBounds.x + newBounds.width
        let heightChanged = oldBounds.y + oldBounds.height != newBounds.y + newBounds.height
        guard (parent.sizesToChildrenWidth && widthChanged) ||
                (parent.sizesToChildrenHeight && heightChanged) else {
            return
        }
        parent.isLayoutInvalidated = true
        pendingDependentLayoutIdentifiers.insert(parentIdentifier)
    }

    fileprivate func hasParent(identifier: Int, ancestorIdentifier: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var current = panels[identifier].flatMap { panelDescriptor(from: $0) }?.parentIdentifier
        var visited: Set<Int> = []
        while let candidate = current, visited.insert(candidate).inserted {
            if candidate == ancestorIdentifier { return true }
            current = panels[candidate].flatMap { panelDescriptor(from: $0) }?.parentIdentifier
        }
        return false
    }

    /// Returns the panel's upper-left corner in screen coordinates by walking
    /// the actual native parent graph. Keeping this in the registry makes
    /// LocalToScreen and ScreenToLocal share the same validity and cycle
    /// checks instead of relying on the most recent render snapshot.
    fileprivate func screenOrigin(identifier: Int) throws -> (x: Double, y: Double) {
        lock.lock()
        defer { lock.unlock() }

        var originX = 0.0
        var originY = 0.0
        var current: Int? = identifier
        var visited: Set<Int> = []
        while let currentIdentifier = current {
            guard visited.insert(currentIdentifier).inserted else {
                throw LuaError.runtime("cycle in Panel parent hierarchy")
            }
            guard let value = panels[currentIdentifier],
                  GMLuaTypeSystem.typedObject(from: value)?.isValid == true,
                  let panel = panelDescriptor(from: value) else {
                throw LuaError.runtime("invalid Panel in parent hierarchy")
            }
            originX += panel.x
            originY += panel.y
            current = panel.parentIdentifier
        }
        return (originX, originY)
    }

    fileprivate func setKeyboardInputEnabled(identifier: Int, enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        var pending = [identifier]
        var visited: Set<Int> = []
        while let current = pending.popLast(), visited.insert(current).inserted {
            guard let value = panels[current],
                  let descriptor = panelDescriptor(from: value),
                  GMLuaTypeSystem.typedObject(from: value)?.isValid == true else { continue }
            descriptor.keyboardInputEnabled = enabled
            for (childIdentifier, childValue) in panels {
                guard panelDescriptor(from: childValue)?.parentIdentifier == current else { continue }
                pending.append(childIdentifier)
            }
        }
    }

    fileprivate func focus(identifier: Int) {
        lock.lock()
        focusedPanelIdentifier = identifier
        lock.unlock()
    }

    fileprivate func isFocused(identifier: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return focusedPanelIdentifier == identifier
    }

    fileprivate func setMouseCapture(identifier: Int, captured: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard panels[identifier] != nil else { return }
        if captured {
            mouseCapturePanelIdentifier = identifier
        } else if mouseCapturePanelIdentifier == identifier {
            mouseCapturePanelIdentifier = nil
        }
    }

    fileprivate func invalidateLayout(identifier: Int, layoutNow: Bool) throws {
        let shouldPerformImmediately: Bool
        lock.lock()
        guard let value = panels[identifier],
              let descriptor = panelDescriptor(from: value),
              GMLuaTypeSystem.typedObject(from: value)?.isValid == true else {
            lock.unlock()
            throw LuaError.runtime("invalid Panel")
        }
        descriptor.isLayoutInvalidated = true
        shouldPerformImmediately = layoutNow && !descriptor.isPerformingLayout
        lock.unlock()

        if shouldPerformImmediately {
            _ = try performLayout(identifier: identifier)
        }
    }

    /// Dispatches deferred Lua `PerformLayout` hooks at a host-selected VGUI
    /// frame boundary. Each panel present at the start is visited at most once;
    /// a hook that invalidates itself remains pending for a later boundary.
    ///
    /// This advances logical Lua layout only. It does not claim UIKit, docking,
    /// clipping, hit-testing, or renderer-backed geometry is implemented.
    @discardableResult
    public func performPendingLayouts(maxLayouts: Int = .max) throws -> Int {
        finalizeMarkedPanelRemovals()
        guard maxLayouts > 0 else { return 0 }

        lock.lock()
        let identifiers = panels.keys.sorted().filter { identifier in
            guard let value = panels[identifier],
                  let descriptor = panelDescriptor(from: value) else { return false }
            return descriptor.isLayoutInvalidated &&
                !descriptor.isPerformingLayout &&
                GMLuaTypeSystem.typedObject(from: value)?.isValid == true
        }
        lock.unlock()

        var performed = 0
        for identifier in identifiers.prefix(maxLayouts) {
            if try performLayout(identifier: identifier) {
                performed += 1
            }
        }
        return performed
    }

    /// Settles only layout work introduced by an already-observed
    /// `SizeToChildren` dependency. Ordinary deferred invalidation keeps the
    /// public one-pass contract above, while a late child resize can revisit
    /// the exact ancestor chain that measured it before the frame is painted.
    /// Both total work and per-panel recursion are bounded and fail loudly.
    private func performDependentLayoutsToFixedPoint(
        maxLayouts: Int = 16_384,
        maxLayoutsPerPanel: Int = 64
    ) throws -> Int {
        var performed = 0
        var visits: [Int: Int] = [:]

        while true {
            let identifier: Int?
            let diagnostic: String?
            lock.lock()
            if performed >= maxLayouts, !pendingDependentLayoutIdentifiers.isEmpty {
                diagnostic = pendingDependentLayoutIdentifiers.sorted().prefix(8).map { pending in
                    let className = panels[pending]
                        .flatMap { panelDescriptor(from: $0) }?.requestedClassName ?? "<removed>"
                    return "\(pending):\(className)"
                }.joined(separator: ",")
                identifier = nil
            } else {
                diagnostic = nil
                identifier = pendingDependentLayoutIdentifiers.min()
                if let identifier {
                    pendingDependentLayoutIdentifiers.remove(identifier)
                }
            }
            lock.unlock()

            if let diagnostic {
                throw LuaError.runtime(
                    "VGUI dependent layout fixed-point exceeded \(maxLayouts) passes; " +
                        "pending=\(diagnostic)"
                )
            }
            guard let identifier else { return performed }

            lock.lock()
            let isPending = panels[identifier].flatMap { value -> Bool? in
                guard let descriptor = panelDescriptor(from: value) else { return nil }
                return descriptor.isLayoutInvalidated &&
                    !descriptor.isPerformingLayout &&
                    GMLuaTypeSystem.typedObject(from: value)?.isValid == true
            } ?? false
            lock.unlock()
            guard isPending else { continue }

            let visitCount = visits[identifier, default: 0] + 1
            guard visitCount <= maxLayoutsPerPanel else {
                lock.lock()
                let className = panels[identifier]
                    .flatMap { panelDescriptor(from: $0) }?.requestedClassName ?? "<removed>"
                lock.unlock()
                throw LuaError.runtime(
                    "VGUI dependent layout fixed-point recursion limit exceeded for " +
                        "'\(className)' (panel \(identifier))"
                )
            }
            visits[identifier] = visitCount

            if try performLayout(identifier: identifier) {
                performed += 1
                lock.lock()
                if let value = panels[identifier],
                   let descriptor = panelDescriptor(from: value),
                   descriptor.isLayoutInvalidated,
                   GMLuaTypeSystem.typedObject(from: value)?.isValid == true {
                    pendingDependentLayoutIdentifiers.insert(identifier)
                }
                lock.unlock()
            }
        }
    }

    private var hasPendingDependentLayouts: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !pendingDependentLayoutIdentifiers.isEmpty
    }

    private func performLayout(identifier: Int) throws -> Bool {
        let value: LuaValue
        let descriptor: GMLuaPanelValue

        lock.lock()
        guard let storedValue = panels[identifier],
              let storedDescriptor = panelDescriptor(from: storedValue),
              storedDescriptor.isLayoutInvalidated,
              !storedDescriptor.isPerformingLayout,
              GMLuaTypeSystem.typedObject(from: storedValue)?.isValid == true else {
            lock.unlock()
            return false
        }
        value = storedValue
        descriptor = storedDescriptor
        descriptor.isLayoutInvalidated = false
        descriptor.isPerformingLayout = true
        lock.unlock()

        var succeeded = false
        defer {
            lock.lock()
            descriptor.isPerformingLayout = false
            if succeeded {
                completedLayoutPasses &+= 1
            } else if panels[identifier] != nil,
                      GMLuaTypeSystem.typedObject(from: value)?.isValid == true {
                descriptor.isLayoutInvalidated = true
            }
            lock.unlock()
        }

        let callback = try state.call(
            semanticIndex,
            arguments: [.table(descriptor.instanceTable), .string("PerformLayout")]
        ).first ?? .nilValue
        if case .luaFunction = callback {
            _ = try callVGUIFunction(callback, arguments: [
                value, .number(descriptor.width), .number(descriptor.height)
            ])
        } else if case .nativeFunction = callback {
            _ = try callVGUIFunction(callback, arguments: [
                value, .number(descriptor.width), .number(descriptor.height)
            ])
        }
        succeeded = true
        return true
    }

    fileprivate func allPanels() -> [LuaValue] {
        lock.lock()
        defer { lock.unlock() }
        return panels.keys.sorted().compactMap { identifier in
            guard let value = panels[identifier],
                  GMLuaTypeSystem.typedObject(from: value)?.isValid == true else { return nil }
            return value
        }
    }

    fileprivate func prepare(_ descriptor: GMLuaPanelValue) throws {
        let classValue = try state.rawTableValue(
            for: .string("ClassName"),
            in: descriptor.instanceTable
        )
        if case let .string(className) = classValue {
            descriptor.requestedClassName = className.utf8String
        }

        var table = control(named: descriptor.requestedClassName)
        if table == nil,
           case let .table(vgui) = state.getGlobal("vgui") {
            let getter = try state.rawTableValue(for: .string("GetControlTable"), in: vgui)
            if case .luaFunction = getter {
                if case let .table(found) = try state.call(
                    getter,
                    arguments: [.string(LuaString(descriptor.requestedClassName))]
                ).first ?? .nilValue {
                    table = found
                }
            } else if case .nativeFunction = getter,
                      case let .table(found) = try state.call(
                        getter,
                        arguments: [.string(LuaString(descriptor.requestedClassName))]
                      ).first ?? .nilValue {
                table = found
            }
        }
        if let table { try prepare(descriptor, using: table) }
    }

    private func prepare(_ descriptor: GMLuaPanelValue, using control: LuaTable) throws {
        let proxyMetatable = LuaTable()
        try state.setRawTableValue(
            .table(control),
            for: .string("__index"),
            in: proxyMetatable
        )
        descriptor.instanceTable.metatable = proxyMetatable
    }

    private func resolveClassChain(
        _ requestedClassName: String
    ) throws -> (engineClassName: String, controlsBaseFirst: [LuaTable])? {
        if Self.engineClassNames.contains(requestedClassName) {
            return (requestedClassName, [])
        }

        var current = requestedClassName
        var visited: Set<String> = []
        var derivedFirst: [LuaTable] = []
        while !Self.engineClassNames.contains(current) {
            guard visited.insert(current).inserted else {
                throw LuaError.runtime("loop in VGUI base classes for '\(requestedClassName)'")
            }
            guard let control = control(named: current) else { return nil }
            derivedFirst.append(control)
            let base = try state.rawTableValue(for: .string("Base"), in: control)
            guard case let .string(baseName) = base else { return nil }
            current = baseName.utf8String
        }
        return (current, Array(derivedFirst.reversed()))
    }

    private func descendantIdentifiers(of root: Int) -> [Int] {
        var result: [Int] = []
        var pending = [root]
        var visited: Set<Int> = []
        while let current = pending.popLast() {
            guard visited.insert(current).inserted else { continue }
            result.append(current)
            for (identifier, value) in panels {
                guard let descriptor = panelDescriptor(from: value),
                      descriptor.parentIdentifier == current else { continue }
                pending.append(identifier)
            }
        }
        return result
    }

    fileprivate func setSemanticIndex(_ value: LuaValue) {
        semanticIndex = value
    }
}

public enum GMLuaVGUI {
    @discardableResult
    public static func install(
        into state: LuaState,
        typeSystem: GMLuaTypeSystem,
        screenMetrics: GMLuaScreenMetrics? = nil,
        surfaceCommandState: GMLuaSurfaceCommandState? = nil
    ) throws -> GMLuaVGUIRegistry {
        guard let panelMetatable = typeSystem.metatable(named: "Panel") else {
            throw LuaError.runtime("GLua Panel metatable was not installed")
        }
        let registry = GMLuaVGUIRegistry(
            state: state,
            typeSystem: typeSystem,
            panelMetatable: panelMetatable,
            screenMetrics: screenMetrics,
            surfaceCommandState: surfaceCommandState
        )
        let semanticIndex = try state.executeReturningValues(
            "return function(container, key) return container[key] end",
            sourceName: "=[GModLua VGUI index helper]"
        ).first ?? .nilValue
        registry.setSemanticIndex(semanticIndex)

        let panelIndex = nativeFunction(
            name: "Panel.__index",
            registry: registry
        ) { arguments in
            guard arguments.count >= 2,
                  let descriptor = panelDescriptor(from: arguments[0]) else {
                return [.nilValue]
            }
            if case let .string(key) = arguments[1] {
                switch key.utf8String {
                case "x": return [.number(descriptor.x)]
                case "y": return [.number(descriptor.y)]
                default: break
                }
            }
            let value = try state.call(
                semanticIndex,
                arguments: [.table(descriptor.instanceTable), arguments[1]]
            ).first ?? .nilValue
            if !isNil(value) { return [value] }
            let nativeValue = try state.rawTableValue(for: arguments[1], in: panelMetatable)
            if !isNil(nativeValue) { return [nativeValue] }
            guard case let .string(key) = arguments[1],
                  isLikelyVGUIMethodName(key.utf8String) else {
                return [.nilValue]
            }
            registry.noteMissingMemberLookup(
                panel: descriptor,
                methodName: key.utf8String
            )
            return [.nilValue]
        }
        let panelNewIndex = nativeFunction(
            name: "Panel.__newindex",
            registry: registry
        ) { arguments in
            guard arguments.count >= 3,
                  let descriptor = panelDescriptor(from: arguments[0]) else {
                throw LuaError.runtime("attempt to index an invalid Panel")
            }
            if case let .string(key) = arguments[1],
               key.utf8String == "x" || key.utf8String == "y" {
                guard case let .number(coordinate) = arguments[2], coordinate.isFinite else {
                    throw LuaError.runtime(
                        "Panel.\(key.utf8String) requires a finite number"
                    )
                }
                if key.utf8String == "x" {
                    descriptor.x = coordinate
                } else {
                    descriptor.y = coordinate
                }
            }
            try state.setRawTableValue(
                arguments[2],
                for: arguments[1],
                in: descriptor.instanceTable
            )
            return []
        }
        try set(panelIndex, "__index", panelMetatable, state)
        try set(panelNewIndex, "__newindex", panelMetatable, state)

        try installPanelMethods(
            state: state,
            registry: registry,
            panelMetatable: panelMetatable
        )

        let vgui = LuaTable()
        let register = nativeFunction(name: "vgui.Register", registry: registry) { arguments in
            let className = try requiredString(arguments, 0, "Register")
            guard arguments.indices.contains(1), case let .table(control) = arguments[1] else {
                throw LuaError.runtime("bad argument #2 to 'Register' (table expected)")
            }
            let baseName = try optionalString(arguments, 2, "Panel", "Register")
            try registry.registerControl(name: className, table: control, baseName: baseName)
            state.setGlobal("PANEL", value: .nilValue)
            return [.table(control)]
        }
        let getControlTable = nativeFunction(
            name: "vgui.GetControlTable",
            registry: registry
        ) { arguments in
            let className = try requiredString(arguments, 0, "GetControlTable")
            return [registry.control(named: className).map(LuaValue.table) ?? .nilValue]
        }
        let exists = nativeFunction(name: "vgui.Exists", registry: registry) { arguments in
            let className = try requiredString(arguments, 0, "Exists")
            return [.boolean(registry.control(named: className) != nil)]
        }
        let create = nativeFunction(name: "vgui.Create", registry: registry) { arguments in
            let className = try requiredString(arguments, 0, "Create")
            let parent = arguments.indices.contains(1) ? arguments[1] : nil
            let name: String?
            if arguments.indices.contains(2), !isNil(arguments[2]) {
                name = try requiredString(arguments, 2, "Create")
            } else {
                name = nil
            }
            return [try registry.create(className: className, parent: parent, name: name)]
        }
        let getAll = nativeFunction(name: "vgui.GetAll", registry: registry) { _ in
            let table = LuaTable()
            for (offset, value) in registry.allPanels().enumerated() {
                try state.setRawTableValue(
                    value,
                    for: .number(Double(offset + 1)),
                    in: table
                )
            }
            return [.table(table)]
        }
        let getHoveredPanel = nativeFunction(
            name: "vgui.GetHoveredPanel",
            registry: registry
        ) { _ in
            [registry.hoveredPanel() ?? .nilValue]
        }
        let getKeyboardFocus = nativeFunction(
            name: "vgui.GetKeyboardFocus",
            registry: registry
        ) { _ in
            [registry.keyboardFocusPanel() ?? .nilValue]
        }

        for (name, value) in [
            ("Register", register), ("GetControlTable", getControlTable),
            ("Exists", exists), ("Create", create), ("GetAll", getAll),
            ("GetHoveredPanel", getHoveredPanel),
            ("GetKeyboardFocus", getKeyboardFocus)
        ] {
            try set(value, name, vgui, state)
        }
        state.setGlobal("vgui", value: .table(vgui))

        let gui: LuaTable
        if case let .table(existing) = state.getGlobal("gui") {
            gui = existing
        } else {
            gui = LuaTable()
        }
        let mouseX = nativeFunction(name: "gui.MouseX", registry: registry) { _ in
            [.number(registry.logicalPointerCoordinates().x)]
        }
        let mouseY = nativeFunction(name: "gui.MouseY", registry: registry) { _ in
            [.number(registry.logicalPointerCoordinates().y)]
        }
        try set(mouseX, "MouseX", gui, state)
        try set(mouseY, "MouseY", gui, state)
        state.setGlobal("gui", value: .table(gui))

        for (name, value) in [
            ("NODOCK", GMLuaPanelDock.none.rawValue),
            ("TOP", GMLuaPanelDock.top.rawValue),
            ("LEFT", GMLuaPanelDock.left.rawValue),
            ("RIGHT", GMLuaPanelDock.right.rawValue),
            ("BOTTOM", GMLuaPanelDock.bottom.rawValue),
            ("FILL", GMLuaPanelDock.fill.rawValue),
            ("MOUSE_LEFT", 107), ("MOUSE_RIGHT", 108), ("MOUSE_MIDDLE", 109)
        ] {
            state.setGlobal(name, value: .number(Double(value)))
        }
        return registry
    }

    private static func installPanelMethods(
        state: LuaState,
        registry: GMLuaVGUIRegistry,
        panelMetatable: LuaTable
    ) throws {
        let methods: [(String, LuaNativeFunction)] = [
            ("GetTable", { arguments in
                [.table(try requiredPanel(arguments, "GetTable").instanceTable)]
            }),
            ("GetName", { arguments in
                [.string(LuaString(try requiredPanel(arguments, "GetName").name))]
            }),
            ("SetName", { arguments in
                let panel = try requiredPanel(arguments, "SetName")
                panel.name = try requiredString(arguments, 1, "SetName")
                return []
            }),
            ("GetClassName", { arguments in
                let panel = try requiredPanel(arguments, "GetClassName")
                return [.string(LuaString(panel.requestedClassName))]
            }),
            ("IsLoading", { arguments in
                let panel = try requiredHTMLPanel(arguments, "IsLoading")
                return [.boolean(panel.htmlDocumentLoadState == .loading)]
            }),
            ("NewObject", { arguments in
                let panel = try requiredHTMLPanel(arguments, "NewObject")
                let objectName = try requiredLuaString(arguments, 1, "NewObject")
                if !panel.htmlJavaScriptObjects.contains(objectName) {
                    panel.htmlJavaScriptObjects.append(objectName)
                }
                return []
            }),
            ("NewObjectCallback", { arguments in
                let panel = try requiredHTMLPanel(arguments, "NewObjectCallback")
                let registration = GMLuaHTMLJavaScriptCallbackSnapshot(
                    objectName: try requiredLuaString(arguments, 1, "NewObjectCallback"),
                    callbackName: try requiredLuaString(arguments, 2, "NewObjectCallback")
                )
                if !panel.htmlJavaScriptCallbacks.contains(registration) {
                    panel.htmlJavaScriptCallbacks.append(registration)
                }
                return []
            }),
            ("OpenURL", { arguments in
                let panel = try requiredHTMLPanel(arguments, "OpenURL")
                try registry.beginHTMLDocumentLoad(
                    panel,
                    url: try requiredLuaString(arguments, 1, "OpenURL"),
                    html: nil
                )
                return []
            }),
            ("SetHTML", { arguments in
                let panel = try requiredHTMLPanel(arguments, "SetHTML")
                try registry.beginHTMLDocumentLoad(
                    panel,
                    url: nil,
                    html: try requiredLuaString(arguments, 1, "SetHTML")
                )
                return []
            }),
            ("GetParent", { arguments in
                let panel = try requiredPanel(arguments, "GetParent")
                return [registry.retainedPanel(identifier: panel.parentIdentifier) ?? .nilValue]
            }),
            ("SetParent", { arguments in
                let panel = try requiredPanel(arguments, "SetParent")
                if arguments.count < 2 || isNil(arguments[1]) {
                    try registry.setParent(identifier: panel.identifier, parentIdentifier: nil)
                    return []
                }
                guard let parent = panelDescriptor(from: arguments[1]),
                      GMLuaTypeSystem.typedObject(from: arguments[1])?.isValid == true else {
                    throw LuaError.runtime("bad argument #1 to 'SetParent' (Panel expected)")
                }
                try registry.setParent(
                    identifier: panel.identifier,
                    parentIdentifier: parent.identifier
                )
                return []
            }),
            ("ParentToHUD", { arguments in
                let panel = try requiredPanel(arguments, "ParentToHUD")
                try registry.parentToHUD(identifier: panel.identifier)
                return []
            }),
            ("GetChildren", { arguments in
                let panel = try requiredPanel(arguments, "GetChildren")
                let result = LuaTable()
                for (offset, child) in registry.children(of: panel.identifier).enumerated() {
                    try state.setRawTableValue(
                        child,
                        for: .number(Double(offset + 1)),
                        in: result
                    )
                }
                return [.table(result)]
            }),
            ("ChildCount", { arguments in
                let panel = try requiredPanel(arguments, "ChildCount")
                return [.number(Double(registry.children(of: panel.identifier).count))]
            }),
            ("HasChildren", { arguments in
                let panel = try requiredPanel(arguments, "HasChildren")
                return [.boolean(!registry.children(of: panel.identifier).isEmpty)]
            }),
            ("GetChild", { arguments in
                let panel = try requiredPanel(arguments, "GetChild")
                let index = try requiredInteger(arguments, 1, "GetChild")
                let children = registry.children(of: panel.identifier)
                guard index >= 0, index < children.count else { return [.nilValue] }
                return [children[index]]
            }),
            ("HasParent", { arguments in
                let panel = try requiredPanel(arguments, "HasParent")
                guard arguments.indices.contains(1),
                      let ancestor = panelDescriptor(from: arguments[1]),
                      GMLuaTypeSystem.typedObject(from: arguments[1])?.isValid == true else {
                    return [.boolean(false)]
                }
                return [.boolean(registry.hasParent(
                    identifier: panel.identifier,
                    ancestorIdentifier: ancestor.identifier
                ))]
            }),
            ("SetPos", { arguments in
                let panel = try requiredPanel(arguments, "SetPos")
                let x = try requiredNumber(arguments, 1, "SetPos")
                let y = try requiredNumber(arguments, 2, "SetPos")
                registry.setPanelPosition(panel, x: x, y: y)
                try state.setRawTableValue(.number(x), for: .string("x"), in: panel.instanceTable)
                try state.setRawTableValue(.number(y), for: .string("y"), in: panel.instanceTable)
                return []
            }),
            ("GetPos", { arguments in
                let panel = try requiredPanel(arguments, "GetPos")
                return [.number(panel.x), .number(panel.y)]
            }),
            ("LocalToScreen", { arguments in
                let panel = try requiredPanel(arguments, "LocalToScreen")
                let x = try requiredNumber(arguments, 1, "LocalToScreen")
                let y = try requiredNumber(arguments, 2, "LocalToScreen")
                let origin = try registry.screenOrigin(identifier: panel.identifier)
                return [.number(origin.x + x), .number(origin.y + y)]
            }),
            ("ScreenToLocal", { arguments in
                let panel = try requiredPanel(arguments, "ScreenToLocal")
                let x = try requiredNumber(arguments, 1, "ScreenToLocal")
                let y = try requiredNumber(arguments, 2, "ScreenToLocal")
                let origin = try registry.screenOrigin(identifier: panel.identifier)
                return [.number(x - origin.x), .number(y - origin.y)]
            }),
            ("SetSize", { arguments in
                let panel = try requiredPanel(arguments, "SetSize")
                try registry.setPanelSize(
                    panel,
                    width: try requiredNumber(arguments, 1, "SetSize"),
                    height: try requiredNumber(arguments, 2, "SetSize")
                )
                return []
            }),
            ("SetWide", { arguments in
                let panel = try requiredPanel(arguments, "SetWide")
                try registry.setPanelSize(
                    panel,
                    width: try requiredNumber(arguments, 1, "SetWide"),
                    height: panel.height
                )
                return []
            }),
            ("SetTall", { arguments in
                let panel = try requiredPanel(arguments, "SetTall")
                try registry.setPanelSize(
                    panel,
                    width: panel.width,
                    height: try requiredNumber(arguments, 1, "SetTall")
                )
                return []
            }),
            ("GetSize", { arguments in
                let panel = try requiredPanel(arguments, "GetSize")
                return [.number(panel.width), .number(panel.height)]
            }),
            ("ChildrenSize", { arguments in
                let panel = try requiredPanel(arguments, "ChildrenSize")
                let size = registry.childrenSize(of: panel.identifier)
                return [.number(size.width), .number(size.height)]
            }),
            ("SizeToChildren", { arguments in
                let panel = try requiredPanel(arguments, "SizeToChildren")
                let sizeWidth = try optionalBoolean(
                    arguments,
                    1,
                    false,
                    "SizeToChildren"
                )
                let sizeHeight = try optionalBoolean(
                    arguments,
                    2,
                    false,
                    "SizeToChildren"
                )
                guard sizeWidth || sizeHeight else { return [] }
                registry.noteSizeToChildrenDependency(
                    for: panel,
                    width: sizeWidth,
                    height: sizeHeight
                )
                let childSize = registry.childrenSize(of: panel.identifier)
                try registry.setPanelSize(
                    panel,
                    width: sizeWidth ? childSize.width : panel.width,
                    height: sizeHeight ? childSize.height : panel.height
                )
                return []
            }),
            ("GetWide", { arguments in
                [.number(try requiredPanel(arguments, "GetWide").width)]
            }),
            ("GetTall", { arguments in
                [.number(try requiredPanel(arguments, "GetTall").height)]
            }),
            ("GetBounds", { arguments in
                let panel = try requiredPanel(arguments, "GetBounds")
                return [
                    .number(panel.x), .number(panel.y),
                    .number(panel.width), .number(panel.height)
                ]
            }),
            ("Dock", { arguments in
                let panel = try requiredPanel(arguments, "Dock")
                let raw = try requiredInteger(arguments, 1, "Dock")
                guard let dock = GMLuaPanelDock(rawValue: raw) else {
                    throw LuaError.runtime("bad argument #1 to 'Dock' (valid dock enum expected)")
                }
                panel.dock = dock
                return []
            }),
            ("GetDock", { arguments in
                [.number(Double(try requiredPanel(arguments, "GetDock").dock.rawValue))]
            }),
            ("DockMargin", { arguments in
                let panel = try requiredPanel(arguments, "DockMargin")
                panel.dockMargin = (
                    try requiredNumber(arguments, 1, "DockMargin"),
                    try requiredNumber(arguments, 2, "DockMargin"),
                    try requiredNumber(arguments, 3, "DockMargin"),
                    try requiredNumber(arguments, 4, "DockMargin")
                )
                return []
            }),
            ("DockPadding", { arguments in
                let panel = try requiredPanel(arguments, "DockPadding")
                panel.dockPadding = (
                    try requiredNumber(arguments, 1, "DockPadding"),
                    try requiredNumber(arguments, 2, "DockPadding"),
                    try requiredNumber(arguments, 3, "DockPadding"),
                    try requiredNumber(arguments, 4, "DockPadding")
                )
                return []
            }),
            ("SetClipChildren", { arguments in
                let panel = try requiredPanel(arguments, "SetClipChildren")
                panel.clipsChildren = try requiredBoolean(arguments, 1, "SetClipChildren")
                return []
            }),
            ("NoClipping", { arguments in
                let panel = try requiredPanel(arguments, "NoClipping")
                panel.disablesPaintClipping = try requiredBoolean(
                    arguments,
                    1,
                    "NoClipping"
                )
                return []
            }),
            ("Center", { arguments in
                let panel = try requiredPanel(arguments, "Center")
                if let parentValue = registry.panel(identifier: panel.parentIdentifier),
                   let parent = panelDescriptor(from: parentValue) {
                    panel.x = floor((parent.width - panel.width) * 0.5)
                    panel.y = floor((parent.height - panel.height) * 0.5)
                } else if panel.parentIdentifier == nil,
                          let viewport = registry.screenMetrics?.viewport {
                    panel.x = floor((Double(viewport.width) - panel.width) * 0.5)
                    panel.y = floor((Double(viewport.height) - panel.height) * 0.5)
                } else {
                    throw LuaError.runtime(
                        "Panel:Center requires a parent or an attached live viewport"
                    )
                }
                return []
            }),
            ("InvalidateLayout", { arguments in
                let panel = try requiredPanel(arguments, "InvalidateLayout")
                let layoutNow = try optionalBoolean(
                    arguments,
                    1,
                    false,
                    "InvalidateLayout"
                )
                try registry.invalidateLayout(
                    identifier: panel.identifier,
                    layoutNow: layoutNow
                )
                return []
            }),
            ("OnSizeChanged", { arguments in
                let panel = try requiredPanel(arguments, "OnSizeChanged")
                try registry.invalidateLayout(identifier: panel.identifier, layoutNow: false)
                return []
            }),
            ("PerformLayout", { arguments in
                let panel = try requiredPanel(arguments, "PerformLayout")
                // Source Panel::PerformLayout is an empty base virtual. Label
                // overrides it to size its TextImage against the panel width.
                try registry.performNativeLayout(panel)
                return []
            }),
            ("SetText", { arguments in
                let panel = try requiredTextPanel(arguments, "SetText")
                let supplied = try requiredLuaString(arguments, 1, "SetText")
                if panel.engineClassName == "Label" {
                    panel.text = LuaString(bytes: Array(supplied.bytes.prefix(1_023)))
                    try registry.invalidateLayout(identifier: panel.identifier, layoutNow: false)
                } else {
                    panel.text = supplied
                    if panel.engineClassName == "TextEntry" {
                        // Valve TextEntry::SetText replaces its stream, calls
                        // GotoTextStart, and clears selection before layout.
                        panel.caretPosition = 0
                    }
                }
                return []
            }),
            ("GetText", { arguments in
                let panel = try requiredTextPanel(arguments, "GetText")
                let text: LuaString
                if panel.engineClassName == "TextEntry" {
                    text = panel.text
                } else {
                    text = LuaString(bytes: Array(panel.text.bytes.prefix(1_023)))
                }
                return [.string(text)]
            }),
            ("GetValue", { arguments in
                let panel = try requiredPanel(arguments, "GetValue")
                guard panel.engineClassName == "Label" || panel.engineClassName == "TextEntry" else {
                    throw unsupportedPanelMethod(panel, "GetValue")
                }
                return [.string(LuaString(bytes: Array(panel.text.bytes.prefix(8_092))))]
            }),
            ("DrawTextEntryText", { arguments in
                let panel = try requiredTextEntry(arguments, "DrawTextEntryText")
                let textColor = try requiredPanelColorTable(
                    arguments,
                    index: 1,
                    state: state,
                    function: "DrawTextEntryText"
                )
                let highlightColor = try requiredPanelColorTable(
                    arguments,
                    index: 2,
                    state: state,
                    function: "DrawTextEntryText"
                )
                let cursorColor = try requiredPanelColorTable(
                    arguments,
                    index: 3,
                    state: state,
                    function: "DrawTextEntryText"
                )
                try registry.drawTextEntryText(
                    panel,
                    textColor: textColor,
                    highlightColor: highlightColor,
                    cursorColor: cursorColor
                )
                return []
            }),
            ("DrawFilledRect", { arguments in
                let panel = try requiredPanel(arguments, "DrawFilledRect")
                try registry.drawFilledRect(panel)
                return []
            }),
            ("DrawOutlinedRect", { arguments in
                let panel = try requiredPanel(arguments, "DrawOutlinedRect")
                try registry.drawOutlinedRect(panel)
                return []
            }),
            ("GetCaretPos", { arguments in
                let panel = try requiredTextEntry(arguments, "GetCaretPos")
                return [.number(Double(panel.caretPosition))]
            }),
            ("SetCaretPos", { arguments in
                let panel = try requiredTextEntry(arguments, "SetCaretPos")
                let requested = try requiredNumber(arguments, 1, "SetCaretPos")
                let characterCount = utf8CharacterCount(in: panel.text.bytes)
                if requested <= 0 {
                    panel.caretPosition = 0
                } else if requested >= Double(characterCount) {
                    panel.caretPosition = characterCount
                } else {
                    panel.caretPosition = Int(requested.rounded(.towardZero))
                }
                return []
            }),
            ("SetAllowNonAsciiCharacters", { arguments in
                let panel = try requiredTextEntry(arguments, "SetAllowNonAsciiCharacters")
                panel.allowsNonASCIICharacters = try requiredBoolean(
                    arguments,
                    1,
                    "SetAllowNonAsciiCharacters"
                )
                return []
            }),
            ("SetExpensiveShadow", { arguments in
                let panel = try requiredLabel(arguments, "SetExpensiveShadow")
                let distance = try requiredNumber(arguments, 1, "SetExpensiveShadow")
                let color = try requiredPanelColorTable(
                    arguments,
                    index: 2,
                    state: state,
                    function: "SetExpensiveShadow"
                )
                panel.expensiveShadow = GMLuaTextShadowSnapshot(
                    distance: distance,
                    color: color
                )
                return []
            }),
            ("SetFontInternal", { arguments in
                let panel = try requiredTextPanel(arguments, "SetFontInternal")
                panel.fontName = try requiredLuaString(arguments, 1, "SetFontInternal")
                return []
            }),
            ("SetFont", { arguments in
                let panel = try requiredTextPanel(arguments, "SetFont")
                panel.fontName = try requiredLuaString(arguments, 1, "SetFont")
                return []
            }),
            ("GetFont", { arguments in
                let panel = try requiredTextPanel(arguments, "GetFont")
                return [.string(panel.fontName)]
            }),
            ("SetTextInset", { arguments in
                let panel = try requiredTextPanel(arguments, "SetTextInset")
                guard panel.engineClassName == "Label" ||
                        panel.engineClassName == "TextEntry" else {
                    throw unsupportedPanelMethod(panel, "SetTextInset")
                }
                let x = try requiredCoercibleInteger(
                    arguments,
                    1,
                    "SetTextInset"
                )
                let y = try requiredCoercibleInteger(
                    arguments,
                    2,
                    "SetTextInset"
                )
                panel.textInsetX = x
                panel.textInsetY = y
                try registry.invalidateLayout(identifier: panel.identifier, layoutNow: false)
                return []
            }),
            ("GetTextInset", { arguments in
                let panel = try requiredLabel(arguments, "GetTextInset")
                return [
                    .number(Double(panel.textInsetX)),
                    .number(Double(panel.textInsetY))
                ]
            }),
            ("GetContentSize", { arguments in
                let panel = try requiredLabel(arguments, "GetContentSize")
                let measurement = try registry.labelContentSize(panel)
                return [
                    .number(Double(measurement.width)),
                    .number(Double(measurement.height))
                ]
            }),
            ("GetTextSize", { arguments in
                let panel = try requiredLabel(arguments, "GetTextSize")
                let measurement = try registry.labelTextSize(panel)
                return [
                    .number(Double(measurement.width)),
                    .number(Double(measurement.height))
                ]
            }),
            ("SizeToContents", { arguments in
                let panel = try requiredPanel(arguments, "SizeToContents")
                if panel.engineClassName == "Label" {
                    let measurement = try registry.labelContentSize(panel)
                    try registry.setPanelSize(
                        panel,
                        width: Double(measurement.width),
                        height: Double(measurement.height)
                    )
                } else {
                    // The native base Panel implementation sizes generic
                    // controls from their direct child extent. Scripted
                    // controls such as DNumSlider rely on this path, while
                    // Label-derived controls retain measured-text semantics.
                    let measurement = registry.childrenSize(of: panel.identifier)
                    try registry.setPanelSize(
                        panel,
                        width: measurement.width,
                        height: measurement.height
                    )
                }
                return []
            }),
            ("SizeToContentsX", { arguments in
                let panel = try requiredLabel(arguments, "SizeToContentsX")
                let additionalWidth = try optionalCoercibleNumber(
                    arguments,
                    1,
                    0,
                    "SizeToContentsX"
                )
                let measurement = try registry.labelContentSize(panel)
                panel.width = floor(Double(measurement.width) + additionalWidth)
                try registry.invalidateLayout(identifier: panel.identifier, layoutNow: false)
                return []
            }),
            ("SizeToContentsY", { arguments in
                let panel = try requiredLabel(arguments, "SizeToContentsY")
                let additionalHeight = try optionalCoercibleNumber(
                    arguments,
                    1,
                    0,
                    "SizeToContentsY"
                )
                let measurement = try registry.labelContentSize(panel)
                panel.height = floor(Double(measurement.height) + additionalHeight)
                try registry.invalidateLayout(identifier: panel.identifier, layoutNow: false)
                return []
            }),
            ("SetWrap", { arguments in
                let panel = try requiredLabel(arguments, "SetWrap")
                panel.wrapsText = try requiredBoolean(arguments, 1, "SetWrap")
                try registry.invalidateLayout(identifier: panel.identifier, layoutNow: false)
                return []
            }),
            ("SetFGColor", { arguments in
                let panel = try requiredTextPanel(arguments, "SetFGColor")
                panel.foregroundColor = try requiredPanelColor(
                    arguments,
                    state: state,
                    function: "SetFGColor"
                )
                return []
            }),
            ("GetFGColor", { arguments in
                let panel = try requiredTextPanel(arguments, "GetFGColor")
                guard let color = panel.foregroundColor else {
                    throw LuaError.runtime(
                        "Panel:GetFGColor has no logical scheme color before ApplySchemeSettings"
                    )
                }
                return [try makeColorValue(color, state: state)]
            }),
            ("SetContentAlignment", { arguments in
                let panel = try requiredLabel(arguments, "SetContentAlignment")
                let alignment = try requiredInteger(arguments, 1, "SetContentAlignment")
                guard (1...9).contains(alignment) else {
                    throw LuaError.runtime(
                        "bad argument #1 to 'SetContentAlignment' (alignment 1 through 9 expected)"
                    )
                }
                panel.contentAlignment = alignment
                try registry.invalidateLayout(identifier: panel.identifier, layoutNow: false)
                return []
            }),
            ("GetContentAlignment", { arguments in
                let panel = try requiredLabel(arguments, "GetContentAlignment")
                return [.number(Double(panel.contentAlignment))]
            }),
            ("SetImage", { arguments in
                let panel = try requiredPanel(arguments, "SetImage")
                panel.imageName = try requiredLuaString(arguments, 1, "SetImage")
                return []
            }),
            ("GetImage", { arguments in
                let panel = try requiredPanel(arguments, "GetImage")
                return [panel.imageName.map(LuaValue.string) ?? .nilValue]
            }),
            ("SetModel", { arguments in
                let panel = try requiredModelImage(arguments, "SetModel")
                let modelPath = try requiredLuaString(arguments, 1, "SetModel")
                let skin: Int
                if arguments.indices.contains(2), !isNil(arguments[2]) {
                    skin = try requiredInteger(arguments, 2, "SetModel")
                } else {
                    skin = 0
                }
                let bodyGroups: LuaString?
                if arguments.indices.contains(3), !isNil(arguments[3]) {
                    bodyGroups = try requiredLuaString(arguments, 3, "SetModel")
                } else {
                    bodyGroups = nil
                }
                panel.modelImagePath = modelPath
                panel.modelImageSkin = skin
                panel.modelImageBodyGroups = bodyGroups
                return []
            }),
            ("SetSpawnIcon", { arguments in
                let panel = try requiredModelImage(arguments, "SetSpawnIcon")
                panel.modelImageSpawnIconName = try requiredLuaString(
                    arguments,
                    1,
                    "SetSpawnIcon"
                )
                return []
            }),
            ("SetVisible", { arguments in
                let panel = try requiredPanel(arguments, "SetVisible")
                // Native VGUI uses Lua truth-value conversion. Stock
                // dtree_node.lua passes nil when both expander predicates are
                // false, which lua_toboolean correctly treats as false.
                panel.isVisible = luaTruthValue(arguments, 1)
                return []
            }),
            ("IsVisible", { arguments in
                [.boolean(try requiredPanel(arguments, "IsVisible").isVisible)]
            }),
            ("SetEnabled", { arguments in
                let panel = try requiredPanel(arguments, "SetEnabled")
                panel.isEnabled = try requiredBoolean(arguments, 1, "SetEnabled")
                return []
            }),
            ("IsEnabled", { arguments in
                [.boolean(try requiredPanel(arguments, "IsEnabled").isEnabled)]
            }),
            ("SetAlpha", { arguments in
                let panel = try requiredPanel(arguments, "SetAlpha")
                let alpha = try requiredNumber(arguments, 1, "SetAlpha")
                panel.alpha = min(255, max(0, alpha.rounded(.towardZero)))
                return []
            }),
            ("GetAlpha", { arguments in
                [.number(try requiredPanel(arguments, "GetAlpha").alpha)]
            }),
            ("SetMouseInputEnabled", { arguments in
                let panel = try requiredPanel(arguments, "SetMouseInputEnabled")
                panel.mouseInputEnabled = try requiredBoolean(
                    arguments,
                    1,
                    "SetMouseInputEnabled"
                )
                return []
            }),
            ("IsMouseInputEnabled", { arguments in
                [.boolean(try requiredPanel(arguments, "IsMouseInputEnabled").mouseInputEnabled)]
            }),
            ("SetWorldClicker", { arguments in
                let panel = try requiredPanel(arguments, "SetWorldClicker")
                panel.isWorldClicker = try requiredBoolean(arguments, 1, "SetWorldClicker")
                return []
            }),
            ("IsWorldClicker", { arguments in
                [.boolean(try requiredPanel(arguments, "IsWorldClicker").isWorldClicker)]
            }),
            ("MouseCapture", { arguments in
                let panel = try requiredPanel(arguments, "MouseCapture")
                registry.setMouseCapture(
                    identifier: panel.identifier,
                    captured: try requiredBoolean(arguments, 1, "MouseCapture")
                )
                return []
            }),
            ("SetKeyboardInputEnabled", { arguments in
                let panel = try requiredPanel(arguments, "SetKeyboardInputEnabled")
                registry.setKeyboardInputEnabled(
                    identifier: panel.identifier,
                    enabled: try requiredBoolean(arguments, 1, "SetKeyboardInputEnabled")
                )
                return []
            }),
            ("SetKeyBoardInputEnabled", { arguments in
                let panel = try requiredPanel(arguments, "SetKeyBoardInputEnabled")
                registry.setKeyboardInputEnabled(
                    identifier: panel.identifier,
                    enabled: try requiredBoolean(arguments, 1, "SetKeyBoardInputEnabled")
                )
                return []
            }),
            ("IsKeyboardInputEnabled", { arguments in
                [.boolean(try requiredPanel(arguments, "IsKeyboardInputEnabled").keyboardInputEnabled)]
            }),
            ("SetCursor", { arguments in
                let panel = try requiredPanel(arguments, "SetCursor")
                panel.cursorName = normalizedCursorName(
                    try requiredString(arguments, 1, "SetCursor")
                )
                return []
            }),
            ("SetDrawOnTop", { arguments in
                let panel = try requiredPanel(arguments, "SetDrawOnTop")
                registry.setDrawOnTop(
                    identifier: panel.identifier,
                    enabled: try optionalBoolean(arguments, 1, false, "SetDrawOnTop")
                )
                return []
            }),
            ("RequestFocus", { arguments in
                let panel = try requiredPanel(arguments, "RequestFocus")
                registry.focus(identifier: panel.identifier)
                return []
            }),
            ("HasFocus", { arguments in
                let panel = try requiredPanel(arguments, "HasFocus")
                return [.boolean(registry.isFocused(identifier: panel.identifier))]
            }),
            ("MakePopup", { arguments in
                let panel = try requiredPanel(arguments, "MakePopup")
                registry.makePopup(identifier: panel.identifier)
                return []
            }),
            ("IsPopup", { arguments in
                [.boolean(try requiredPanel(arguments, "IsPopup").isPopup)]
            }),
            ("MoveToBack", { arguments in
                let panel = try requiredPanel(arguments, "MoveToBack")
                registry.moveToStackEdge(identifier: panel.identifier, front: false)
                return []
            }),
            ("MoveToFront", { arguments in
                let panel = try requiredPanel(arguments, "MoveToFront")
                registry.moveToStackEdge(identifier: panel.identifier, front: true)
                return []
            }),
            ("SetPaintBackgroundEnabled", { arguments in
                let panel = try requiredPanel(arguments, "SetPaintBackgroundEnabled")
                panel.paintBackgroundEnabled = try requiredBoolean(
                    arguments,
                    1,
                    "SetPaintBackgroundEnabled"
                )
                return []
            }),
            ("SetPaintBorderEnabled", { arguments in
                let panel = try requiredPanel(arguments, "SetPaintBorderEnabled")
                panel.paintBorderEnabled = try requiredBoolean(
                    arguments,
                    1,
                    "SetPaintBorderEnabled"
                )
                return []
            }),
            ("SetZPos", { arguments in
                let panel = try requiredPanel(arguments, "SetZPos")
                panel.zPosition = try requiredNumber(arguments, 1, "SetZPos").rounded(.towardZero)
                return []
            }),
            ("GetZPos", { arguments in
                [.number(try requiredPanel(arguments, "GetZPos").zPosition)]
            }),
            ("Prepare", { arguments in
                let panel = try requiredPanel(arguments, "Prepare")
                try registry.prepare(panel)
                return []
            }),
            ("IsMarkedForDeletion", { arguments in
                let panel = try requiredPanel(
                    arguments,
                    "IsMarkedForDeletion",
                    requireValid: false
                )
                return [.boolean(panel.isMarkedForDeletion)]
            }),
            ("Remove", { arguments in
                let panel = try requiredPanel(arguments, "Remove", requireValid: false)
                registry.markForDeletion(identifier: panel.identifier)
                return []
            })
        ]
        for (name, body) in methods {
            try set(
                nativeFunction(name: "Panel:\(name)", registry: registry, body),
                name,
                panelMetatable,
                state
            )
        }
    }
}

private let validCursorNames: Set<String> = [
    "arrow", "beam", "hourglass", "waitarrow", "crosshair", "up",
    "sizenwse", "sizenesw", "sizewe", "sizens", "sizeall", "no",
    "hand", "blank"
]

private func normalizedCursorName(_ name: String) -> String {
    validCursorNames.contains(name) ? name : "none"
}

private func isLikelyVGUIMethodName(_ name: String) -> Bool {
    guard let first = name.utf8.first, first >= 65, first <= 90 else { return false }
    return name.utf8.dropFirst().allSatisfy { byte in
        (byte >= 65 && byte <= 90) ||
            (byte >= 97 && byte <= 122) ||
            (byte >= 48 && byte <= 57) ||
            byte == 95
    }
}

private func nativeFunction(
    name: String,
    registry: GMLuaVGUIRegistry,
    _ body: @escaping LuaNativeFunction
) -> LuaValue {
    .nativeFunction(
        LuaNativeFunctionBox(
            body,
            debugName: name,
            gcReferences: { [weak registry] in registry?.references ?? [] }
        )
    )
}

private func panelDescriptor(from value: LuaValue) -> GMLuaPanelValue? {
    GMLuaTypeSystem.typedObject(from: value)?.payload as? GMLuaPanelValue
}

private func requiredPanel(
    _ arguments: [LuaValue],
    _ method: String,
    requireValid: Bool = true
) throws -> GMLuaPanelValue {
    guard let first = arguments.first,
          let descriptor = panelDescriptor(from: first),
          !requireValid || GMLuaTypeSystem.typedObject(from: first)?.isValid == true else {
        throw LuaError.runtime("bad self for Panel:\(method)")
    }
    return descriptor
}

private func isTextEngineClass(_ className: String) -> Bool {
    className == "Label" || className == "TextEntry" || className == "RichText"
}

private func unsupportedPanelMethod(_ panel: GMLuaPanelValue, _ method: String) -> LuaError {
    LuaError.runtime(
        "Panel:\(method) is not implemented by engine class '\(panel.engineClassName)'"
    )
}

private func requiredTextPanel(
    _ arguments: [LuaValue],
    _ method: String
) throws -> GMLuaPanelValue {
    let panel = try requiredPanel(arguments, method)
    guard isTextEngineClass(panel.engineClassName) else {
        throw unsupportedPanelMethod(panel, method)
    }
    return panel
}

private func requiredHTMLPanel(
    _ arguments: [LuaValue],
    _ method: String
) throws -> GMLuaPanelValue {
    let panel = try requiredPanel(arguments, method)
    guard panel.engineClassName == "HTML" else {
        throw unsupportedPanelMethod(panel, method)
    }
    return panel
}

private func requiredModelImage(
    _ arguments: [LuaValue],
    _ method: String
) throws -> GMLuaPanelValue {
    let panel = try requiredPanel(arguments, method)
    guard panel.engineClassName == "ModelImage" else {
        throw unsupportedPanelMethod(panel, method)
    }
    return panel
}

private func requiredLabel(
    _ arguments: [LuaValue],
    _ method: String
) throws -> GMLuaPanelValue {
    let panel = try requiredPanel(arguments, method)
    guard panel.engineClassName == "Label" else {
        throw unsupportedPanelMethod(panel, method)
    }
    return panel
}

private func requiredTextEntry(
    _ arguments: [LuaValue],
    _ method: String
) throws -> GMLuaPanelValue {
    let panel = try requiredPanel(arguments, method)
    guard panel.engineClassName == "TextEntry" else {
        throw unsupportedPanelMethod(panel, method)
    }
    return panel
}

private func requiredLuaString(
    _ arguments: [LuaValue],
    _ index: Int,
    _ function: String
) throws -> LuaString {
    guard arguments.indices.contains(index), case let .string(value) = arguments[index] else {
        throw LuaError.runtime(
            "bad argument #\(index + 1) to '\(function)' (string expected)"
        )
    }
    return value
}

private func requiredPanelColor(
    _ arguments: [LuaValue],
    state: LuaState,
    function: String
) throws -> GMLuaPanelColorSnapshot {
    if arguments.indices.contains(1), case let .table(table) = arguments[1] {
        func component(_ name: String) throws -> Double {
            let value = try state.rawTableValue(for: .string(LuaString(name)), in: table)
            guard case let .number(number) = value, number.isFinite else {
                throw LuaError.runtime(
                    "bad argument #1 to '\(function)' (Color table with finite \(name) expected)"
                )
            }
            return number
        }
        return try GMLuaPanelColorSnapshot(
            red: component("r"),
            green: component("g"),
            blue: component("b"),
            alpha: component("a")
        )
    }

    return GMLuaPanelColorSnapshot(
        red: try requiredNumber(arguments, 1, function),
        green: try requiredNumber(arguments, 2, function),
        blue: try requiredNumber(arguments, 3, function),
        alpha: try requiredNumber(arguments, 4, function)
    )
}

private func requiredPanelColorTable(
    _ arguments: [LuaValue],
    index: Int,
    state: LuaState,
    function: String
) throws -> GMLuaPanelColorSnapshot {
    guard arguments.indices.contains(index), case let .table(table) = arguments[index] else {
        throw LuaError.runtime(
            "bad argument #\(index) to '\(function)' (Color table expected)"
        )
    }

    func component(_ name: String) throws -> Double {
        let value = try state.rawTableValue(for: .string(LuaString(name)), in: table)
        guard case let .number(number) = value, number.isFinite else {
            throw LuaError.runtime(
                "bad argument #\(index) to '\(function)' " +
                    "(Color table with finite \(name) expected)"
            )
        }
        return number
    }

    return try GMLuaPanelColorSnapshot(
        red: component("r"),
        green: component("g"),
        blue: component("b"),
        alpha: component("a")
    )
}

private func makeColorValue(
    _ color: GMLuaPanelColorSnapshot,
    state: LuaState
) throws -> LuaValue {
    let arguments: [LuaValue] = [
        .number(color.red), .number(color.green),
        .number(color.blue), .number(color.alpha)
    ]
    let constructor = state.getGlobal("Color")
    if case .luaFunction = constructor {
        if let value = try state.call(constructor, arguments: arguments).first, !isNil(value) {
            return value
        }
    } else if case .nativeFunction = constructor,
              let value = try state.call(constructor, arguments: arguments).first,
              !isNil(value) {
        return value
    }

    let table = LuaTable()
    try state.setRawTableValue(.number(color.red), for: .string("r"), in: table)
    try state.setRawTableValue(.number(color.green), for: .string("g"), in: table)
    try state.setRawTableValue(.number(color.blue), for: .string("b"), in: table)
    try state.setRawTableValue(.number(color.alpha), for: .string("a"), in: table)
    return .table(table)
}

private func requiredString(
    _ arguments: [LuaValue],
    _ index: Int,
    _ function: String
) throws -> String {
    try requiredLuaString(arguments, index, function).utf8String
}

private func optionalString(
    _ arguments: [LuaValue],
    _ index: Int,
    _ fallback: String,
    _ function: String
) throws -> String {
    guard arguments.indices.contains(index), !isNil(arguments[index]) else { return fallback }
    return try requiredString(arguments, index, function)
}

private func requiredNumber(
    _ arguments: [LuaValue],
    _ index: Int,
    _ function: String
) throws -> Double {
    guard arguments.indices.contains(index), case let .number(value) = arguments[index],
          value.isFinite else {
        throw LuaError.runtime(
            "bad argument #\(index) to '\(function)' (finite number expected)"
        )
    }
    return value
}

private func requiredInteger(
    _ arguments: [LuaValue],
    _ index: Int,
    _ function: String
) throws -> Int {
    let value = try requiredNumber(arguments, index, function)
    let integral = value.rounded(.towardZero)
    guard integral == value, integral >= Double(Int.min), integral < Double(Int.max) else {
        throw LuaError.runtime("bad argument #\(index) to '\(function)' (integer expected)")
    }
    return Int(integral)
}

private func requiredCoercibleInteger(
    _ arguments: [LuaValue],
    _ index: Int,
    _ function: String
) throws -> Int {
    guard arguments.indices.contains(index) else {
        throw LuaError.runtime(
            "bad argument #\(index) to '\(function)' (number expected)"
        )
    }
    let number: Double?
    switch arguments[index] {
    case let .number(value):
        number = value
    case let .string(value):
        number = Double(
            value.utf8String.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    default:
        number = nil
    }
    guard let number, number.isFinite else {
        throw LuaError.runtime(
            "bad argument #\(index) to '\(function)' (number expected)"
        )
    }
    let integral = number.rounded(.towardZero)
    guard integral >= Double(Int.min), integral < Double(Int.max) else {
        throw LuaError.runtime(
            "bad argument #\(index) to '\(function)' (integer range expected)"
        )
    }
    return Int(integral)
}

private func optionalCoercibleNumber(
    _ arguments: [LuaValue],
    _ index: Int,
    _ fallback: Double,
    _ function: String
) throws -> Double {
    guard arguments.indices.contains(index), !isNil(arguments[index]) else { return fallback }
    let number: Double?
    switch arguments[index] {
    case let .number(value):
        number = value
    case let .string(value):
        number = Double(value.utf8String.trimmingCharacters(in: .whitespacesAndNewlines))
    default:
        number = nil
    }
    guard let number, number.isFinite else {
        throw LuaError.runtime(
            "bad argument #\(index) to '\(function)' (number expected)"
        )
    }
    return number
}

private func requiredBoolean(
    _ arguments: [LuaValue],
    _ index: Int,
    _ function: String
) throws -> Bool {
    guard arguments.indices.contains(index), case let .boolean(value) = arguments[index] else {
        throw LuaError.runtime("bad argument #\(index) to '\(function)' (boolean expected)")
    }
    return value
}

private func luaTruthValue(_ arguments: [LuaValue], _ index: Int) -> Bool {
    guard arguments.indices.contains(index) else { return false }
    switch arguments[index] {
    case .nilValue:
        return false
    case let .boolean(value):
        return value
    default:
        return true
    }
}

private func optionalBoolean(
    _ arguments: [LuaValue],
    _ index: Int,
    _ fallback: Bool,
    _ function: String
) throws -> Bool {
    guard arguments.indices.contains(index), !isNil(arguments[index]) else { return fallback }
    return try requiredBoolean(arguments, index, function)
}

/// Byte boundaries for the decoded UTF-8 character offsets exposed by
/// TextEntry caret APIs. Invalid bytes remain one addressable unit so a Lua
/// string is never normalized or discarded merely because host text is
/// inserted into it.
private func utf8CharacterBoundaries(in bytes: [UInt8]) -> [Int] {
    var result = [0]
    var index = 0
    while index < bytes.count {
        func hasByte(_ offset: Int, in allowed: ClosedRange<UInt8>) -> Bool {
            let candidate = index + offset
            return bytes.indices.contains(candidate) && allowed.contains(bytes[candidate])
        }
        func isContinuation(_ offset: Int) -> Bool {
            hasByte(offset, in: 0x80...0xBF)
        }

        let length: Int
        switch bytes[index] {
        case 0x00...0x7F:
            length = 1
        case 0xC2...0xDF where isContinuation(1):
            length = 2
        case 0xE0 where hasByte(1, in: 0xA0...0xBF) && isContinuation(2):
            length = 3
        case 0xE1...0xEC where isContinuation(1) && isContinuation(2):
            length = 3
        case 0xEE...0xEF where isContinuation(1) && isContinuation(2):
            length = 3
        case 0xED where hasByte(1, in: 0x80...0x9F) && isContinuation(2):
            length = 3
        case 0xF0 where hasByte(1, in: 0x90...0xBF) &&
                isContinuation(2) && isContinuation(3):
            length = 4
        case 0xF1...0xF3 where
                isContinuation(1) && isContinuation(2) && isContinuation(3):
            length = 4
        case 0xF4 where hasByte(1, in: 0x80...0x8F) &&
                isContinuation(2) && isContinuation(3):
            length = 4
        default:
            length = 1
        }
        index += length
        result.append(index)
    }
    return result
}

private func utf8CharacterCount(in bytes: [UInt8]) -> Int {
    utf8CharacterBoundaries(in: bytes).count - 1
}

private func set(
    _ value: LuaValue,
    _ name: String,
    _ table: LuaTable,
    _ state: LuaState
) throws {
    try state.setRawTableValue(value, for: .string(LuaString(name)), in: table)
}

private func isNil(_ value: LuaValue) -> Bool {
    if case .nilValue = value { return true }
    return false
}
