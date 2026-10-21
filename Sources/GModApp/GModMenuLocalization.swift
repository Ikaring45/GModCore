import Foundation
import GModGameAssets
import GModGameSession

typealias GModJavaPropertiesParser = GModGameSession.GModJavaPropertiesParser
typealias GModJavaPropertiesParserError = GModGameSession.GModJavaPropertiesParserError

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
    case duckButton = "garryspad.control.duck"
    case speedButton = "garryspad.control.speed"
    case previousWeaponButton = "garryspad.control.previous-weapon"
    case nextWeaponButton = "garryspad.control.next-weapon"
    case dropWeaponButton = "garryspad.control.drop-weapon"
    case undoButton = "garryspad.control.undo"
    case noClipButton = "garryspad.control.noclip"
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
        let source: GModContentPackAssetSource?
        do { source = try GModContentPackAssetSource(pack: pack) }
        catch {
            diagnostic("Source localization mount failed: \(error)")
            source = nil
        }
        for languageCode in supportedLanguageCodes {
            var phrases = appPhrasesByLanguage[languageCode] ?? [:]
            var loadedPackPhrases: [String: String] = [:]
            if let source {
                loadedPackPhrases = GModSourceLocalizationTokens.load(
                    languageCode: languageCode, source: source, diagnostic: diagnostic
                )
                phrases.merge(loadedPackPhrases) { _, mounted in mounted }
            }
            if !phrases.isEmpty {
                catalogs[languageCode] = phrases
            }
            if loadedPackPhrases.isEmpty {
                diagnostic("no readable \(languageCode) localization catalogs in content pack")
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
