import Combine
import Foundation
import GModEngine

/// Host-owned controls that are genuinely implemented by Garry's PAD.
/// These do not impersonate Source mouse/video ConVars: the values directly
/// drive the native touch-look path and MTKView cadence.
@MainActor
final class GModInputVideoSettingsStore: ObservableObject {
    static let shared = GModInputVideoSettingsStore()

    nonisolated static let minimumTouchLookSensitivity = 0.05
    nonisolated static let maximumTouchLookSensitivity = 1.50
    nonisolated static let defaultTouchLookSensitivity = 0.34
    nonisolated static let supportedFrameRates = [60, 120]

    static let touchLookSensitivityKey =
        "GarrysPAD.Input.TouchLookSensitivity.v1"
    static let invertTouchLookYKey =
        "GarrysPAD.Input.InvertTouchLookY.v1"
    static let preferredFrameRateKey =
        "GarrysPAD.Video.PreferredFrameRate.v1"

    @Published private(set) var touchLookSensitivity: Double
    @Published private(set) var invertTouchLookY: Bool
    @Published private(set) var preferredFramesPerSecond: Int

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        touchLookSensitivity = Self.clampedTouchLookSensitivity(
            defaults.object(forKey: Self.touchLookSensitivityKey) == nil
                ? Self.defaultTouchLookSensitivity
                : defaults.double(forKey: Self.touchLookSensitivityKey)
        )
        invertTouchLookY = defaults.object(forKey: Self.invertTouchLookYKey) == nil
            ? false
            : defaults.bool(forKey: Self.invertTouchLookYKey)
        preferredFramesPerSecond = Self.resolvedFrameRate(
            defaults.object(forKey: Self.preferredFrameRateKey) == nil
                ? 120
                : defaults.integer(forKey: Self.preferredFrameRateKey)
        )
    }

    func setTouchLookSensitivity(_ value: Double) {
        let replacement = Self.clampedTouchLookSensitivity(value)
        guard replacement != touchLookSensitivity else { return }
        touchLookSensitivity = replacement
        defaults.set(replacement, forKey: Self.touchLookSensitivityKey)
    }

    func setInvertTouchLookY(_ enabled: Bool) {
        guard enabled != invertTouchLookY else { return }
        invertTouchLookY = enabled
        defaults.set(enabled, forKey: Self.invertTouchLookYKey)
    }

    func setPreferredFramesPerSecond(_ requested: Int) {
        let replacement = Self.resolvedFrameRate(requested)
        guard replacement != preferredFramesPerSecond else { return }
        preferredFramesPerSecond = replacement
        defaults.set(replacement, forKey: Self.preferredFrameRateKey)
    }

    nonisolated static func clampedTouchLookSensitivity(
        _ value: Double
    ) -> Double {
        guard value.isFinite else { return defaultTouchLookSensitivity }
        return Swift.max(
            minimumTouchLookSensitivity,
            Swift.min(maximumTouchLookSensitivity, value)
        )
    }

    nonisolated static func resolvedFrameRate(_ requested: Int) -> Int {
        requested <= 60 ? 60 : 120
    }
}

/// Pure touch-look transform used by the live model and focused tests. Keeping
/// it independent of SwiftUI makes clamping and invert-Y behavior explicit.
enum GModTouchLookPolicy {
    static func adjustedAngles(
        current: SourceQAngle,
        deltaX: Float,
        deltaY: Float,
        sensitivity requestedSensitivity: Double,
        invertY: Bool
    ) -> SourceQAngle {
        guard deltaX.isFinite, deltaY.isFinite else { return current }
        let sensitivity = Float(
            GModInputVideoSettingsStore.clampedTouchLookSensitivity(
                requestedSensitivity
            )
        )
        let pitchDelta = deltaY * sensitivity * (invertY ? -1 : 1)
        var yaw = current.yaw + deltaX * sensitivity
        yaw.formTruncatingRemainder(dividingBy: 360)
        return SourceQAngle(
            pitch: Swift.max(-89, Swift.min(89, current.pitch + pitchDelta)),
            yaw: yaw,
            roll: 0
        )
    }
}
