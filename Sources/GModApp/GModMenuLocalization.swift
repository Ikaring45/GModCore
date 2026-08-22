import Foundation
import GModGameAssets

enum GModJavaPropertiesParserError: Error, Equatable, CustomStringConvertible {
    case invalidUnicodeEscape(line: Int, escape: String)

    var description: String {
        switch self {
        case let .invalidUnicodeEscape(line, escape):
            return "invalid Java properties Unicode escape at line \(line): \(escape)"
        }
    }
}

/// Parser for the Java `.properties` files shipped in GMod content packs.
/// It intentionally implements the file format rather than relying on
/// `NSDictionary(contentsOf:)`, which does not preserve Java continuation and
/// escape semantics consistently across Foundation versions.
enum GModJavaPropertiesParser {
    static func parse(data: Data) throws -> [String: String] {
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return try parse(text)
    }

    static func parse(_ source: String) throws -> [String: String] {
        var normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if normalized.unicodeScalars.first?.value == 0xFEFF {
            normalized.removeFirst()
        }

        let physicalLines = normalized.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        var result: [String: String] = [:]
        var logicalLine = ""
        var logicalStartLine = 1
        var isContinuing = false

        func trailingBackslashCount(_ value: String) -> Int {
            var count = 0
            for scalar in value.unicodeScalars.reversed() {
                guard scalar.value == 0x5C else { break }
                count += 1
            }
            return count
        }

        for (index, slice) in physicalLines.enumerated() {
            var physical = String(slice)
            if isContinuing {
                while let first = physical.first,
                      Self.isPropertyWhitespace(first) {
                    physical.removeFirst()
                }
            } else {
                logicalLine = ""
                logicalStartLine = index + 1
            }
            logicalLine.append(physical)

            if trailingBackslashCount(logicalLine).isMultiple(of: 2) {
                try parseLogicalLine(
                    logicalLine,
                    lineNumber: logicalStartLine,
                    into: &result
                )
                logicalLine = ""
                isContinuing = false
            } else {
                logicalLine.removeLast()
                isContinuing = true
            }
        }

        if isContinuing || !logicalLine.isEmpty {
            try parseLogicalLine(
                logicalLine,
                lineNumber: logicalStartLine,
                into: &result
            )
        }
        return result
    }

    private static func parseLogicalLine(
        _ line: String,
        lineNumber: Int,
        into result: inout [String: String]
    ) throws {
        let scalars = Array(line.unicodeScalars)
        var start = 0
        while start < scalars.count, isPropertyWhitespace(scalars[start]) {
            start += 1
        }
        guard start < scalars.count,
              scalars[start].value != 0x23,
              scalars[start].value != 0x21 else {
            return
        }

        var separator = scalars.count
        var separatorWasWhitespace = false
        var escaped = false
        var index = start
        while index < scalars.count {
            let scalar = scalars[index]
            if escaped {
                escaped = false
            } else if scalar.value == 0x5C {
                escaped = true
            } else if scalar.value == 0x3D || scalar.value == 0x3A {
                separator = index
                break
            } else if isPropertyWhitespace(scalar) {
                separator = index
                separatorWasWhitespace = true
                break
            }
            index += 1
        }

        var valueStart = separator
        if separator < scalars.count {
            if separatorWasWhitespace {
                while valueStart < scalars.count,
                      isPropertyWhitespace(scalars[valueStart]) {
                    valueStart += 1
                }
                if valueStart < scalars.count,
                   scalars[valueStart].value == 0x3D
                    || scalars[valueStart].value == 0x3A {
                    valueStart += 1
                }
            } else {
                valueStart += 1
            }
            while valueStart < scalars.count,
                  isPropertyWhitespace(scalars[valueStart]) {
                valueStart += 1
            }
        }

        let rawKey = String(String.UnicodeScalarView(scalars[start..<separator]))
        let rawValue = valueStart < scalars.count
            ? String(String.UnicodeScalarView(scalars[valueStart...]))
            : ""
        let key = try unescape(rawKey, lineNumber: lineNumber)
        let value = try unescape(rawValue, lineNumber: lineNumber)
        result[key] = value
    }

