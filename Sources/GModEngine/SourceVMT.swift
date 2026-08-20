import Foundation

/// Errors raised while interpreting a Valve Material Type document.
public enum SourceVMTError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidRootCount(Int)
    case rootMustBeObject(String)
    case patchIncludeMissing
    case includeResolverRequired(String)
    case includeNotFound(String)
    case includeCycle([String])
    case maximumPatchDepthExceeded(Int, [String])
    case valueIsObject(String)
    case invalidNumber(String, String)
    case invalidBoolean(String, String)
    case invalidVector(String, String)
    case unexpectedVectorComponentCount(String, Int, ClosedRange<Int>)
    case invalidMatrix(String, String)

    public var description: String {
        switch self {
        case let .invalidRootCount(count):
            return "VMT must contain exactly one shader root; found \(count)"
        case let .rootMustBeObject(shader):
            return "VMT shader root '\(shader)' must contain an object"
        case .patchIncludeMissing:
            return "Patch VMT requires a string include parameter"
        case let .includeResolverRequired(path):
            return "Patch VMT include '\(path)' requires an include resolver"
        case let .includeNotFound(path):
            return "Patch VMT include was not found: \(path)"
        case let .includeCycle(paths):
            return "Patch VMT include cycle: \(paths.joined(separator: " -> "))"
        case let .maximumPatchDepthExceeded(limit, paths):
            return "Patch VMT include depth exceeds \(limit): \(paths.joined(separator: " -> "))"
        case let .valueIsObject(key):
            return "VMT parameter '\(key)' is an object, not a scalar value"
        case let .invalidNumber(key, value):
            return "VMT parameter '\(key)' is not a finite number: \(value)"
        case let .invalidBoolean(key, value):
            return "VMT parameter '\(key)' is not a numeric boolean: \(value)"
        case let .invalidVector(key, value):
            return "VMT parameter '\(key)' is not a numeric vector: \(value)"
        case let .unexpectedVectorComponentCount(key, count, expected):
            return "VMT parameter '\(key)' has \(count) vector components; expected \(expected)"
        case let .invalidMatrix(key, value):
            return "VMT parameter '\(key)' is not a Source matrix: \(value)"
        }
    }
}

/// Injected Source search-path boundary used to resolve `Patch` includes.
///
/// The resolver receives the include spelling verbatim. It is therefore able
/// to apply the host's real GAME mount order, BSP pack priority, and VPK path
/// rules instead of baking desktop filesystem assumptions into this parser.
public struct SourceVMTIncludeResolver: Sendable {
    public typealias Loader = @Sendable (_ logicalPath: String) throws -> String?

    private let loader: Loader

    public init(_ loader: @escaping Loader) {
        self.loader = loader
    }

    public func source(for logicalPath: String) throws -> String? {
        try loader(logicalPath)
    }
}

public struct SourceVMTVector2: Sendable, Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// The two matrix spellings accepted by Source material variables.
public enum SourceVMTMatrix: Sendable, Equatable {
    /// A bracketed row-major 4x4 matrix.
    case matrix4x4([Double])

    /// `center x y scale x y rotate degrees translate x y`.
    case textureTransform(
        center: SourceVMTVector2,
        scale: SourceVMTVector2,
        rotationDegrees: Double,
        translation: SourceVMTVector2
    )
}

/// One ordered material-proxy declaration. Duplicate proxy names are retained.
public struct SourceVMTProxy: Sendable, Equatable {
    public let name: String
    public let parameters: [SourceKeyValuesParser.Entry]
    public let conditional: String?

    public init(
        name: String,
        parameters: [SourceKeyValuesParser.Entry],
        conditional: String? = nil
    ) {
        self.name = name
        self.parameters = parameters
        self.conditional = conditional
    }
}

/// Ordered, spelling-preserving representation of a Source 1 VMT.
///
/// Values remain KeyValues strings or objects until a caller explicitly asks
/// for a typed conversion. This is intentional: shader-specific parameter
/// typing belongs to the material system and unknown addon parameters must not
/// be guessed or discarded.
public struct SourceVMTDocument: Sendable, Equatable {
    public typealias Entry = SourceKeyValuesParser.Entry
    public typealias Value = SourceKeyValuesParser.Value

    public let shader: String
    public let entries: [Entry]

    public init(shader: String, entries: [Entry]) {
        self.shader = shader
        self.entries = entries
    }

    /// Parses a standalone VMT and, when needed, expands a `Patch` chain using
    /// the ordering of Source SDK 2013 VBSP's `ExpandPatchFile`.
    ///
    /// This is specifically VBSP patch-tool compatibility; it must not be used
    /// as evidence that every runtime material-system branch has identical
    /// patch quirks. The SDK tool caps expansion at ten levels. Cycle detection
    /// is additionally explicit here so malformed addon content fails
    /// deterministically rather than silently producing a partial VMT.
    public static func parse(
        source: String,
        sourceName: String = "<memory>",
        resolver: SourceVMTIncludeResolver? = nil,
        maximumPatchDepth: Int = 10
    ) throws -> SourceVMTDocument {
        let safeLimit = max(0, maximumPatchDepth)
        let initialKey = normalizedIncludeIdentity(sourceName)
        return try parseResolved(
            source: source,
            sourceName: sourceName,
            resolver: resolver,
            maximumPatchDepth: safeLimit,
            depth: 0,
            includeStack: initialKey == "<memory>" ? [] : [initialKey]
        )
    }

