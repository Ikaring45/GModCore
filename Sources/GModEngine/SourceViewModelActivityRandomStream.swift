/// A SERVER-owned, reproducible activity-selection stream. Its seed is an
/// explicit host policy, not a claim about a particular Windows session's RNG.
/// Prediction/shared-random selection is not connected to this stream.
public struct SourceViewModelActivityRandomStream: Sendable {
    private var stream: SourceCanonicalUniformRandomStream
    public init(seed: Int32 = 0) { stream = SourceCanonicalUniformRandomStream(seed: seed) }
    public mutating func next(maximum: Int32) -> Int32 { stream.randomInt(maximum: maximum) }
}