    private static func unescape(
        _ raw: String,
        lineNumber: Int
    ) throws -> String {
        let scalars = Array(raw.unicodeScalars)
        var output: [UnicodeScalar] = []
        output.reserveCapacity(scalars.count)
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar.value == 0x5C else {
                output.append(scalar)
                index += 1
                continue
            }

            index += 1
            guard index < scalars.count else {
                output.append("\\")
                break
            }

            switch scalars[index].value {
            case 0x74:
                output.append("\t")
                index += 1
            case 0x6E:
                output.append("\n")
                index += 1
            case 0x72:
                output.append("\r")
                index += 1
            case 0x66:
                output.append("\u{000C}")
                index += 1
            case 0x75:
                let first = try unicodeUnit(
                    in: scalars,
                    uIndex: index,
                    lineNumber: lineNumber
                )
                index += 5
                if (0xD800...0xDBFF).contains(first) {
                    guard index + 5 < scalars.count,
                          scalars[index].value == 0x5C,
                          scalars[index + 1].value == 0x75 else {
                        throw GModJavaPropertiesParserError.invalidUnicodeEscape(
                            line: lineNumber,
                            escape: "\\u\(hex(first))"
                        )
                    }
                    let second = try unicodeUnit(
                        in: scalars,
                        uIndex: index + 1,
                        lineNumber: lineNumber
                    )
                    guard (0xDC00...0xDFFF).contains(second) else {
                        throw GModJavaPropertiesParserError.invalidUnicodeEscape(
                            line: lineNumber,
                            escape: "\\u\(hex(first))\\u\(hex(second))"
                        )
                    }
                    let scalarValue = 0x1_0000
                        + (UInt32(first - 0xD800) << 10)
                        + UInt32(second - 0xDC00)
                    guard let combined = UnicodeScalar(scalarValue) else {
                        throw GModJavaPropertiesParserError.invalidUnicodeEscape(
                            line: lineNumber,
                            escape: "\\u\(hex(first))\\u\(hex(second))"
                        )
                    }
                    output.append(combined)
                    index += 6
                } else {
                    guard !(0xDC00...0xDFFF).contains(first),
                          let decoded = UnicodeScalar(first) else {
                        throw GModJavaPropertiesParserError.invalidUnicodeEscape(
                            line: lineNumber,
                            escape: "\\u\(hex(first))"
                        )
                    }
                    output.append(decoded)
                }
            default:
                // Java properties treats a backslash before an otherwise
                // unknown character as quoting that character.
                output.append(scalars[index])
                index += 1
            }
        }
        return String(String.UnicodeScalarView(output))
    }

    private static func unicodeUnit(
        in scalars: [UnicodeScalar],
        uIndex: Int,
        lineNumber: Int
    ) throws -> UInt16 {
        guard uIndex + 4 < scalars.count else {
            let suffix = String(String.UnicodeScalarView(scalars[uIndex...]))
            throw GModJavaPropertiesParserError.invalidUnicodeEscape(
                line: lineNumber,
                escape: "\\\(suffix)"
            )
        }
        let digits = scalars[(uIndex + 1)...(uIndex + 4)]
        var value: UInt16 = 0
        for scalar in digits {
            guard let nibble = hexValue(scalar) else {
                let escape = String(String.UnicodeScalarView(
                    scalars[uIndex...(uIndex + 4)]
                ))
                throw GModJavaPropertiesParserError.invalidUnicodeEscape(
                    line: lineNumber,
                    escape: "\\\(escape)"
                )
            }
            value = (value << 4) | UInt16(nibble)
        }
        return value
    }

    private static func hexValue(_ scalar: UnicodeScalar) -> UInt8? {
        switch scalar.value {
        case 0x30...0x39: return UInt8(scalar.value - 0x30)
        case 0x41...0x46: return UInt8(scalar.value - 0x41 + 10)
        case 0x61...0x66: return UInt8(scalar.value - 0x61 + 10)
        default: return nil
        }
    }

    private static func hex(_ value: UInt16) -> String {
        String(format: "%04X", value)
    }

    private static func isPropertyWhitespace(_ scalar: UnicodeScalar) -> Bool {
        scalar.value == 0x20 || scalar.value == 0x09 || scalar.value == 0x0C
    }

    private static func isPropertyWhitespace(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\u{000C}"
    }
}

struct GModMenuLanguageSnapshot: Equatable, Sendable {
    let code: String
    let phrases: [String: String]

    func phrase(_ key: String) -> String {
        let lookup = key.hasPrefix("#") ? String(key.dropFirst()) : key
        return phrases[lookup] ?? key
    }

    func appText(_ key: GModAppLocalizedTextKey) -> String {
        phrase(key.rawValue)
    }
}

