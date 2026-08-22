import Foundation

/// Source exposes `fov_desired` as a horizontal angle authored against its
/// 4:3 base view. This boundary keeps the Lua/ConVar value renderer-neutral;
/// conversion to a vertical Metal projection belongs to GModMetal.
public enum GModPlayableWorldFieldOfView {
    public static let defaultHorizontalDegrees: Float = 75

    public static func resolvedHorizontalDegrees(
        _ rawValue: String?
    ) -> Float {
        guard let rawValue,
              let value = Float(rawValue.trimmingCharacters(
                in: .whitespacesAndNewlines
              )),
              value.isFinite,
              value > 0,
              value < 180 else {
            return defaultHorizontalDegrees
        }
        return value
    }
}

extension GModPlayableSession {
    /// Reads the current CLIENT engine ConVar on the serialized session lane.
    /// Missing/invalid values fail back to Source's ordinary 75-degree view.
    public var clientWorldHorizontalFieldOfViewDegrees: Float {
        GModPlayableWorldFieldOfView.resolvedHorizontalDegrees(
            clientRuntime.engineConVarCatalog?.currentValue(
                for: "fov_desired"
            )
        )
    }
}
