import Foundation
import GModLua

/// Pixel dimensions of the viewport currently exposed to client-side Lua.
public struct GMLuaViewportSize: Sendable, Equatable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        precondition(width > 0 && height > 0, "viewport dimensions must be positive")
        self.width = width
        self.height = height
    }

    /// Deterministic fallback used by the Windows strict-conformance host and
    /// before an Apple view supplies its real drawable dimensions.
    public static let logicalDesktopDefault = GMLuaViewportSize(
        width: 1280,
        height: 720
    )
}

/// Mutable host boundary behind GLua's client/menu screen-size functions.
///
/// `ScrW` and `ScrH` report the current render viewport in pixels in GMod. A
/// real renderer can therefore update this object whenever its drawable or
/// viewport changes, while headless conformance runs stay deterministic.
public final class GMLuaScreenMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var viewportStorage: GMLuaViewportSize

    fileprivate init(initialViewport: GMLuaViewportSize) {
        viewportStorage = initialViewport
    }

    public var viewport: GMLuaViewportSize {
        lock.lock()
        defer { lock.unlock() }
        return viewportStorage
    }

    /// Replaces the current viewport. Invalid/transient zero-sized drawable
    /// notifications are ignored, preserving the last usable dimensions.
    @discardableResult
    public func updateViewport(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        let replacement = GMLuaViewportSize(width: width, height: height)
        lock.lock()
        let changed = viewportStorage != replacement
        viewportStorage = replacement
        lock.unlock()
        return changed
    }

    static func install(
        into state: LuaState,
        initialViewport: GMLuaViewportSize
    ) -> GMLuaScreenMetrics {
        let metrics = GMLuaScreenMetrics(initialViewport: initialViewport)

        state.register("ScrW") { _ in
            [.number(Double(metrics.viewport.width))]
        }
        state.register("ScrH") { _ in
            [.number(Double(metrics.viewport.height))]
        }
        state.register("ScreenScale") { arguments in
            let value = try numericArgument(arguments, function: "ScreenScale")
            return [.number(value * Double(metrics.viewport.width) / 640.0)]
        }
        state.register("ScreenScaleH") { arguments in
            let value = try numericArgument(arguments, function: "ScreenScaleH")
            return [.number(value * Double(metrics.viewport.height) / 480.0)]
        }

        // The shipped client globals extension assigns this exact alias.
        state.setGlobal("SScale", value: state.getGlobal("ScreenScale"))
        return metrics
    }

    private static func numericArgument(
        _ arguments: [LuaValue],
        function: String
    ) throws -> Double {
        guard let first = arguments.first else {
            throw LuaError.runtime(
                "bad argument #1 to '\(function)' (number expected, got no value)"
            )
        }
        switch first {
        case let .number(value):
            return value
        case let .string(value):
            let source = value.utf8String.trimmingCharacters(in: .whitespacesAndNewlines)
            if let converted = Double(source) { return converted }
            throw LuaError.runtime(
                "bad argument #1 to '\(function)' (number expected, got string)"
            )
        default:
            throw LuaError.runtime(
                "bad argument #1 to '\(function)' (number expected, got \(first.typeName))"
            )
        }
    }
}