/// Source-backed keys for SwiftUI chrome and loading stages. These are keys
/// present in GMod's own properties catalogs, not translated fallback strings.
/// A missing pack entry remains visibly identifiable by its key.
enum GModAppLocalizedTextKey: String, CaseIterable, Sendable {
    case pauseButton = "garryspad.control.pause"
    case jumpButton = "garryspad.control.jump"
    case fireButton = "garryspad.control.fire"
    case alternateFireButton = "garryspad.control.alt-fire"
    case useButton = "garryspad.control.use"
    case reloadButton = "garryspad.control.reload"
    case dropWeaponButton = "garryspad.control.drop-weapon"
    case spawnMenuButton = "garryspad.control.spawn-menu"
    case closeSpawnMenuButton = "garryspad.control.close-spawn-menu"
    case contextMenuButton = "garryspad.control.context-menu"
    case closeContextMenuButton = "garryspad.control.close-context-menu"
    case quitUnavailableMessage = "garryspad.ios.quit-unavailable"
    case okayButton = "garryspad.control.ok"
    case pauseMenu = "options"
    case resumeGame = "resume_game"
    case backToGame = "back_to_game"
    case spawnMenu = "spawnmenu"
    case loading = "loading"
    case mountingContent = "ugc.mounting"
    case indexingModels = "spawnmenu.searchindex"
    case startingGame = "start_game"
    case ready = "ready"
    case loadingFailed = "garryspad.loading.failed"
    case returnHomeAfterFailure = "garryspad.loading.return-home"
}

struct GModMenuLocalizationCatalog: Equatable, Sendable {
    static let supportedLanguageCodes = ["en", "ja"]

    let phrasesByLanguage: [String: [String: String]]

    var availableLanguageCodes: [String] {
        Self.supportedLanguageCodes.filter {
            !(phrasesByLanguage[$0] ?? [:]).isEmpty
        }
    }

    func contains(languageCode: String) -> Bool {
        availableLanguageCodes.contains(Self.normalizedCode(languageCode))
    }

    func snapshot(languageCode: String) -> GModMenuLanguageSnapshot {
        let normalized = Self.normalizedCode(languageCode)
        var phrases = phrasesByLanguage["en"] ?? [:]
        if normalized != "en" {
            phrases.merge(phrasesByLanguage[normalized] ?? [:]) { _, selected in
                selected
            }
        }
        return GModMenuLanguageSnapshot(code: normalized, phrases: phrases)
    }

    static func load(
        from pack: GarrysPADContentPack,
        appPhrasesByLanguage: [String: [String: String]] = [:],
        diagnostic: (String) -> Void = { _ in }
    ) -> GModMenuLocalizationCatalog {
        var catalogs: [String: [String: String]] = [:]
        for languageCode in supportedLanguageCodes {
            let prefix = "garrysmod/resource/localization/\(languageCode)/"
            let paths = pack.entries.values
                .filter {
                    $0.path.lowercased().hasPrefix(prefix)
                        && $0.path.lowercased().hasSuffix(".properties")
                }
                .sorted { $0.path < $1.path }

            var phrases = appPhrasesByLanguage[languageCode] ?? [:]
            var loadedPackPhrases = false
            for entry in paths {
                guard entry.compressionMethod == 0 else {
                    diagnostic(
                        "localization entry is not stored and cannot be read in place: "
                            + entry.path
                    )
                    continue
                }
                do {
                    let data = try pack.data(
                        for: entry.path,
                        maximumByteCount: 8 * 1_024 * 1_024
                    )
                    let parsed = try GModJavaPropertiesParser.parse(data: data)
                    if !parsed.isEmpty { loadedPackPhrases = true }
                    phrases.merge(parsed) { _, laterFile in laterFile }
                } catch {
                    diagnostic("localization parse failed for \(entry.path): \(error)")
                }
            }
            if !phrases.isEmpty {
                catalogs[languageCode] = phrases
            }
            if !loadedPackPhrases {
                diagnostic("no readable \(languageCode) localization properties in content pack")
            }
        }
        return GModMenuLocalizationCatalog(phrasesByLanguage: catalogs)
    }

    static func normalizedCode(_ rawCode: String) -> String {
        rawCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-", maxSplits: 1)
            .first
            .map(String.init)?
            .lowercased() ?? ""
    }
}

final class GModMenuLanguagePreferenceStore {
    static let key = "GarrysPAD.Menu.Language.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func resolvedLanguageCode(
        availableLanguageCodes: [String],
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        let available = availableLanguageCodes.map(
            GModMenuLocalizationCatalog.normalizedCode
        )
        if let stored = defaults.string(forKey: Self.key).map(
            GModMenuLocalizationCatalog.normalizedCode
        ), available.contains(stored) {
            return stored
        }
        for preferred in preferredLanguages {
            let code = GModMenuLocalizationCatalog.normalizedCode(preferred)
            if available.contains(code) { return code }
        }
        if available.contains("en") { return "en" }
        return available.first ?? "en"
    }

    @discardableResult
    func persist(
        languageCode: String,
        availableLanguageCodes: [String]
    ) -> Bool {
        let code = GModMenuLocalizationCatalog.normalizedCode(languageCode)
        let available = availableLanguageCodes.map(
            GModMenuLocalizationCatalog.normalizedCode
        )
        guard available.contains(code) else { return false }
        defaults.set(code, forKey: Self.key)
        return true
    }
}

