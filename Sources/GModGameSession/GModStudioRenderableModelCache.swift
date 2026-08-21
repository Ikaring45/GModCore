import Foundation
import GModEngine

enum GModStudioModelPath {
    static func normalizedRelativeModelPath(_ path: String) -> String? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty,
              normalized == normalized.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              normalized.lowercased().hasPrefix("models/"),
              normalized.lowercased().hasSuffix(".mdl"),
              !normalized.hasPrefix("/"),
              !normalized.split(separator: "/").contains(".."),
              !normalized.utf8.contains(0) else {
            return nil
        }
        return normalized
    }

    static func cacheKey(_ path: String) -> String? {
        normalizedRelativeModelPath(path)?.lowercased()
    }
}

public struct GModStudioRenderableModelResourceID:
    Sendable,
    Equatable,
    Hashable,
    Comparable
{
    public let normalizedModelPath: String
    public let checksum: Int32
    public let bodyValue: Int
    public let skinFamilyIndex: Int

    public init(
        normalizedModelPath: String,
        checksum: Int32,
        bodyValue: Int,
        skinFamilyIndex: Int
    ) {
        self.normalizedModelPath = normalizedModelPath
        self.checksum = checksum
        self.bodyValue = bodyValue
        self.skinFamilyIndex = skinFamilyIndex
    }

    public static func < (
        lhs: GModStudioRenderableModelResourceID,
        rhs: GModStudioRenderableModelResourceID
    ) -> Bool {
        if lhs.normalizedModelPath != rhs.normalizedModelPath {
            return lhs.normalizedModelPath < rhs.normalizedModelPath
        }
        if lhs.checksum != rhs.checksum { return lhs.checksum < rhs.checksum }
        if lhs.bodyValue != rhs.bodyValue { return lhs.bodyValue < rhs.bodyValue }
        return lhs.skinFamilyIndex < rhs.skinFamilyIndex
    }
}

public struct GModStudioRenderableModelResource: Sendable, Equatable {
    public let id: GModStudioRenderableModelResourceID
    public let model: GModStudioRenderableModelSnapshot

    public init(
        id: GModStudioRenderableModelResourceID,
        model: GModStudioRenderableModelSnapshot
    ) {
        self.id = id
        self.model = model
    }
}

public struct GModStudioRenderableModelCachePolicy: Sendable, Equatable {
    public let maximumEntryCount: Int
    /// Vertex and index payload only. Material strings are independently
    /// bounded by the Studio compile policy.
    public let maximumGeometryByteCount: Int

    public init(maximumEntryCount: Int, maximumGeometryByteCount: Int) {
        self.maximumEntryCount = maximumEntryCount
        self.maximumGeometryByteCount = maximumGeometryByteCount
    }

    public static let initialIpadPropScene = Self(
        maximumEntryCount: 128,
        maximumGeometryByteCount: 128 * 1_024 * 1_024
    )
}

public enum GModStudioRenderableModelCacheError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    case invalidPolicy(entries: Int, geometryBytes: Int)
    case invalidModelPath(String)
    case geometryByteCountOverflow(String)
    case geometryExceedsCache(model: String, requested: Int, cap: Int)

    public var description: String {
        switch self {
        case let .invalidPolicy(entries, bytes):
            return "invalid Studio render cache policy entries=\(entries) bytes=\(bytes)"
        case let .invalidModelPath(path):
            return "invalid Studio render model path '\(path)'"
        case let .geometryByteCountOverflow(model):
            return "Studio render geometry byte count overflow for '\(model)'"
        case let .geometryExceedsCache(model, requested, cap):
            return "Studio render geometry '\(model)' needs \(requested) bytes; cache cap is \(cap)"
        }
    }
}

public enum GModStudioRenderableModelResolutionFailure: Sendable, Equatable {
    case assetUnavailable(SourceStudioModelAssetUnavailable)
    case compile(GModStudioRenderableModelCompileError)
    case cache(GModStudioRenderableModelCacheError)
    case unexpected(String)
}

public enum GModStudioRenderableModelResolution: Sendable, Equatable {
    case resolved(GModStudioRenderableModelResource)
    case failed(GModStudioRenderableModelResolutionFailure)
}

public protocol GModStudioRenderableModelResolving: Sendable {
    func resolve(
        model: SourceEntityModelReference,
        bodyValue: Int,
        skinFamilyIndex: Int
    ) -> GModStudioRenderableModelResolution
}

