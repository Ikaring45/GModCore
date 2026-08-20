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
    public let textInsetX: Int
    public let textInsetY: Int
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
        textInsetX: Int = 0,
        textInsetY: Int = 0,
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
        self.textInsetX = textInsetX
        self.textInsetY = textInsetY
        self.expensiveShadow = expensiveShadow
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
    public let clipRect: GMLuaPanelRect
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
    var width = 0.0
    var height = 0.0
    var alpha = 255.0
    var isVisible = true
    var isEnabled = true
    var mouseInputEnabled = true
    var keyboardInputEnabled = true
    var isPopup = false
    var isWorldClicker = false
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
    var foregroundColor: GMLuaPanelColorSnapshot?
    var contentAlignment = 5
    var allowsNonASCIICharacters = false
    var expensiveShadow: GMLuaTextShadowSnapshot?
    var dock = GMLuaPanelDock.none
    var dockMargin = (left: 0.0, top: 0.0, right: 0.0, bottom: 0.0)
    var dockPadding = (left: 0.0, top: 0.0, right: 0.0, bottom: 0.0)
    var clipsChildren = true
    var imageName: LuaString?

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
    private var latestDrawOnTopOrder: UInt64 = 0

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

    fileprivate func labelContentSize(
        _ panel: GMLuaPanelValue
    ) throws -> GMLuaTextMeasurement {
        guard let surfaceCommandState else {
            throw LuaError.runtime(
                "Panel:GetContentSize requires the shared surface text measurement boundary"
            )
        }
        guard panel.imageName == nil else {
            throw LuaError.runtime(
                "Panel:GetContentSize cannot measure a Label image without a platform image boundary"
            )
        }

        let fullContentSize = try surfaceCommandState.measureText(
            panel.text,
            usingFontNamed: panel.fontName,
            fallbackFontNamed: LuaString("Default")
        )
        // Label.cpp replaces the current TextImage width with its full content
        // width. With wrapping deliberately unsupported, both measurements are
        // identical today, but retaining the two concepts prevents a future
        // wrapped implementation from silently applying the wrong formula.
        let currentTextImageSize = fullContentSize
        let alignedContentWidth = currentTextImageSize.width
        // Native Label.cpp uses max(current aligned TextImage height + the
        // vertical inset, full content height). Original DLabel overrides the
        // native PerformLayout without sizing that TextImage, so the current
        // image height is zero throughout the bootstrap path. Do not add the
        // inset to the full glyph height: the Windows oracle returns 14, not
        // 27, for a 13px line with a 14px vertical inset.
        let alignedContentHeight = 0
        return GMLuaTextMeasurement(
            width: alignedContentWidth + panel.textInsetX
                - currentTextImageSize.width + fullContentSize.width,
            height: max(
                alignedContentHeight + panel.textInsetY,
                fullContentSize.height
            )
        )
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
                textInsetX: descriptor.textInsetX,
                textInsetY: descriptor.textInsetY,
                expensiveShadow: descriptor.expensiveShadow
            )
        }
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

    /// Must be called while `lock` is held. Hidden panels do not consume dock
    /// space, while alpha-zero panels do, matching the child docking contract.
    private func applyNativeDockingLocked(
        descriptors: [Int: GMLuaPanelValue],
        viewport: GMLuaPanelRect
    ) {
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
        _ = try performPendingLayouts()
        let tree = renderTree(viewportWidth: viewportWidth, viewportHeight: viewportHeight)
        surface.beginFrame(viewportWidth: viewportWidth, viewportHeight: viewportHeight)
        let byParent = Dictionary(grouping: tree, by: \.parentIdentifier)

        func paint(_ panel: GMLuaPanelRenderSnapshot) throws {
            surface.pushPanelContext(frame: panel.frame, clip: panel.clipRect, alpha: panel.alpha)
            defer { surface.popPanelContext() }
            let paintResult = try callPanelMethodReturningValues(
                identifier: panel.identifier,
                name: "Paint",
                arguments: [.number(panel.frame.width), .number(panel.frame.height)]
            )
            let suppressesDefaultPaint: Bool
            if let first = paintResult?.first, case .boolean(true) = first {
                suppressesDefaultPaint = true
            } else {
                suppressesDefaultPaint = false
            }
            if !suppressesDefaultPaint {
                try surface.appendPanelImage(panel)
                if panel.engineClassName == "Label" { surface.appendPanelText(panel) }
            }
            for child in byParent[panel.identifier] ?? [] { try paint(child) }
            _ = try callPanelMethod(
                identifier: panel.identifier,
                name: "PaintOver",
                arguments: [.number(panel.frame.width), .number(panel.frame.height)]
            )
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
                descriptor.text = LuaString(bytes: descriptor.text.bytes + accepted)
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
            return try state.call(callback, arguments: [value] + arguments)
        default:
            return nil
        }
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
                    _ = try state.call(initializer, arguments: [value])
                } else if case .nativeFunction = initializer {
                    _ = try state.call(initializer, arguments: [value])
                }
            }
            return value
        } catch {
            remove(identifier: identifier)
            throw error
        }
    }

    fileprivate func remove(identifier: Int) {
        lock.lock()
        let identifiers = descendantIdentifiers(of: identifier)
        let removed = identifiers.compactMap { panels.removeValue(forKey: $0) }
        let removedIdentifiers = Set(identifiers)
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
            GMLuaTypeSystem.typedObject(from: value)?.isValid = false
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

    fileprivate func setParent(identifier: Int, parentIdentifier: Int?) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let value = panels[identifier],
              let descriptor = panelDescriptor(from: value),
              GMLuaTypeSystem.typedObject(from: value)?.isValid == true else {
            throw LuaError.runtime("invalid Panel")
        }
        guard let parentIdentifier else {
            descriptor.parentIdentifier = nil
            descriptor.isParentedToHUD = false
            return
        }
        guard panels[parentIdentifier] != nil else {
            throw LuaError.runtime("invalid parent Panel")
        }

        var current: Int? = parentIdentifier
        var visited: Set<Int> = []
        while let candidate = current {
            guard visited.insert(candidate).inserted else {
                throw LuaError.runtime("cycle in Panel parent hierarchy")
            }
            guard candidate != identifier else {
                throw LuaError.runtime("a Panel cannot be parented to its descendant")
            }
            current = panels[candidate].flatMap { panelDescriptor(from: $0) }?.parentIdentifier
        }
        descriptor.parentIdentifier = parentIdentifier
        descriptor.isParentedToHUD = false
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
            _ = try state.call(callback, arguments: [
                value, .number(descriptor.width), .number(descriptor.height)
            ])
        } else if case .nativeFunction = callback {
            _ = try state.call(callback, arguments: [
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
            let value = try state.call(
                semanticIndex,
                arguments: [.table(descriptor.instanceTable), arguments[1]]
            ).first ?? .nilValue
            if !isNil(value) { return [value] }
            return [try state.rawTableValue(for: arguments[1], in: panelMetatable)]
        }
        let panelNewIndex = nativeFunction(
            name: "Panel.__newindex",
            registry: registry
        ) { arguments in
            guard arguments.count >= 3,
                  let descriptor = panelDescriptor(from: arguments[0]) else {
                throw LuaError.runtime("attempt to index an invalid Panel")
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

        for (name, value) in [
            ("Register", register), ("GetControlTable", getControlTable),
            ("Exists", exists), ("Create", create), ("GetAll", getAll)
        ] {
            try set(value, name, vgui, state)
        }
        state.setGlobal("vgui", value: .table(vgui))
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
            ("GetParent", { arguments in
                let panel = try requiredPanel(arguments, "GetParent")
                return [registry.panel(identifier: panel.parentIdentifier) ?? .nilValue]
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
                panel.x = x
                panel.y = y
                try state.setRawTableValue(.number(x), for: .string("x"), in: panel.instanceTable)
                try state.setRawTableValue(.number(y), for: .string("y"), in: panel.instanceTable)
                return []
            }),
            ("GetPos", { arguments in
                let panel = try requiredPanel(arguments, "GetPos")
                return [.number(panel.x), .number(panel.y)]
            }),
            ("SetSize", { arguments in
                let panel = try requiredPanel(arguments, "SetSize")
                panel.width = floor(try requiredNumber(arguments, 1, "SetSize"))
                panel.height = floor(try requiredNumber(arguments, 2, "SetSize"))
                return []
            }),
            ("SetWide", { arguments in
                let panel = try requiredPanel(arguments, "SetWide")
                panel.width = floor(try requiredNumber(arguments, 1, "SetWide"))
                return []
            }),
            ("SetTall", { arguments in
                let panel = try requiredPanel(arguments, "SetTall")
                panel.height = floor(try requiredNumber(arguments, 1, "SetTall"))
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
                let childSize = registry.childrenSize(of: panel.identifier)
                if sizeWidth { panel.width = floor(childSize.width) }
                if sizeHeight { panel.height = floor(childSize.height) }
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
            ("SetText", { arguments in
                let panel = try requiredTextPanel(arguments, "SetText")
                let supplied = try requiredLuaString(arguments, 1, "SetText")
                if panel.engineClassName == "Label" {
                    panel.text = LuaString(bytes: Array(supplied.bytes.prefix(1_023)))
                    try registry.invalidateLayout(identifier: panel.identifier, layoutNow: false)
                } else {
                    panel.text = supplied
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
            ("GetFont", { arguments in
                let panel = try requiredTextPanel(arguments, "GetFont")
                return [.string(panel.fontName)]
            }),
            ("SetTextInset", { arguments in
                let panel = try requiredLabel(arguments, "SetTextInset")
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
            ("Remove", { arguments in
                let panel = try requiredPanel(arguments, "Remove", requireValid: false)
                registry.remove(identifier: panel.identifier)
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
