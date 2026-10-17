import GModEngine

extension GModPlayableSession {
    /// Called after SERVER Think and before the shared FIFO drains. Animation
    /// selection made during Think therefore starts at that tick's exact time.
    func advanceCanonicalWeaponAnimations() throws {
        let snapshots = sourceAdapter.canonicalEntitySnapshots
        let time = sourceAdapter.serverGlobals.currentTime
        let active = Set(snapshots.filter { $0.kind == .player }.compactMap { $0.weaponInventory.activeWeapon })
        for weapon in snapshots where weapon.kind == .weapon && active.contains(weapon.identity) &&
            (weapon.lifecycle == .spawned || weapon.lifecycle == .active) {
            let updated = try weapon.weaponRuntime.advancingAnimation(to: time)
            guard updated != weapon.weaponRuntime else { continue }
            _ = try sourceAdapter.updateCanonicalEntity(weapon.identity) { $0.weaponRuntime = updated }
        }
    }
}
