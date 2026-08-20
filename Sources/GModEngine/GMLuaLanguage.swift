import Foundation
import GModLua

/// Host-supplied localization phrases for one Lua state.
///
/// Keys use the form accepted by `language.Add`, without the display-time `#`
/// marker. The host is responsible for selecting and merging the real locale,
/// fallback locale, mounted-game and addon catalogs before it supplies this
/// snapshot. An empty snapshot is valid: desktop GMod documents that an
/// unknown phrase falls back to the input string.
public struct GMLuaLanguageConfiguration: Sendable, Equatable {
    public let phrases: [String: String]

    public init(phrases: [String: String] = [:]) {
        self.phrases = phrases
    }

    public static let empty = GMLuaLanguageConfiguration()
}

/// Logical client/menu localization registry behind GLua's `language` table.
///
/// The native host catalog is kept separate from phrases registered by Lua so
/// the host can change locale without erasing addon registrations. A missing
/// phrase intentionally returns its original input, matching the public GMod
/// contract rather than inventing English strings in the compatibility layer.
public final class GMLuaLanguageRegistry: @unchecked Sendable {
    /// Public GMod documentation caps `language.GetPhrase` results at 4000
    /// bytes. Lua strings are byte sequences, so the cap is applied without a
    /// lossy Unicode round trip.
    public static let maximumReturnedByteCount = 4_000

    private let lock = NSLock()
    private var hostPhrases: [LuaString: LuaString]
    private var luaPhrases: [LuaString: LuaString] = [:]

    fileprivate init(configuration: GMLuaLanguageConfiguration) {
        hostPhrases = Self.luaDictionary(configuration.phrases)
    }

    /// Replaces only the host-owned catalog. Phrases previously registered by
    /// `language.Add` remain available for the lifetime of this Lua state.
    public func replaceHostPhrases(_ configuration: GMLuaLanguageConfiguration) {
        let replacement = Self.luaDictionary(configuration.phrases)
        lock.lock()
        hostPhrases = replacement
        lock.unlock()
    }

    public func clearHostPhrases() {
        replaceHostPhrases(.empty)
    }

    /// Returns a translated phrase or the exact input when none is registered.
    /// A leading `#` participates in lookup but is preserved by the unknown-key
    /// fallback. This covers the two forms used by GMod's bundled Lua while
    /// retaining the documented input-string fallback.
    public func phrase(for input: LuaString) -> LuaString {
        let lookupKey = Self.lookupKey(for: input)
        lock.lock()
        let translated = luaPhrases[lookupKey] ?? hostPhrases[lookupKey]
        lock.unlock()
        return Self.capped(translated ?? input)
    }

    /// Registers an addon phrase under the documented marker-free key.
    public func add(placeholder: LuaString, fullText: LuaString) {
        lock.lock()
        luaPhrases[placeholder] = fullText
        lock.unlock()
    }

    @discardableResult
    public static func install(
        into state: LuaState,
        realm: GMLuaRealm,
        configuration: GMLuaLanguageConfiguration = .empty
    ) throws -> GMLuaLanguageRegistry? {
        // Facepunch documents both functions for CLIENT and MENU only.
        guard realm != .server else { return nil }

        let registry = GMLuaLanguageRegistry(configuration: configuration)
        let languageTable: LuaTable
        if case let .table(existing) = state.getGlobal("language") {
            languageTable = existing
        } else {
            languageTable = LuaTable()
        }

        let getPhrase = LuaNativeFunctionBox(
            { [registry] arguments in
                guard let first = arguments.first,
                      case let .string(phrase) = first else {
                    throw LuaError.runtime(
                        "bad argument #1 to 'GetPhrase' (string expected)"
                    )
                }
                return [.string(registry.phrase(for: phrase))]
            },
            debugName: "language.GetPhrase"
        )
        try state.setRawTableValue(
            .nativeFunction(getPhrase),
            for: .string("GetPhrase"),
            in: languageTable
        )

        let add = LuaNativeFunctionBox(
            { [registry] arguments in
                guard let first = arguments.first,
                      case let .string(placeholder) = first else {
                    throw LuaError.runtime(
                        "bad argument #1 to 'Add' (string expected)"
                    )
                }
                guard arguments.count >= 2,
                      case let .string(fullText) = arguments[1] else {
                    throw LuaError.runtime(
                        "bad argument #2 to 'Add' (string expected)"
                    )
                }
                registry.add(placeholder: placeholder, fullText: fullText)
                return []
            },
            debugName: "language.Add"
        )
        try state.setRawTableValue(
            .nativeFunction(add),
            for: .string("Add"),
            in: languageTable
        )

        state.setGlobal("language", value: .table(languageTable))
        return registry
    }

    private static func luaDictionary(
        _ phrases: [String: String]
    ) -> [LuaString: LuaString] {
        var result: [LuaString: LuaString] = [:]
        result.reserveCapacity(phrases.count)
        for (placeholder, fullText) in phrases {
            result[LuaString(placeholder)] = LuaString(fullText)
        }
        return result
    }

    private static func lookupKey(for input: LuaString) -> LuaString {
        guard input.count > 0, input[0] == UInt8(ascii: "#") else {
            return input
        }
        return input.slice(1..<input.count)
    }

    private static func capped(_ value: LuaString) -> LuaString {
        guard value.count > maximumReturnedByteCount else { return value }
        return LuaString(bytes: Array(value.bytes.prefix(maximumReturnedByteCount)))
    }
}
