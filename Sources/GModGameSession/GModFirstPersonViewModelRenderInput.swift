import GModEngine

public enum GModFirstPersonViewModelAnimationError: Error, Sendable, CustomStringConvertible {
    case projectionMismatch
    case repositoryUnavailable
    case studio(GModStudioAnimatedRenderableModelResolutionFailure)

    public var description: String {
        switch self {
        case .projectionMismatch: return "viewmodel animation does not match the replicated active weapon"
        case .repositoryUnavailable: return "viewmodel animation has no Studio repository"
        case let .studio(error): return "viewmodel animation resolution failed: \(error)"
        }
    }
}

/// Atomic CLIENT state plus a thread-safe decoded-asset resolver. No Lua or
/// mutable entity objects leave the session lane. Resolve on a render worker,
/// not the simulation lane: decoding and CPU skinning can be expensive.
public struct GModFirstPersonViewModelRenderInput: Sendable {
    public let frame: GModFirstPersonRenderFrame
    let resolver: (any GModStudioAnimatedRenderableModelResolving)?

    /// Cycle-only changes may coalesce without starving an in-flight render.
    /// Full-handle, model/appearance, definition and sequence changes may not.
    public func hasSameAnimationTarget(as other: Self) -> Bool {
        frame.activeWeapon == other.frame.activeWeapon &&
        frame.definition == other.frame.definition &&
        frame.viewModel?.projection?.resource.id == other.frame.viewModel?.projection?.resource.id &&
        frame.animation?.animationSequence == other.frame.animation?.animationSequence
    }

    public func resolveAnimation() throws -> GModStudioAnimatedRenderableModelResource? {
        guard let projection = frame.viewModel?.projection else { return nil }
        guard projection.weaponIdentity == frame.activeWeapon,
              frame.definition?.viewModel == projection.viewModel else {
            throw GModFirstPersonViewModelAnimationError.projectionMismatch
        }
        guard let selection = try frame.viewModelAnimationSelection() else { return nil }
        guard let resolver else { throw GModFirstPersonViewModelAnimationError.repositoryUnavailable }
        switch resolver.resolve(model: projection.viewModel,
            bodyValue: projection.resource.id.bodyValue,
            skinFamilyIndex: projection.resource.id.skinFamilyIndex,
            lodIndex: projection.resource.id.lodIndex, selection: selection) {
        case let .resolved(resource): return resource
        case let .failed(error): throw GModFirstPersonViewModelAnimationError.studio(error)
        }
    }
}

extension GModPlayableSession {
    public func clientFirstPersonViewModelRenderInput() throws -> GModFirstPersonViewModelRenderInput? {
        guard let frame = try clientFirstPersonRenderFrame() else { return nil }
        if firstPersonAnimatedModelCache == nil, let studioModelRepository {
            firstPersonAnimatedModelCache = try GModStudioAnimatedRenderableModelCache(repository: studioModelRepository)
        }
        return GModFirstPersonViewModelRenderInput(frame: frame, resolver: firstPersonAnimatedModelCache)
    }
}
