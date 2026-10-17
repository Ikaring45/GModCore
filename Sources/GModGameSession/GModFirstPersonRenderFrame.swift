import Foundation
import GModEngine

/// One serialized CLIENT observation. A renderer must clear hands when this
/// frame disables them, even if the hands entity itself has not changed.
/// This packet does not perform skeletal bonemerge or claim animated geometry.
public struct GModFirstPersonRenderFrame: Sendable, Equatable {
    public let cursor: SourceEntityReplicationCursor
    public let activeWeapon: SourceCanonicalEntityIdentity?
    public let definition: GMLuaScriptedWeaponRenderDefinition?
    public let viewModel: GModFirstPersonViewModelSceneSnapshot?
    public let hands: GModFirstPersonHandsSceneSnapshot?
    public var handsEnabled: Bool { definition?.useHands == true && definition?.viewModel != nil }
}

extension GModPlayableSession {
    /// Called only on the session owner lane; no actor suspension occurs
    /// between definition selection, viewmodel projection and hands projection.
    public func clientFirstPersonRenderFrame() throws -> GModFirstPersonRenderFrame? {
        guard !isClosed else { throw GModPlayableSessionError.closed }
        guard let registry = clientRuntime.entityRegistry,
              let cursor = registry.canonicalEntityReplicationCursor else { return nil }
        let entities = registry.canonicalEntitySnapshots
        let player = entities.first { $0.identity.entryIndex == configuration.playerEntityIndex && $0.kind == .player && $0.isNetworkable && ($0.lifecycle == .spawned || $0.lifecycle == .active) }
        let identity = player?.weaponInventory.activeWeapon
        let weapon = entities.first {
            guard $0.identity == identity, $0.kind == .weapon, $0.isNetworkable,
                  $0.lifecycle == .spawned || $0.lifecycle == .active,
                  let record = player?.weaponInventory.weapon(identity: $0.identity) else { return false }
            return record.className.caseInsensitiveCompare($0.className) == .orderedSame
        }
        let definition = try weapon.map { try clientRuntime.scriptedWeaponRenderDefinition(className: $0.className) }
        let viewModel = try clientFirstPersonViewModelScene(ifChangedFrom: nil)
        let hands = definition?.useHands == true && definition?.viewModel != nil
            ? try clientFirstPersonHandsScene(ifChangedFrom: nil) : nil
        return GModFirstPersonRenderFrame(cursor: cursor, activeWeapon: weapon?.identity,
            definition: definition, viewModel: viewModel, hands: hands)
    }
}
