import Foundation

public enum SourceWeaponAnimationClockError: Error, Sendable, Equatable {
    case invalidTime
    case backwardsTime
    case invalidState
}

extension SourceCanonicalWeaponRuntimeState {
    /// Source-style cycle advance using the supplied fixed simulation time.
    /// A value result keeps failure transactional. CLIENTs consume this state;
    /// they must not run an independent authoritative animation clock.
    public func advancingAnimation(to time: Float) throws -> Self {
        guard time.isFinite, time >= 0 else { throw SourceWeaponAnimationClockError.invalidTime }
        guard animationCycle.isFinite, (0...1).contains(animationCycle),
              animationCycleRate.isFinite, animationCycleRate >= 0,
              animationPlaybackRate.isFinite, animationPlaybackRate >= 0 else {
            throw SourceWeaponAnimationClockError.invalidState
        }
        var result = self
        guard animationSequence >= 0, animationCycleRate > 0 else { return result }
        guard let previous = animationLastAdvanceTime else {
            result.animationLastAdvanceTime = time
            return result
        }
        guard previous.isFinite, previous >= 0 else { throw SourceWeaponAnimationClockError.invalidState }
        guard time >= previous else { throw SourceWeaponAnimationClockError.backwardsTime }
        let interval = min(time - previous, 0.2)
        guard interval > 0.001 else { return result }
        if !animationSequenceLoops, animationCycle == 1 { return result }
        let next = animationCycle + interval * (animationCycleRate * animationPlaybackRate)
        guard next.isFinite else { throw SourceWeaponAnimationClockError.invalidState }
        result.animationCycle = animationSequenceLoops ? next - floor(next) : min(next, 1)
        result.animationLastAdvanceTime = time
        return result
    }
}
