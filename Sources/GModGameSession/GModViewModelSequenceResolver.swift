import Foundation
import GModEngine

/// Bounded metadata cache backed by the same immutable MDL payload used for
/// rendering. Missing assets remain missing; malformed data is not timed by a
/// guessed animation duration.
final class GModViewModelSequenceResolver: @unchecked Sendable {
    private let repository: GModStudioModelRepository
    private let lock = NSLock()
    private var libraries: [String: SourceViewModelSequenceLibrary] = [:]
    private var order: [String] = []
    private var activityRandom = SourceViewModelActivityRandomStream()
    init(repository: GModStudioModelRepository) { self.repository = repository }

    func resolve(model: SourceEntityModelReference, query: SourceViewModelSequenceQuery)
        throws -> SourceViewModelSequenceMetadata? {
        guard let key = GModStudioModelPath.cacheKey(model.path) else { return nil }
        lock.lock()
        let cached = libraries[key]
        lock.unlock()
        if let cached { return try resolve(library: cached, query: query) }
        guard case let .loaded(asset) = repository.renderAsset(for: model) else { return nil }
        let library = SourceViewModelSequenceLibrary(model:
            try SourceStudioAnimationDecoder.decode(mdlData: asset.renderPayload.mdlData))
        lock.lock()
        if libraries[key] == nil {
            if order.count >= 32 { libraries.removeValue(forKey: order.removeFirst()) }
            order.append(key)
            libraries[key] = library
        }
        lock.unlock()
        return try resolve(library: library, query: query)
    }

    private func resolve(library: SourceViewModelSequenceLibrary, query: SourceViewModelSequenceQuery)
        throws -> SourceViewModelSequenceMetadata? {
        lock.lock()
        defer { lock.unlock() }
        return try library.resolve(query, randomInt: { maximum in self.activityRandom.next(maximum: maximum) })
    }
}
