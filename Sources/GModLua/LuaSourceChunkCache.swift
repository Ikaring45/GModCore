import Foundation

/// Process-local cache of successfully parsed immutable Lua source chunks.
///
/// A chunk contains syntax only: globals, closure environments, function
/// objects, GC ownership, and execution frames are still created by each
/// ``LuaState``. This is therefore safe to share between the SERVER and CLIENT
/// states which read the same immutable stock Lua while preserving completely
/// separate realm execution.
final class LuaSourceChunkCache: @unchecked Sendable {
    static let shared = LuaSourceChunkCache()

    private final class Entry: NSObject {
        let chunk: LuaChunk

        init(chunk: LuaChunk) {
            self.chunk = chunk
        }
    }

    private let storage = NSCache<NSString, Entry>()

    private init() {
        // Bound third-party/addon source retention. Eviction only causes a
        // future reparse and cannot change Lua behavior.
        storage.countLimit = 512
        storage.totalCostLimit = 32 * 1_024 * 1_024
    }

    func chunk(for source: String) -> LuaChunk? {
        storage.object(forKey: source as NSString)?.chunk
    }

    func insert(_ chunk: LuaChunk, for source: String) {
        storage.setObject(
            Entry(chunk: chunk),
            forKey: source as NSString,
            cost: source.utf8.count
        )
    }
}
