import Foundation

public enum SourceViewModelSequenceQuery: Sendable, Equatable {
    case name(String)
    case index(Int32)
}

public struct SourceViewModelSequenceMetadata: Sendable, Equatable {
    public let index: Int32
    public let name: String
    public let duration: Float
    public let frameCount: Int32
    public let loops: Bool
    public let cycleRate: Float

    public init(index: Int32, name: String, duration: Float, frameCount: Int32 = 0,
                loops: Bool = false, cycleRate: Float? = nil) {
        self.index = index
        self.name = name
        self.duration = duration
        self.frameCount = frameCount
        self.loops = loops
        self.cycleRate = cycleRate ?? (duration > 0 ? 1 / duration : 0)
    }
}

public enum SourceViewModelSequenceError: Error, Sendable, Equatable {
    case unsupportedBlend(sequence: Int)
    case invalidTiming(sequence: Int)
}

/// Exact decoded single-blend sequence metadata. Pose-parameter interpolation
/// is not guessed for multi-blend sequences. No pose/vertex decoding is needed.
public struct SourceViewModelSequenceLibrary: Sendable {
    private let model: SourceStudioAnimationModel
    public init(model: SourceStudioAnimationModel) { self.model = model }

    public func resolve(_ query: SourceViewModelSequenceQuery) throws -> SourceViewModelSequenceMetadata? {
        let index: Int
        switch query {
        case let .index(value): index = Int(value)
        case let .name(name):
            guard let found = model.sequences.firstIndex(where: {
                $0.label.caseInsensitiveCompare(name) == .orderedSame
            }) else { return nil }
            index = found
        }
        guard model.sequences.indices.contains(index) else { return nil }
        let sequence = model.sequences[index]
        guard sequence.animationIndices.count == 1 else {
            throw SourceViewModelSequenceError.unsupportedBlend(sequence: index)
        }
        let animationIndex = try model.animationIndex(sequenceIndex: index, blendIndex: 0)
        let animation = model.animations[animationIndex]
        guard animation.frameCount > 0,
              animation.framesPerSecond.isFinite,
              animation.framesPerSecond >= 0 else {
            throw SourceViewModelSequenceError.invalidTiming(sequence: index)
        }
        // Match the single-blend Studio_CPS -> Studio_Duration operation order.
        let cyclesPerSecond = animation.frameCount == 1 ? 0 : animation.framesPerSecond / Float(animation.frameCount - 1)
        let duration: Float = cyclesPerSecond == 0 ? 0 : 1 / cyclesPerSecond
        guard duration.isFinite else { throw SourceViewModelSequenceError.invalidTiming(sequence: index) }
        return SourceViewModelSequenceMetadata(index: Int32(index), name: sequence.label,
            duration: duration, frameCount: Int32(animation.frameCount),
            loops: sequence.flags & 1 != 0, cycleRate: cyclesPerSecond)
    }
}
