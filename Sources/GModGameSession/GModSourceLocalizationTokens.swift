import Foundation
import GModEngine

public enum GModSourceLocalizationError: Error, Equatable {
    case tooLarge
    case invalidEncoding
    case missingTokens
    case invalidToken(String)
}

/// Reads the owned Source `lang { Tokens { ... } }` catalogs. These are
/// distinct from GMod's Java-properties catalogs and often UTF-16 encoded.
/// No translations or aliases for misspelled tokens are invented here.
public enum GModSourceLocalizationTokens {
    public static let maximumByteCount = 8 * 1_024 * 1_024

    public static func parse(data: Data) throws -> [String: String] {
        guard data.count <= maximumByteCount else { throw GModSourceLocalizationError.tooLarge }
        let encoding: String.Encoding
        let offset: Int
        if data.starts(with: [0xFF, 0xFE]) {
            encoding = .utf16LittleEndian; offset = 2
        } else if data.starts(with: [0xFE, 0xFF]) {
            encoding = .utf16BigEndian; offset = 2
        } else {
            encoding = .utf8; offset = data.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        }
        guard let source = String(data: data.dropFirst(offset), encoding: encoding),
              !source.contains("\0") else { throw GModSourceLocalizationError.invalidEncoding }
        var parser = SourceKeyValuesParser(source: source,
            options: .init(usesEscapeSequences: true, preserveKeyCase: true, preserveConditionals: true))
        let roots = try parser.parse()
        guard roots.count == 1, roots[0].key.lowercased() == "lang",
              roots[0].conditional == nil, case let .object(fields) = roots[0].value,
              let tokens = fields.first(where: { $0.key.lowercased() == "tokens" }),
              tokens.conditional == nil, case let .object(entries) = tokens.value else {
            throw GModSourceLocalizationError.missingTokens
        }
        var result: [String: String] = [:]
        for entry in entries {
            // A platform-conditional token needs an explicit condition context;
            // do not silently select a Windows/Linux branch on an iPad host.
            guard entry.conditional == nil else { continue }
            guard case let .string(value) = entry.value else {
                throw GModSourceLocalizationError.invalidToken(entry.key)
            }
            result[entry.key] = value
        }
        return result
    }

    /// Bounded GAME reads preserve the existing loose/VPK mount precedence.
    /// File order is this host's explicit merge policy, not native-engine parity.
    public static func load(
        languageCode: String,
        source: GModContentPackAssetSource,
        diagnostic: (String) -> Void = { _ in }
    ) -> [String: String] {
        let language: String
        switch languageCode {
        case "en": language = "english"
        case "ja": language = "japanese"
        default: return [:]
        }
        var result: [String: String] = [:]
        for base in ["valve", "platform", "vgui", "gameui", "hl2", "garrysmod"] {
            let path = "resource/\(base)_\(language).txt"
            do {
                guard let data = try source.data(for: path, maximumByteCount: UInt64(maximumByteCount)) else { continue }
                result.merge(try parse(data: data)) { _, later in later }
            } catch {
                diagnostic("Source localization failed for \(path): \(error)")
            }
        }
        // Native VGUI tokens and GLua weapon/entity phrases are separate
        // catalogs. Discover both loose and mounted VPK properties, then read
        // each logical path through the existing GAME precedence resolver.
        let prefix = "resource/localization/\(languageCode)/"
        var paths = Set<String>()
        for entry in source.pack.entries.values {
            let path = entry.path.lowercased()
            for root in ["garrysmod/", "platform/", "sourceengine/"] where path.hasPrefix(root) {
                let logical = String(path.dropFirst(root.count))
                if logical.hasPrefix(prefix), logical.hasSuffix(".properties") { paths.insert(logical) }
            }
        }
        for archive in source.archives {
            for path in archive.logicalFilePaths {
                let logical = path.utf8String.lowercased()
                if logical.hasPrefix(prefix), logical.hasSuffix(".properties") { paths.insert(logical) }
            }
        }
        for path in paths.sorted() {
            do {
                guard let data = try source.data(for: path, maximumByteCount: UInt64(maximumByteCount)) else { continue }
                result.merge(try GModJavaPropertiesParser.parse(data: data)) { _, later in later }
            } catch {
                diagnostic("GMod localization failed for \(path): \(error)")
            }
        }
        return result
    }
}