    public func entries(named name: String) -> [Entry] {
        entries.filter { asciiCaseInsensitiveEqual($0.key, name) }
    }

    /// Source KeyValues lookup returns the first case-insensitive match.
    public func firstEntry(named name: String) -> Entry? {
        entries.first { asciiCaseInsensitiveEqual($0.key, name) }
    }

    /// Explicit last-match access for callers such as Lua table conversion.
    public func lastEntry(named name: String) -> Entry? {
        entries.last { asciiCaseInsensitiveEqual($0.key, name) }
    }

    public func string(named name: String) throws -> String? {
        guard let entry = firstEntry(named: name) else { return nil }
        guard case let .string(value) = entry.value else {
            throw SourceVMTError.valueIsObject(entry.key)
        }
        return value
    }

    public func number(named name: String) throws -> Double? {
        guard let value = try string(named: name) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = Double(trimmed), number.isFinite else {
            throw SourceVMTError.invalidNumber(name, value)
        }
        return number
    }

    /// Converts Source's numeric boolean spelling (`0` is false, nonzero true).
    public func boolean(named name: String) throws -> Bool? {
        guard let value = try string(named: name) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = Double(trimmed), number.isFinite else {
            throw SourceVMTError.invalidBoolean(name, value)
        }
        return number != 0
    }

    public func vector(
        named name: String,
        componentCount: ClosedRange<Int> = 1...4
    ) throws -> [Double]? {
        guard let value = try string(named: name) else { return nil }
        let components: [Double]
        do {
            components = try Self.numericComponents(value)
        } catch {
            throw SourceVMTError.invalidVector(name, value)
        }
        guard componentCount.contains(components.count) else {
            throw SourceVMTError.unexpectedVectorComponentCount(
                name,
                components.count,
                componentCount
            )
        }
        return components
    }