enum GModMenuWebContract {
    static let viewportContent =
        "width=device-width, initial-scale=1.0, minimum-scale=1.0, "
        + "maximum-scale=1.0, user-scalable=no"

    static let zoomLockScript = """
    (function(){
      const gpViewportContent='\(viewportContent)';
      function forceViewport(){
        const all=Array.prototype.slice.call(
          document.querySelectorAll('meta[name="viewport" i]')
        );
        let viewport=all.shift();
        if(!viewport && document.head){
          viewport=document.createElement('meta');
          viewport.setAttribute('name','viewport');
          document.head.appendChild(viewport);
        }
        if(viewport && viewport.getAttribute('content')!==gpViewportContent){
          viewport.setAttribute('content',gpViewportContent);
        }
        all.forEach(function(extra){extra.remove();});
        if(document.head && !document.getElementById('garrys-pad-zoom-lock')){
          const style=document.createElement('style');
          style.id='garrys-pad-zoom-lock';
          style.textContent='html,body{touch-action:pan-x pan-y!important;}';
          document.head.appendChild(style);
        }
      }
      forceViewport();
      document.addEventListener('DOMContentLoaded',forceViewport,{once:true});
      const root=document.documentElement||document;
      new MutationObserver(forceViewport).observe(root,{
        childList:true,subtree:true,attributes:true,
        attributeFilter:['content','name']
      });
      document.addEventListener('dblclick',function(event){
        event.preventDefault();
      },{capture:true,passive:false});
      ['gesturestart','gesturechange','gestureend'].forEach(function(name){
        document.addEventListener(name,function(event){event.preventDefault();},
          {capture:true,passive:false});
      });
    })();
    """

    static func languageFacadeScript(
        snapshot: GModMenuLanguageSnapshot,
        availableLanguageCodes: [String]
    ) -> String {
        let payload = localizationJSON(
            snapshot: snapshot,
            availableLanguageCodes: availableLanguageCodes
        )
        return """
        (function(){
          window.__garrysPadApplyLocalization=function(next){
            window.__garrysPadLocalization=next||{code:'',languages:[],phrases:{}};
            if(typeof window.UpdateLanguages==='function'){
              window.UpdateLanguages(window.__garrysPadLocalization.languages);
            }
            if(typeof window.UpdateLanguage==='function'){
              window.UpdateLanguage(window.__garrysPadLocalization.code);
            }
            document.querySelectorAll('[data-garryspad-phrase]').forEach(function(node){
              node.textContent=window.language.Update(
                node.getAttribute('data-garryspad-phrase')||''
              );
            });
          };
          window.language=window.language||{};
          window.language.Update=function(key,callback){
            const original=key==null?'':String(key);
            const lookup=original.charAt(0)==='#'?original.substring(1):original;
            const phrases=(window.__garrysPadLocalization||{}).phrases||{};
            const value=Object.prototype.hasOwnProperty.call(phrases,lookup)
              ?phrases[lookup]:original;
            if(typeof callback==='function') callback(value);
            return value;
          };
          window.__garrysPadApplyLocalization(\(payload));
        })();
        """
    }

    static func applyLanguageScript(
        snapshot: GModMenuLanguageSnapshot,
        availableLanguageCodes: [String]
    ) -> String {
        let payload = localizationJSON(
            snapshot: snapshot,
            availableLanguageCodes: availableLanguageCodes
        )
        return """
        if(typeof window.__garrysPadApplyLocalization==='function'){
          window.__garrysPadApplyLocalization(\(payload));
        }
        """
    }

    /// Mirrors the stock MainMenuPanel:SetProblemCount bridge. The payload is
    /// retained even before control.Menu.js finishes loading so its async
    /// configure path can apply the latest source-backed status exactly once
    /// the official function exists.
    static func problemStatusScript(count: Int, severity: Int) -> String {
        let boundedCount = Swift.max(0, count)
        let boundedSeverity = Swift.max(0, Swift.min(2, severity))
        return """
        window.__garrysPadProblemStatus={count:\(boundedCount),severity:\(boundedSeverity)};
        if(typeof window.SetProblemCount==='function'){
          window.SetProblemCount(
            window.__garrysPadProblemStatus.count,
            window.__garrysPadProblemStatus.severity
          );
        }
        """
    }

    private static func localizationJSON(
        snapshot: GModMenuLanguageSnapshot,
        availableLanguageCodes: [String]
    ) -> String {
        let object: [String: Any] = [
            "code": snapshot.code,
            "languages": availableLanguageCodes.map { "\($0).png" },
            "phrases": snapshot.phrases,
        ]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
              ),
              let result = String(data: data, encoding: .utf8) else {
            return "{\"code\":\"\",\"languages\":[],\"phrases\":{}}"
        }
        return result
    }
}
