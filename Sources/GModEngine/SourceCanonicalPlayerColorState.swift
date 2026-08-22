/// Player-only material-proxy colors. These RGB vectors are distinct from
/// Entity color32 modulation and travel with the canonical full-EHANDLE
/// snapshot. The bundled Sandbox weapon-color default deliberately exceeds
/// one, so storage preserves finite engine-authored components verbatim.
public struct SourceCanonicalPlayerColorState: Equatable, Sendable {
    public var playerColor: SourceVector3
    public var weaponColor: SourceVector3

    public init(
        playerColor: SourceVector3 = SourceVector3(1, 1, 1),
        weaponColor: SourceVector3 = SourceVector3(1, 1, 1)
    ) {
        self.playerColor = playerColor
        self.weaponColor = weaponColor
    }

    public static let white = SourceCanonicalPlayerColorState()

    var isFinite: Bool {
        Self.isFinite(playerColor) && Self.isFinite(weaponColor)
    }

    private static func isFinite(_ value: SourceVector3) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }
}