    public func matrix(named name: String) throws -> SourceVMTMatrix? {
        guard let value = try string(named: name) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        if (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
            || (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
        {
            guard let values = try? Self.numericComponents(trimmed), values.count == 16 else {
                throw SourceVMTError.invalidMatrix(name, value)
            }
            return .matrix4x4(values)
        }

        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard tokens.count == 11,
              asciiCaseInsensitiveEqual(tokens[0], "center"),
              asciiCaseInsensitiveEqual(tokens[3], "scale"),
              asciiCaseInsensitiveEqual(tokens[6], "rotate"),
              asciiCaseInsensitiveEqual(tokens[8], "translate"),
              let centerX = Self.finiteDouble(tokens[1]),
              let centerY = Self.finiteDouble(tokens[2]),
              let scaleX = Self.finiteDouble(tokens[4]),
              let scaleY = Self.finiteDouble(tokens[5]),
              let rotation = Self.finiteDouble(tokens[7]),
              let translateX = Self.finiteDouble(tokens[9]),
              let translateY = Self.finiteDouble(tokens[10]) else {
            throw SourceVMTError.invalidMatrix(name, value)
        }
        return .textureTransform(
            center: SourceVMTVector2(x: centerX, y: centerY),
            scale: SourceVMTVector2(x: scaleX, y: scaleY),
            rotationDegrees: rotation,
            translation: SourceVMTVector2(x: translateX, y: translateY)
        )
    }

    /// Ordered proxy blocks, including duplicate proxy class names.
    public var proxies: [SourceVMTProxy] {
        var result: [SourceVMTProxy] = []
        for block in entries(named: "proxies") {
            guard case let .object(proxyEntries) = block.value else { continue }
            for proxy in proxyEntries {
                guard case let .object(parameters) = proxy.value else { continue }
                result.append(
                    SourceVMTProxy(
                        name: proxy.key,
                        parameters: parameters,
                        conditional: proxy.conditional
                    )
                )
            }
        }
        return result
    }

    private static func parseResolved(
        source: String,
        sourceName: String,
        resolver: SourceVMTIncludeResolver?,
        maximumPatchDepth: Int,
        depth: Int,
        includeStack: [String]
    ) throws -> SourceVMTDocument {
        var document = try parseSingle(source: source)
        var currentDepth = depth
        var currentIncludeStack = includeStack

        while asciiCaseInsensitiveEqual(document.shader, "patch") {
            guard let includeEntry = document.firstEntry(named: "include"),
                  case let .string(includePath) = includeEntry.value,
                  !includePath.isEmpty else {
                throw SourceVMTError.patchIncludeMissing
            }
            guard currentDepth < maximumPatchDepth else {
                throw SourceVMTError.maximumPatchDepthExceeded(
                    maximumPatchDepth,
                    currentIncludeStack + [includePath]
                )
            }
            guard let resolver else {
                throw SourceVMTError.includeResolverRequired(includePath)
            }

            let identity = normalizedIncludeIdentity(includePath)
            if currentIncludeStack.contains(identity) {
                throw SourceVMTError.includeCycle(currentIncludeStack + [identity])
            }
            guard let includedSource = try resolver.source(for: includePath) else {
                throw SourceVMTError.includeNotFound(includePath)
            }

            // ExpandPatchFile loads the included file *without* recursively
            // expanding it. Its command ordering then has two observable
            // quirks which are intentionally preserved below:
            //
            // 1. `insert` assigns the included tree to the current tree before
            //    the subsequent `replace` lookup. Consequently a replace block
            //    from the same outer Patch is no longer visible.
            // 2. Without an outer insert, replace targets the immediate included
            //    tree. A nested Patch is therefore patched as a Patch; the outer
            //    replace is not deferred until the final shader is reached.
            //
            // Source KeyValues FindKey selects one section, not every duplicate
            // section, so firstEntry is the matching spelling-preserving model.
            var included = try parseSingle(source: includedSource)
            if let insertSection = document.firstEntry(named: "insert") {
                var merged = included.entries
                if case let .object(patchEntries) = insertSection.value {
                    merge(&merged, patchEntries: patchEntries, requiresExistingKey: false)
                }
                included = SourceVMTDocument(shader: included.shader, entries: merged)
                document = included
            }

            // Deliberately look up replace on `document` after the possible
            // insert assignment, exactly like materialpatch.cpp does.
            if let replaceSection = document.firstEntry(named: "replace") {
                var merged = included.entries
                if case let .object(patchEntries) = replaceSection.value {
                    merge(&merged, patchEntries: patchEntries, requiresExistingKey: true)
                }
                included = SourceVMTDocument(shader: included.shader, entries: merged)
                document = included
            }

            currentDepth += 1
            currentIncludeStack.append(identity)
        }

        return document
    }

    private static func parseSingle(source: String) throws -> SourceVMTDocument {
        var parser = SourceKeyValuesParser(
            source: source,
            options: .init(
                usesEscapeSequences: false,
                preserveKeyCase: true,
                preserveConditionals: true
            )
        )
        let roots = try parser.parse()
        guard roots.count == 1 else {
            throw SourceVMTError.invalidRootCount(roots.count)
        }
        let root = roots[0]
        guard case let .object(parsedEntries) = root.value else {
            throw SourceVMTError.rootMustBeObject(root.key)
        }
        return SourceVMTDocument(shader: root.key, entries: parsedEntries)
    }

    private static func merge(
        _ destination: inout [Entry],
        patchEntries: [Entry],
        requiresExistingKey: Bool
    ) {
        for patch in patchEntries {
            // Source SDK 2013's materialpatch.cpp InsertKeyValues only handles
            // scalar KeyValues data types. TYPE_NONE true subkeys (including
            // Proxies and addon-defined object blocks) are deliberately
            // ignored instead of being recursively merged.
            guard case .string = patch.value else { continue }

            guard let index = destination.firstIndex(where: {
                asciiCaseInsensitiveEqual($0.key, patch.key)
            }) else {
                if !requiresExistingKey { destination.append(patch) }
                continue
            }

            let existing = destination[index]
            destination[index] = Entry(
                key: existing.key,
                value: patch.value,
                conditional: patch.conditional ?? existing.conditional
            )
        }
    }

    private static func numericComponents(_ source: String) throws -> [Double] {
        var trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
            || (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
        {
            trimmed.removeFirst()
            trimmed.removeLast()
        }
        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace })
        guard !tokens.isEmpty else { throw SourceVMTError.invalidVector("", source) }
        return try tokens.map { token in
            guard let value = finiteDouble(String(token)) else {
                throw SourceVMTError.invalidVector("", source)
            }
            return value
        }
    }

    private static func finiteDouble(_ source: String) -> Double? {
        guard let value = Double(source), value.isFinite else { return nil }
        return value
    }
}

private func asciiCaseInsensitiveEqual(_ lhs: String, _ rhs: String) -> Bool {
    let lhsBytes = Array(lhs.utf8)
    let rhsBytes = Array(rhs.utf8)
    guard lhsBytes.count == rhsBytes.count else { return false }
    return zip(lhsBytes, rhsBytes).allSatisfy { left, right in
        let foldedLeft = (65...90).contains(left) ? left + 32 : left
        let foldedRight = (65...90).contains(right) ? right + 32 : right
        return foldedLeft == foldedRight
    }
}

private func normalizedIncludeIdentity(_ path: String) -> String {
    let slashNormalized = path.replacingOccurrences(of: "\\", with: "/")
    let bytes = slashNormalized.utf8.map { byte -> UInt8 in
        (65...90).contains(byte) ? byte + 32 : byte
    }
    return String(decoding: bytes, as: UTF8.self)
}
