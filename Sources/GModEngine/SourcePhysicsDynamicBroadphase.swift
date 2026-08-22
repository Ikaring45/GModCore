/// One collision-enabled body projected into the dynamic contact broadphase.
/// `sourceOrder` is the index in the environment's complete
/// `SourcePhysicsBodyID` ordering. It is deliberately independent from the
/// spatial sweep order so pruning cannot change solver contact ties.
struct SourcePhysicsDynamicBroadphaseEntry: Equatable, Sendable {
    let sourceOrder: Int
    let minimums: SourceVector3
    let maximums: SourceVector3
    let isMovable: Bool
    let isDynamic: Bool

    init(
        sourceOrder: Int,
        minimums: SourceVector3,
        maximums: SourceVector3,
        isMovable: Bool,
        isDynamic: Bool
    ) {
        precondition(sourceOrder >= 0)
        precondition(minimums.x <= maximums.x)
        precondition(minimums.y <= maximums.y)
        precondition(minimums.z <= maximums.z)
        self.sourceOrder = sourceOrder
        self.minimums = minimums
        self.maximums = maximums
        self.isMovable = isMovable
        self.isDynamic = isDynamic
    }
}

/// A full-AABB-overlapping body pair restored to legacy Source body order.
struct SourcePhysicsDynamicBroadphasePair: Equatable, Sendable {
    let firstSourceOrder: Int
    let secondSourceOrder: Int
}

struct SourcePhysicsDynamicBroadphaseResult: Equatable, Sendable {
    /// All pairs represented by the collision-enabled input before pruning.
    let fullPairCount: Int
    /// Pairs surviving motion policy and inclusive overlap on the sweep axis.
    let sweepCandidatePairCount: Int
    /// Pairs surviving the exact inclusive three-axis AABB test.
    let candidatePairs: [SourcePhysicsDynamicBroadphasePair]
}

/// Deterministic one-axis sweep-and-prune for dynamic rigid-body contacts.
///
/// Spatial ordering is used only to discover a candidate set. The returned
/// pairs are sorted back into the exact nested-loop `(firstID, secondID)`
/// order used by the original exhaustive scan. Inclusive comparisons match
/// `Bounds.intersects`, including bodies that merely touch on an AABB face.
enum SourcePhysicsDynamicSweepAndPrune {
    static func candidates(
        from entries: [SourcePhysicsDynamicBroadphaseEntry]
    ) -> SourcePhysicsDynamicBroadphaseResult {
        guard entries.count > 1 else {
            return SourcePhysicsDynamicBroadphaseResult(
                fullPairCount: 0,
                sweepCandidatePairCount: 0,
                candidatePairs: []
            )
        }

        let spatiallyOrdered = entries.sorted { first, second in
            if first.minimums.x != second.minimums.x {
                return first.minimums.x < second.minimums.x
            }
            if first.maximums.x != second.maximums.x {
                return first.maximums.x < second.maximums.x
            }
            return first.sourceOrder < second.sourceOrder
        }

        var active: [SourcePhysicsDynamicBroadphaseEntry] = []
        active.reserveCapacity(spatiallyOrdered.count)
        var pairs: [SourcePhysicsDynamicBroadphasePair] = []
        var sweepCandidatePairCount = 0

        for current in spatiallyOrdered {
            // A strict separation is required for eviction. Equality is an
            // overlap in the legacy broadphase and must remain a candidate.
            active.removeAll { $0.maximums.x < current.minimums.x }
            for previous in active {
                guard previous.isMovable || current.isMovable,
                      previous.isDynamic || current.isDynamic else {
                    continue
                }
                sweepCandidatePairCount += 1
                guard previous.minimums.y <= current.maximums.y,
                      previous.maximums.y >= current.minimums.y,
                      previous.minimums.z <= current.maximums.z,
                      previous.maximums.z >= current.minimums.z else {
                    continue
                }
                if previous.sourceOrder < current.sourceOrder {
                    pairs.append(SourcePhysicsDynamicBroadphasePair(
                        firstSourceOrder: previous.sourceOrder,
                        secondSourceOrder: current.sourceOrder
                    ))
                } else {
                    pairs.append(SourcePhysicsDynamicBroadphasePair(
                        firstSourceOrder: current.sourceOrder,
                        secondSourceOrder: previous.sourceOrder
                    ))
                }
            }
            active.append(current)
        }

        pairs.sort { first, second in
            if first.firstSourceOrder != second.firstSourceOrder {
                return first.firstSourceOrder < second.firstSourceOrder
            }
            return first.secondSourceOrder < second.secondSourceOrder
        }
        return SourcePhysicsDynamicBroadphaseResult(
            fullPairCount: pairCount(for: entries.count),
            sweepCandidatePairCount: sweepCandidatePairCount,
            candidatePairs: pairs
        )
    }

    private static func pairCount(for count: Int) -> Int {
        guard count > 1 else { return 0 }
        // Divide the even factor first so diagnostics do not overflow at half
        // the representable body count. Saturation is diagnostic-only; it can
        // never affect candidate membership or order.
        let first = count.isMultiple(of: 2) ? count / 2 : count
        let second = count.isMultiple(of: 2) ? count - 1 : (count - 1) / 2
        let (result, overflow) = first.multipliedReportingOverflow(by: second)
        return overflow ? Int.max : result
    }
}
