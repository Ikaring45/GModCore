import Foundation
import GModLua

extension GMLuaRuntime {
    /// Uses the same authoritative view angles, resolved horizontal FOV and
    /// logical viewport as the current playable world, not a fixed forward ray.
    public func installClientScreenRay(
        provider: @escaping () throws -> (angles: SourceQAngle, horizontalFOV: Float)
    ) throws {
        let state = self.state
        guard case let .table(gui) = state.getGlobal("gui") else {
            throw LuaError.runtime("CLIENT gui table is unavailable")
        }
        let function = LuaNativeFunctionBox({ [weak self] arguments in
            guard let self, !self.isClosed,
                  let viewport = self.screenMetrics?.viewport,
                  viewport.width > 0, viewport.height > 0,
                  arguments.count >= 2,
                  case let .number(x) = arguments[0], x.isFinite,
                  case let .number(y) = arguments[1], y.isFinite else {
                throw LuaError.runtime("gui.ScreenToVector requires a live view and finite x/y")
            }
            let view = try provider()
            guard view.horizontalFOV.isFinite, view.horizontalFOV > 0, view.horizontalFOV < 180 else {
                throw LuaError.runtime("gui.ScreenToVector requires a valid field of view")
            }
            let basis = view.angles.sourceBasis
            let tangent = tan(Double(view.horizontalFOV) * .pi / 360)
            let sx = (2 * x / Double(viewport.width) - 1) * tangent
            let sy = (1 - 2 * y / Double(viewport.height)) * tangent *
                Double(viewport.height) / Double(viewport.width)
            let dx = Double(basis.forward.x) + sx * Double(basis.right.x) + sy * Double(basis.up.x)
            let dy = Double(basis.forward.y) + sx * Double(basis.right.y) + sy * Double(basis.up.y)
            let dz = Double(basis.forward.z) + sx * Double(basis.right.z) + sy * Double(basis.up.z)
            let length = sqrt(dx * dx + dy * dy + dz * dz)
            guard length.isFinite, length > 0 else {
                throw LuaError.runtime("gui.ScreenToVector produced an invalid direction")
            }
            return try self.state.call(self.state.getGlobal("Vector"),
                arguments: [.number(dx / length), .number(dy / length), .number(dz / length)])
        }, debugName: "gui.ScreenToVector")
        try state.setRawTableValue(.nativeFunction(function), for: .string("ScreenToVector"), in: gui)
    }
}