/// Bounded session-local LRU. Entity pose/revision never enters its key, so a
/// moving prop reuses the same immutable Studio resource.
public final class GModStudioRenderableModelCache:
    GModStudioRenderableModelResolving,
    @unchecked Sendable
{
    private struct Key: Hashable {
        let normalizedModelPath: String
        let bodyValue: Int
        let skinFamilyIndex: Int
    }

    private struct Entry {
        let resolution: GModStudioRenderableModelResolution
        let geometryBytes: Int
    }

    private let lock = NSLock()
    private let policy: GModStudioRenderableModelCachePolicy
    private let compile: @Sendable (
        SourceEntityModelReference,
        Int,
        Int
    ) -> GModStudioRenderableModelResolution
    private var entries: [Key: Entry] = [:]
    private var leastToMostRecent: [Key] = []
    private var retainedGeometryBytes = 0

    public convenience init(
        repository: GModStudioModelRepository,
        compilePolicy: GModStudioRenderableModelCompilePolicy = .initialIpadProp,
        cachePolicy: GModStudioRenderableModelCachePolicy = .initialIpadPropScene
    ) throws {
        try self.init(policy: cachePolicy) { model, bodyValue, skinFamilyIndex in
            guard let normalized = GModStudioModelPath.cacheKey(model.path) else {
                return .failed(.cache(.invalidModelPath(model.path)))
            }
            switch repository.renderAsset(for: model) {
            case let .unavailable(error):
                return .failed(.assetUnavailable(error))
            case let .loaded(asset):
                do {
                    let compiled = try GModStudioRenderableModelCompiler.compile(
                        asset: asset,
                        bodyValue: bodyValue,
                        skinFamilyIndex: skinFamilyIndex,
                        policy: compilePolicy
                    )
                    return .resolved(GModStudioRenderableModelResource(
                        id: GModStudioRenderableModelResourceID(
                            normalizedModelPath: normalized,
                            checksum: compiled.checksum,
                            bodyValue: bodyValue,
                            skinFamilyIndex: skinFamilyIndex
                        ),
                        model: compiled
                    ))
                } catch let error as GModStudioRenderableModelCompileError {
                    return .failed(.compile(error))
                } catch {
                    return .failed(.unexpected(String(reflecting: type(of: error))))
                }
            }
        }
    }

    init(
        policy: GModStudioRenderableModelCachePolicy,
        compile: @escaping @Sendable (
            SourceEntityModelReference,
            Int,
            Int
        ) -> GModStudioRenderableModelResolution
    ) throws {
        guard policy.maximumEntryCount > 0,
              policy.maximumGeometryByteCount > 0 else {
            throw GModStudioRenderableModelCacheError.invalidPolicy(
                entries: policy.maximumEntryCount,
                geometryBytes: policy.maximumGeometryByteCount
            )
        }
        self.policy = policy
        self.compile = compile
    }

    public func resolve(
        model: SourceEntityModelReference,
        bodyValue: Int,
        skinFamilyIndex: Int
    ) -> GModStudioRenderableModelResolution {
        guard let normalized = GModStudioModelPath.cacheKey(model.path) else {
            return .failed(.cache(.invalidModelPath(model.path)))
        }
        let key = Key(
            normalizedModelPath: normalized,
            bodyValue: bodyValue,
            skinFamilyIndex: skinFamilyIndex
        )
        lock.lock()
        if let cached = entries[key] {
            touch(key)
            lock.unlock()
            return cached.resolution
        }
        lock.unlock()

        // Studio I/O and decode must not hold the cache lock. A simultaneous
        // miss may compile the same immutable appearance twice; the first
        // committed result wins and both callers observe that one entry.
        let compiledResolution = compile(model, bodyValue, skinFamilyIndex)
        let resolution: GModStudioRenderableModelResolution
        let geometryBytes: Int
        switch compiledResolution {
        case let .resolved(resource):
            guard let count = Self.geometryByteCount(resource.model) else {
                resolution = .failed(.cache(.geometryByteCountOverflow(model.path)))
                geometryBytes = 0
                break
            }
            guard count <= policy.maximumGeometryByteCount else {
                resolution = .failed(.cache(.geometryExceedsCache(
                    model: model.path,
                    requested: count,
                    cap: policy.maximumGeometryByteCount
                )))
                geometryBytes = 0
                break
            }
            resolution = compiledResolution
            geometryBytes = count
        case .failed:
            resolution = compiledResolution
            geometryBytes = 0
        }

        lock.lock()
        defer { lock.unlock() }
        if let cached = entries[key] {
            touch(key)
            return cached.resolution
        }
        evictToFit(geometryBytes)
        entries[key] = Entry(
            resolution: resolution,
            geometryBytes: geometryBytes
        )
        leastToMostRecent.append(key)
        retainedGeometryBytes += geometryBytes
        return resolution
    }

    public var cachedEntryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    public var cachedGeometryByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return retainedGeometryBytes
    }

    public func removeAll() {
        lock.lock()
        entries.removeAll(keepingCapacity: false)
        leastToMostRecent.removeAll(keepingCapacity: false)
        retainedGeometryBytes = 0
        lock.unlock()
    }

    private func touch(_ key: Key) {
        if let index = leastToMostRecent.firstIndex(of: key) {
            leastToMostRecent.remove(at: index)
        }
        leastToMostRecent.append(key)
    }

    private func evictToFit(_ geometryBytes: Int) {
        while !leastToMostRecent.isEmpty && (
            entries.count >= policy.maximumEntryCount ||
                retainedGeometryBytes >
                    policy.maximumGeometryByteCount - geometryBytes
        ) {
            let key = leastToMostRecent.removeFirst()
            guard let removed = entries.removeValue(forKey: key) else { continue }
            retainedGeometryBytes -= removed.geometryBytes
        }
    }

    private static func geometryByteCount(
        _ model: GModStudioRenderableModelSnapshot
    ) -> Int? {
        let (vertexBytes, vertexOverflow) = model.vertices.count
            .multipliedReportingOverflow(by: 8 * MemoryLayout<Float>.size)
        let (indexBytes, indexOverflow) = model.indices.count
            .multipliedReportingOverflow(by: MemoryLayout<UInt32>.size)
        let (total, totalOverflow) = vertexBytes.addingReportingOverflow(indexBytes)
        guard !vertexOverflow, !indexOverflow, !totalOverflow else { return nil }
        return total
    }
}
