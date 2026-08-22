import Foundation
import GModEngine

/// Live, read-only collision projection used by one realm's `util.Trace*`.
/// It never owns Entity state and never substitutes render bounds for missing
/// Studio hitboxes or an unattested physics hull.
final class GModCanonicalDynamicTraceSource:
    GMLuaDynamicTraceCandidateProvider, @unchecked Sendable
{
    private let lock = NSLock()
    private let studioRepository: GModStudioModelRepository?
    private let propPhysicsResolver: GModAttestedPropPhysicsAssetResolver?
    private var snapshots: (() -> [SourceCanonicalEntitySnapshot])?

    init(
        studioRepository: GModStudioModelRepository?,
        propPhysicsResolver: GModAttestedPropPhysicsAssetResolver?
    ) {
        self.studioRepository = studioRepository
        self.propPhysicsResolver = propPhysicsResolver
    }

    func connect(
        snapshots: @escaping () -> [SourceCanonicalEntitySnapshot]
    ) {
        lock.lock()
        self.snapshots = snapshots
        lock.unlock()
    }

    var isDynamicTraceReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        // A connected realm with no mounted Studio/PHY assets is still a
        // valid dynamic world containing zero traceable candidates. Missing
        // per-model assets are skipped below instead of disabling util.Trace*
        // for the already-ready BSP world.
        return snapshots != nil
    }

    func dynamicTraceCandidates(
        for request: GMLuaTraceRequest
    ) throws -> [GMLuaDynamicTraceCandidate] {
        lock.lock()
        let snapshotProvider = snapshots
        lock.unlock()
        guard let snapshotProvider else { return [] }

        let entities = snapshotProvider().filter(Self.isTraceable).sorted {
            $0.identity.handle.rawValue < $1.identity.handle.rawValue
        }

        var candidates: [GMLuaDynamicTraceCandidate] = []
        candidates.reserveCapacity(entities.count)
        for entity in entities {
            switch request.kind {
            case .line:
                guard entity.kind == .propPhysics || entity.kind == .weapon,
                      let modelReference = entity.model,
                      let studioRepository,
                      case let .loaded(asset) = studioRepository.renderAsset(
                        for: modelReference
                      ), !asset.renderPayload.model.hitboxSets.isEmpty else {
                    continue
                }
                let hitboxes = try GMLuaDynamicTraceCandidate
                    .defaultPoseStudioHitboxes(
                        model: asset.renderPayload.model,
                        entityTransform: entity.transform
                    )
                guard !hitboxes.isEmpty else { continue }
                candidates.append(GMLuaDynamicTraceCandidate(
                    identity: entity.identity,
                    className: entity.className,
                    collisionGroup: entity.collisionGroup,
                    studioHitboxes: hitboxes
                ))

            case .hull:
                guard entity.kind == .propPhysics,
                      let modelReference = entity.model,
                      let collisionProperty = entity.collisionProperty,
                      let propPhysicsResolver,
                      case let .valid(asset) = propPhysicsResolver.resolve(
                        modelReference
                      ) else {
                    continue
                }
                let surfaceProperty = Int16(exactly:
                    asset.identity.materialIndex
                )
                guard let surfaceProperty else { continue }
                let hull = try GMLuaDynamicHullCollision(
                    transform: entity.transform,
                    collisionProperty: collisionProperty,
                    physicsShape: asset.bodyDefinition.shape,
                    contents: .solid,
                    surface: SourceTraceSurface(
                        surfaceProperties: surfaceProperty
                    )
                )
                candidates.append(GMLuaDynamicTraceCandidate(
                    identity: entity.identity,
                    className: entity.className,
                    collisionGroup: entity.collisionGroup,
                    hullCollision: hull
                ))
            }
        }
        return candidates
    }

    /// `FSOLID_NOT_SOLID` is authoritative collision state, not a render-only
    /// hint. In particular, the stock remover sets it before the delayed
    /// `Entity:Remove`, so the entity must disappear from both line and hull
    /// candidates immediately while its complete EHANDLE still exists.
    static func isTraceable(
        _ entity: SourceCanonicalEntitySnapshot
    ) -> Bool {
        entity.isNetworkable &&
            !entity.isNotSolid &&
            (entity.lifecycle == .spawned || entity.lifecycle == .active)
    }

    /// The canonical collision group is projected into every candidate. The
    /// nonzero Source game-rules matrix remains fail-closed until its verified
    /// policy is supplied instead of being guessed by the trace bridge.
    func shouldCollide(
        queryCollisionGroup: Int32,
        candidateCollisionGroup: Int32
    ) -> Bool {
        queryCollisionGroup == 0 && candidateCollisionGroup == 0
    }
}
