import Foundation

extension SourceVGUIScheme {
    public struct FontDefinition: Equatable, Sendable {
        public let alias: String
        public let face: String
        public let tall: Int
        public let weight: Int
        public let blurSize: Int
        public let scanlines: Int
        /// Surface-compatible effect names; Source's dropshadow maps to shadow.
        public let flags: [String: Bool]

        /// Content-addressed, runtime-local registration. Never overwrites
        /// stock Default/Derma font names when GameUI uses a different Scheme.
        var registrationName: String {
            let fields = [alias.lowercased(), face, String(tall), String(weight), String(blurSize), String(scanlines)] +
                flags.keys.sorted().map { "\($0)=\(flags[$0] == true ? 1 : 0)" }
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in fields.joined(separator: "\u{0}").utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
            return "GarrysPAD.GameUI." + String(hash, radix: 16)
        }
    }

    /// Resolves one unscaled glyph set for the current logical viewport.
    /// Multiple overlapping glyph ranges/fallback faces cannot be represented
    /// by Surface's single-face descriptor and are not silently collapsed.
    public func font(_ alias: String, viewportHeight: Int) throws -> FontDefinition {
        guard viewportHeight > 0,
              let entry = fonts.first(where: { $0.key.caseInsensitiveCompare(alias) == .orderedSame }),
              case let .object(variants) = entry.value else { throw SchemeError.missingFont(alias) }
        func field(_ key: String, _ values: [SourceKeyValuesParser.Entry]) -> String? {
            guard let entry = values.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }),
                  case let .string(value) = entry.value else { return nil }
            return value
        }
        var matches: [[SourceKeyValuesParser.Entry]] = []
        for variant in variants {
            guard case let .object(values) = variant.value else { throw SchemeError.unsupportedFont(alias) }
            if let range = field("yres", values) {
                let parts = range.split(whereSeparator: { $0.isWhitespace })
                let numbers = parts.compactMap { Int($0) }
                guard parts.count == 2, numbers.count == 2, numbers[0] >= 0, numbers[1] >= numbers[0] else {
                    throw SchemeError.unsupportedFont(alias)
                }
                if !(numbers[0]...numbers[1]).contains(viewportHeight) { continue }
            }
            matches.append(values)
        }
        guard matches.count == 1, let values = matches.first else { throw SchemeError.unsupportedFont(alias) }
        let flagFields = ["antialias", "underline", "italic", "strikeout", "symbol", "dropshadow", "outline", "additive"]
        let supported = Set(flagFields + ["name", "tall", "weight", "blursize", "scanlines", "yres"])
        guard values.allSatisfy({ supported.contains($0.key.lowercased()) }),
              let face = field("name", values), !face.isEmpty, face.utf8.count <= 31,
              !face.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let tall = Int(field("tall", values) ?? ""), (4...255).contains(tall),
              let weight = Int32(field("weight", values) ?? "") else {
            throw SchemeError.unsupportedFont(alias)
        }
        var flags: [String: Bool] = [:]
        for key in flagFields {
            let value = field(key, values) ?? "0"
            guard value == "0" || value == "1" else { throw SchemeError.unsupportedFont(alias) }
            flags[key == "dropshadow" ? "shadow" : key] = value == "1"
        }
        guard let blur = Int(field("blursize", values) ?? "0"), (0...80).contains(blur),
              let scanlines = Int32(field("scanlines", values) ?? "0") else { throw SchemeError.unsupportedFont(alias) }
        return .init(alias: alias, face: face, tall: tall, weight: Int(weight), blurSize: blur,
            scanlines: Int(scanlines), flags: flags)
    }
}
