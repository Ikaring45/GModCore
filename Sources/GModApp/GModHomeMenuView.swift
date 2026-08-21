import Foundation
import SwiftUI
import UIKit
import WebKit
import GModGameAssets
import GModGameSession

/// Hosts the original GMod main-menu HTML over a native background layer.
///
/// Stock GMod does not paint its photographic menu background inside menu.html.
/// `mainmenu.lua` paints the background first and places a transparent DHTML
/// panel over it. Garry's PAD mirrors that split: UIKit owns the background,
/// while WKWebView runs the original menu HTML/CSS/Angular application.
struct GModHomeMenuView: UIViewRepresentable {
    private static let scheme = "garryspad"
    private static let menuPath = "garrysmod/html/menu.html"
    private static let stockMenuURL = "asset://garrysmod/html/menu.html"

    let pack: GarrysPADContentPack
    let assetSource: GModContentPackAssetSource?
    let backgroundJPEG: Data
    let logoPNG: Data?
    let onSelectMap: (GModBundledMap) -> Void
    let isInGame: Bool
    let preferredLanguageCode: String?
    let menuBackgroundsEnabled: Bool
    let problemCount: Int
    let problemSeverity: Int
    let onMenuAction: ((GModHomeMenuAction) -> Void)?
    let onLanguageChange: ((GModMenuLanguageSnapshot) -> Void)?
    let onDiagnostic: ((GModAppProblemRecord) -> Void)?
    let audioController: GModMenuAudioController

    init(
        pack: GarrysPADContentPack,
        assetSource: GModContentPackAssetSource?,
        backgroundJPEG: Data,
        logoPNG: Data?,
        onSelectMap: @escaping (GModBundledMap) -> Void,
        isInGame: Bool = false,
        preferredLanguageCode: String? = nil,
        menuBackgroundsEnabled: Bool = true,
        problemCount: Int = 0,
        problemSeverity: Int = 0,
        onMenuAction: ((GModHomeMenuAction) -> Void)? = nil,
        onLanguageChange: ((GModMenuLanguageSnapshot) -> Void)? = nil,
        onDiagnostic: ((GModAppProblemRecord) -> Void)? = nil,
        audioController: GModMenuAudioController
    ) {
        self.pack = pack
        self.assetSource = assetSource
        self.backgroundJPEG = backgroundJPEG
        self.logoPNG = logoPNG
        self.onSelectMap = onSelectMap
        self.isInGame = isInGame
        self.preferredLanguageCode = preferredLanguageCode
        self.menuBackgroundsEnabled = menuBackgroundsEnabled
        self.problemCount = problemCount
        self.problemSeverity = problemSeverity
        self.onMenuAction = onMenuAction
        self.onLanguageChange = onLanguageChange
        self.onDiagnostic = onDiagnostic
        self.audioController = audioController
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            pack: pack,
            assetSource: assetSource,
            fallbackBackgroundJPEG: backgroundJPEG,
            onSelectMap: onSelectMap,
            isInGame: isInGame,
            menuBackgroundsEnabled: menuBackgroundsEnabled,
            problemCount: problemCount,
            problemSeverity: problemSeverity,
            onMenuAction: onMenuAction,
            onLanguageChange: onLanguageChange,
            onDiagnostic: onDiagnostic,
            audioController: audioController
        )
    }

    func makeUIView(context: Context) -> UIView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            context.coordinator.contentHandler,
            forURLScheme: Self.scheme
        )
        configuration.setURLSchemeHandler(
            context.coordinator.contentHandler,
            forURLScheme: "asset"
        )
        configuration.userContentController.add(
            context.coordinator,
            name: Coordinator.messageName
        )
        configuration.userContentController.addUserScript(WKUserScript(
            source: GModMenuWebContract.zoomLockScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        configuration.userContentController.addUserScript(WKUserScript(
            source: context.coordinator.engineFacadeScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        configuration.userContentController.addUserScript(WKUserScript(
            source: GModMenuWebContract.htmlAudioBridgeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        configuration.userContentController.addUserScript(WKUserScript(
            source: context.coordinator.criticalImageFallbackScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.menuBridgeScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        configuration.allowsInlineMediaPlayback = true

        let webView = GModZoomLockedWebView(
            frame: .zero,
            configuration: configuration
        )
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.bounces = false
        webView.scrollView.delaysContentTouches = false
        webView.scrollView.canCancelContentTouches = true
        webView.allowsLinkPreview = false
        webView.customUserAgent = "Valve Source Client GarrysPAD/iPad"
        webView.accessibilityIdentifier = "garryspad.home.web"

        let container = GModHomeMenuContainerView(webView: webView)
        context.coordinator.webView = webView
        context.coordinator.publishLanguageSnapshot()
        context.coordinator.installBackground(into: container)

        if let entry = try? pack.entry(for: Self.menuPath),
           entry.compressionMethod == 0,
           let url = URL(string: Self.stockMenuURL) {
            // GMod itself opens exactly asset://garrysmod/html/menu.html.
            // Using the same base is important: Angular explicitly trusts the
            // asset: scheme and many templates use ../gamemodes, ../materials,
            // img/, template/, and asset://mapimage relative paths.
            webView.load(URLRequest(url: url))
        } else {
            // Keep transfer-sized/older packs usable, but do not pretend this
            // is the stock menu when menu.html cannot be random-accessed.
            webView.loadHTMLString(fallbackHTML, baseURL: nil)
        }
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onSelectMap = onSelectMap
        context.coordinator.updateIsInGame(isInGame, in: context.coordinator.webView)
        context.coordinator.updatePreferredLanguage(
            preferredLanguageCode,
            in: context.coordinator.webView
        )
        context.coordinator.updateBackgroundEnabled(menuBackgroundsEnabled)
        context.coordinator.updateProblemStatus(
            count: problemCount,
            severity: problemSeverity,
            in: context.coordinator.webView
        )
        context.coordinator.onMenuAction = onMenuAction
        context.coordinator.onLanguageChange = onLanguageChange
        context.coordinator.onDiagnostic = onDiagnostic
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stopBackgroundAnimation()
        coordinator.stopAudio()
        if let webView = coordinator.webView {
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: Coordinator.messageName
            )
            webView.stopLoading()
            webView.navigationDelegate = nil
        }
        coordinator.webView = nil
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        static let messageName = "garrysPAD"

        fileprivate let contentHandler: ContentSchemeHandler
        weak var webView: WKWebView?
        var onSelectMap: (GModBundledMap) -> Void
        private var isInGame: Bool
        private var menuBackgroundsEnabled: Bool
        private var problemCount: Int
        private var problemSeverity: Int
        var onMenuAction: ((GModHomeMenuAction) -> Void)?
        var onLanguageChange: ((GModMenuLanguageSnapshot) -> Void)?
        var onDiagnostic: ((GModAppProblemRecord) -> Void)?

        private let pack: GarrysPADContentPack
        private let fallbackBackgroundJPEG: Data
        private let languageCatalog: GModMenuLocalizationCatalog
        private let languagePreferenceStore: GModMenuLanguagePreferenceStore
        private var languageSnapshot: GModMenuLanguageSnapshot
        private let audioController: GModMenuAudioController
        private weak var backgroundContainer: GModHomeMenuContainerView?

        init(
            pack: GarrysPADContentPack,
            assetSource: GModContentPackAssetSource?,
            fallbackBackgroundJPEG: Data,
            onSelectMap: @escaping (GModBundledMap) -> Void,
            isInGame: Bool,
            menuBackgroundsEnabled: Bool,
            problemCount: Int,
            problemSeverity: Int,
            onMenuAction: ((GModHomeMenuAction) -> Void)?,
            onLanguageChange: ((GModMenuLanguageSnapshot) -> Void)?,
            onDiagnostic: ((GModAppProblemRecord) -> Void)?,
            audioController: GModMenuAudioController
        ) {
            self.pack = pack
            self.fallbackBackgroundJPEG = fallbackBackgroundJPEG
            contentHandler = ContentSchemeHandler(
                pack: pack,
                assetSource: assetSource
            )
            self.onSelectMap = onSelectMap
            self.isInGame = isInGame
            self.menuBackgroundsEnabled = menuBackgroundsEnabled
            self.problemCount = max(0, problemCount)
            self.problemSeverity = max(0, min(2, problemSeverity))
            self.onMenuAction = onMenuAction
            self.onLanguageChange = onLanguageChange
            self.onDiagnostic = onDiagnostic
            self.audioController = audioController
            let appPhrases = GModBundledAppLocalization.load {
                print("[Garry's PAD][Menu][language] \($0)")
            }
            let catalog = GModMenuLocalizationCatalog.load(
                from: pack,
                appPhrasesByLanguage: appPhrases
            ) {
                print("[Garry's PAD][Menu][language] \($0)")
            }
            languageCatalog = catalog
            let preferenceStore = GModMenuLanguagePreferenceStore()
            languagePreferenceStore = preferenceStore
            let code = preferenceStore.resolvedLanguageCode(
                availableLanguageCodes: catalog.availableLanguageCodes
            )
            languageSnapshot = catalog.snapshot(languageCode: code)
            super.init()
        }

        func engineFacadeScript() -> String {
            GModMenuWebContract.languageFacadeScript(
                snapshot: languageSnapshot,
                availableLanguageCodes: languageCatalog.availableLanguageCodes
            ) + GModMenuWebContract.problemStatusScript(
                count: problemCount,
                severity: problemSeverity
            ) + """

            window.__garrysPadIsInGame=\(isInGame ? "true" : "false");
            window.util={MotionSensorAvailable:function(cb){
              if(typeof cb==='function')cb(false);return false;
            }};
            """
        }

        func updateIsInGame(_ replacement: Bool, in webView: WKWebView?) {
            guard replacement != isInGame else { return }
            isInGame = replacement
            webView?.evaluateJavaScript("""
            window.__garrysPadIsInGame=\(replacement ? "true" : "false");
            if(typeof SetInGame==='function') SetInGame(window.__garrysPadIsInGame);
            """)
        }

        func updatePreferredLanguage(_ rawCode: String?, in webView: WKWebView?) {
            guard let rawCode else { return }
            let code = GModMenuLocalizationCatalog.normalizedCode(rawCode)
            guard code != languageSnapshot.code,
                  languageCatalog.contains(languageCode: code) else {
                return
            }
            selectLanguage(code, in: webView)
        }

        func updateBackgroundEnabled(_ enabled: Bool) {
            guard enabled != menuBackgroundsEnabled else { return }
            menuBackgroundsEnabled = enabled
            let data = enabled ? preferredBackgroundData() : nil
            backgroundContainer?.setBackgroundImage(data.flatMap(UIImage.init(data:)))
        }

        func updateProblemStatus(
            count replacementCount: Int,
            severity replacementSeverity: Int,
            in webView: WKWebView?
        ) {
            let count = max(0, replacementCount)
            let severity = max(0, min(2, replacementSeverity))
            guard count != problemCount || severity != problemSeverity else { return }
            problemCount = count
            problemSeverity = severity
            webView?.evaluateJavaScript(GModMenuWebContract.problemStatusScript(
                count: count,
                severity: severity
            ))
        }

        func publishLanguageSnapshot() {
            GModMenuLocalizationSelectionStore.shared.publish(
                languageSnapshot,
                availableLanguageCodes: languageCatalog.availableLanguageCodes
            )
            onLanguageChange?(languageSnapshot)
        }

        func stopAudio() {
            audioController.stop(bus: .menu)
        }

        fileprivate func installBackground(into container: GModHomeMenuContainerView) {
            backgroundContainer = container
            let data = menuBackgroundsEnabled ? preferredBackgroundData() : nil
            container.setBackgroundImage(data.flatMap(UIImage.init(data:)))
        }

        func stopBackgroundAnimation() {
            backgroundContainer?.stopBackgroundAnimation()
        }

        /// GMod's mainmenu.lua searches the active gamemode's backgrounds first,
        /// then the default garrysmod/backgrounds folder. Playable/CompleteBase
        /// packs expose those loose files directly, so keep the same priority.
        ///
        /// The small Playground profile historically contained only html/ and
        /// maps; in that case use bg_dark.jpg rather than the pale bg.jpg tile.
        private func preferredBackgroundData() -> Data? {
            let sandboxPrefix = "garrysmod/gamemodes/sandbox/backgrounds/"
            let defaultPrefix = "garrysmod/backgrounds/"

            func isImage(_ path: String) -> Bool {
                let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
                return ext == "jpg" || ext == "jpeg" || ext == "png"
            }

            let sandbox = pack.entries.keys
                .filter { $0.hasPrefix(sandboxPrefix) && isImage($0) }
                .sorted()
            let defaults = pack.entries.keys
                .filter { $0.hasPrefix(defaultPrefix) && isImage($0) }
                .sorted()
            let candidates = sandbox.isEmpty ? defaults : sandbox

            if !candidates.isEmpty {
                // Rotate the first choice between launches while retaining a
                // deterministic fallback order if one image is malformed.
                let seed = Int(Date().timeIntervalSince1970 / 30)
                let start = seed % candidates.count
                for offset in 0..<candidates.count {
                    let path = candidates[(start + offset) % candidates.count]
                    guard let entry = try? pack.entry(for: path),
                          entry.compressionMethod == 0,
                          let data = try? pack.data(
                            for: path,
                            maximumByteCount: 32 * 1_024 * 1_024
                          ),
                          UIImage(data: data) != nil else {
                        continue
                    }
                    return data
                }
            }

            if let dark = try? contentHandler.data(
                forLogicalPath: "html/img/bg_dark.jpg",
                maximumByteCount: 8 * 1_024 * 1_024
            ), UIImage(data: dark) != nil {
                return dark
            }
            return fallbackBackgroundJPEG
        }

        /// The stock asset:// routing should resolve these normally. These data
        /// URLs are only an error fallback so a single scheme/path regression
        /// cannot blank the primary navigation icons.
        func criticalImageFallbackScript() -> String {
            let criticalPaths = [
                "html/img/back_to_main_menu.png",
                "html/img/back_to_game.png",
                "html/img/addons.png",
                "html/img/games.png",
                "html/img/settings.png",
                "html/img/workshop.png",
                "html/img/whatsnew.png",
                "html/img/disconnect.png",
                "html/img/downloading.png",
                "html/img/gmod_logo_brave.png",
                "gamemodes/sandbox/logo.png",
            ]

            var fallbacks: [String: String] = [:]
            for path in criticalPaths {
                guard let data = try? contentHandler.data(
                    forLogicalPath: path,
                    maximumByteCount: 2 * 1_024 * 1_024
                ) else {
                    continue
                }
                let mime = ContentSchemeHandler.mimeType(path)
                fallbacks[path.lowercased()] =
                    "data:\(mime);base64,\(data.base64EncodedString())"
            }

            guard JSONSerialization.isValidJSONObject(fallbacks),
                  let encoded = try? JSONSerialization.data(withJSONObject: fallbacks),
                  let json = String(data: encoded, encoding: .utf8) else {
                return ""
            }

            return """
            (function(){
              const gpFallbacks=\(json);
              function normalizedPath(src){
                try {
                  const u=new URL(src,document.baseURI);
                  let p=(u.pathname||'').replace(/^\\/+/, '').toLowerCase();
                  if(u.protocol==='asset:' && u.hostname==='garrysmod') return p;
                  if(p.indexOf('garrysmod/')===0) return p.substring('garrysmod/'.length);
                  return p;
                } catch(_) { return String(src||'').replace(/^.*garrysmod\\//,'').toLowerCase(); }
              }
              function repair(img){
                if(!img || img.tagName!=='IMG' || img.dataset.garrysPadFallback==='1') return;
                const key=normalizedPath(img.getAttribute('src')||img.src);
                let replacement=gpFallbacks[key];
                if(!replacement && key==='gamemodes/sandbox/logo.png'){
                  replacement=gpFallbacks['html/img/gmod_logo_brave.png'];
                }
                if(!replacement) return;
                img.dataset.garrysPadFallback='1';
                img.src=replacement;
              }
              document.addEventListener('error',function(e){
                if(e.target && e.target.tagName==='IMG') repair(e.target);
              },true);
              window.__garrysPadRepairImages=function(){
                document.querySelectorAll('img').forEach(function(img){
                  if(img.complete && img.naturalWidth===0) repair(img);
                });
              };
            })();
            """
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == Self.messageName,
                  let body = message.body as? [String: Any],
                  let action = body["action"] as? String else {
                return
            }

            if action == "startMap",
               let name = body["map"] as? String {
                handleMenuAction(.startMap(name), in: message.webView)
                return
            }

            if action == "sound",
               let name = body["name"] as? String {
                audioController.play(name, origin: .lua)
                return
            }

            if action == "htmlSound",
               let name = body["name"] as? String {
                let documentURL = (body["base"] as? String).flatMap(URL.init(string:))
                audioController.play(
                    name,
                    origin: .html,
                    documentURL: documentURL
                )
                return
            }

            if action == "diagnostic" {
                let level = body["level"] as? String ?? "info"
                let text = body["message"] as? String ?? ""
                print("[Garry's PAD][Menu][\(level)] \(text)")
                if level.lowercased() == "js" || level.lowercased() == "error" {
                    onDiagnostic?(GModAppProblemRecord(
                        id: "menu|\(level)|\(text)",
                        kind: .compatibility,
                        severity: .error,
                        title: "#garryspad.problem.menu",
                        detail: text,
                        source: "WKWebView"
                    ))
                }
                return
            }

            guard action == "lua",
                  let command = body["command"] as? String else {
                return
            }

            if let parsed = GModHomeMenuCommandParser.parse(command) {
                handleMenuAction(parsed, in: message.webView)
            } else if command.contains("UpdateServerSettings") {
                message.webView?.evaluateJavaScript(Self.serverSettingsScript)
            }
        }

        func webView(
            _ webView: WKWebView,
            didFinish navigation: WKNavigation!
        ) {
            // A real GMod main menu keeps the DHTML surface transparent because
            // background.lua paints behind it.
            webView.evaluateJavaScript("""
            document.documentElement.style.background='transparent';
            document.body.style.backgroundColor='transparent';
            if(window.__garrysPadRepairImages) window.__garrysPadRepairImages();
            """)
            webView.evaluateJavaScript(GModMenuWebContract.applyLanguageScript(
                snapshot: languageSnapshot,
                availableLanguageCodes: languageCatalog.availableLanguageCodes
            ))
            webView.evaluateJavaScript(GModMenuWebContract.problemStatusScript(
                count: problemCount,
                severity: problemSeverity
            ))
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            print("[Garry's PAD][Menu][navigation] \(error)")
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            print("[Garry's PAD][Menu][provisional] \(error)")
        }

        private func handleMenuAction(
            _ action: GModHomeMenuAction,
            in webView: WKWebView?
        ) {
            onMenuAction?(action)
            switch action {
            case let .startMap(name):
                guard let map = GModBundledMap(rawValue: name) else {
                    print("[Garry's PAD][Menu][command] unavailable bundled map: \(name)")
                    return
                }
                onSelectMap(map)
            case let .setLanguage(rawCode):
                selectLanguage(rawCode, in: webView)
            case .hideGameUI, .openOptions, .openProblems, .disconnect, .quit:
                guard onMenuAction != nil else {
                    print(
                        "[Garry's PAD][Menu][integration] parent callback required for \(action)"
                    )
                    return
                }
            }
        }

        private func selectLanguage(_ rawCode: String, in webView: WKWebView?) {
            let code = GModMenuLocalizationCatalog.normalizedCode(rawCode)
            guard languageCatalog.contains(languageCode: code) else {
                print(
                    "[Garry's PAD][Menu][language] rejected unavailable language: \(rawCode)"
                )
                return
            }
            guard languagePreferenceStore.persist(
                languageCode: code,
                availableLanguageCodes: languageCatalog.availableLanguageCodes
            ) else {
                print("[Garry's PAD][Menu][language] persistence rejected: \(code)")
                return
            }
            languageSnapshot = languageCatalog.snapshot(languageCode: code)
            publishLanguageSnapshot()
            webView?.evaluateJavaScript(GModMenuWebContract.applyLanguageScript(
                snapshot: languageSnapshot,
                availableLanguageCodes: languageCatalog.availableLanguageCodes
            ))
        }

        static let serverSettingsScript = """
        if (typeof UpdateServerSettings === 'function') {
          UpdateServerSettings({sv_lan:'1',p2p_enabled:'0',p2p_friendsonly:'0',
            maxplayers:'1',hostname:"Garry's PAD",settings:{}});
        }
        """
    }

    private static let menuBridgeScript = """
    (function(){
      function postDiagnostic(level,message){
        try{
          window.webkit.messageHandlers.garrysPAD.postMessage({
            action:'diagnostic',level:String(level),message:String(message)
          });
        }catch(_){}
      }

      window.addEventListener('error',function(e){
        if(!e) return;
        postDiagnostic('js',e.message||'JavaScript error');
      });

      function format(cmd,args){
        var out='',arg=1;
        for(var i=0;i<cmd.length;i++){
          if(cmd[i]==='%'&&i+1<cmd.length){
            i++;
            if(cmd[i]==='s'){
              var v=String(args[arg++]);
              out+='"'+v.replace(/["\\\\]/g,'\\\\$&')+'"';
              continue;
            }
            if(cmd[i]==='i'){
              out+=String(args[arg++]);
              continue;
            }
          }
          out+=cmd[i];
        }
        return out;
      }

      window.lua=window.lua||{};
      window.lua.Run=function(cmd){
        window.webkit.messageHandlers.garrysPAD.postMessage({
          action:'lua',command:format(String(cmd),arguments)
        });
      };
      window.lua.PlaySound=function(name){
        window.webkit.messageHandlers.garrysPAD.postMessage({
          action:'sound',name:String(name)
        });
      };

      // WKWebView normally synthesizes clicks from taps, but the stock menu was
      // authored for Awesomium/CEF mouse input. Explicitly promote a stationary
      // single-finger touch into one click/route transition. Dragging keeps its
      // normal scroll behavior.
      var touchStart=null;
      var touchMoved=false;
      function actionable(node){
        while(node && node!==document.documentElement){
          if(node.matches && node.matches(
            'a,button,[ng-click],[onclick],.button,.mapicon,.category'
          )) return node;
          node=node.parentElement;
        }
        return null;
      }

      document.addEventListener('touchstart',function(e){
        if(!e.touches || e.touches.length!==1){
          touchStart=null;
          return;
        }
        var t=e.touches[0];
        touchStart={x:t.clientX,y:t.clientY};
        touchMoved=false;
      },{capture:true,passive:true});

      document.addEventListener('touchmove',function(e){
        if(!touchStart || !e.touches || e.touches.length!==1) return;
        var t=e.touches[0],dx=t.clientX-touchStart.x,dy=t.clientY-touchStart.y;
        if((dx*dx+dy*dy)>196) touchMoved=true;
      },{capture:true,passive:true});

      document.addEventListener('touchcancel',function(){
        touchStart=null;
        touchMoved=false;
      },{capture:true,passive:true});

      document.addEventListener('touchend',function(e){
        if(!touchStart || touchMoved || !e.changedTouches || !e.changedTouches.length){
          touchStart=null;
          touchMoved=false;
          return;
        }

        var t=e.changedTouches[0];
        var node=document.elementFromPoint(t.clientX,t.clientY);
        var target=actionable(node);
        touchStart=null;
        touchMoved=false;
        if(!target) return;

        var tag=(target.tagName||'').toUpperCase();
        if(tag==='INPUT'||tag==='TEXTAREA'||tag==='SELECT'){
          return;
        }

        // Suppress WebKit's delayed synthetic click so Angular handlers are not
        // executed twice.
        e.preventDefault();

        var href=target.getAttribute &&
          (target.getAttribute('href')||target.getAttribute('ng-href'));
        if(href && href.charAt(0)==='#'){
          window.location.hash=href.substring(1);
        }

        target.dispatchEvent(new MouseEvent('click',{
          bubbles:true,
          cancelable:true,
          view:window,
          clientX:t.clientX,
          clientY:t.clientY
        }));
      },{capture:true,passive:false});

      function configure(){
        if(typeof UpdateGamemodes!=='function'||!window.gScope){
          return setTimeout(configure,30);
        }
        UpdateGamemodes({'1':{menusystem:true,maps:'^gm_',name:'sandbox',title:'Sandbox'}});
        UpdateCurrentGamemode('sandbox');
        UpdateMaps({Sandbox:['gm_construct','gm_flatgrass']});
        var locale=window.__garrysPadLocalization||{code:'',languages:[]};
        UpdateLanguages(locale.languages||[]);
        UpdateLanguage(locale.code||'');
        if(typeof SetInGame==='function'){
          SetInGame(!!window.__garrysPadIsInGame);
        }
        UpdateVersion("Garry's PAD",'2026.08.20','unknown');
        var problemStatus=window.__garrysPadProblemStatus;
        if(problemStatus&&typeof SetProblemCount==='function'){
          SetProblemCount(problemStatus.count,problemStatus.severity);
        }
        \(Coordinator.serverSettingsScript)

        document.documentElement.style.background='transparent';
        document.body.style.backgroundColor='transparent';
        if(window.__garrysPadRepairImages) window.__garrysPadRepairImages();
      }
      configure();
    })();
    """

    private var fallbackHTML: String {
        let background = backgroundJPEG.base64EncodedString()
        let logo = logoPNG?.base64EncodedString()
        let logoMarkup = logo.map {
            "<img class='logo' src='data:image/png;base64,\($0)' alt=\"Garry's Mod\">"
        } ?? "<div class='wordmark'>garry's mod</div>"
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no"><style>
        *{box-sizing:border-box;-webkit-user-select:none}html,body{margin:0;width:100%;height:100%;overflow:hidden;font-family:Arial,sans-serif;color:white;background:#121416}
        body:before{content:"";position:fixed;inset:0;background:linear-gradient(90deg,rgba(6,9,12,.94),rgba(9,12,15,.3)),url(data:image/jpeg;base64,\(background)) center/cover}
        .page{position:relative;height:100%;padding:7vh 7vw;display:flex;flex-direction:column}.logo{width:min(430px,64vw)}.menu{margin-top:auto;margin-bottom:8vh;width:min(520px,82vw)}
        button{display:block;width:100%;border:0;text-align:left;color:#fff;background:rgba(28,34,39,.9);font-size:28px;font-weight:700;padding:18px 22px;margin:10px 0;border-left:5px solid #4b9ce2}.hidden{display:none}.title{font-size:36px}.map small{display:block;font-size:13px;color:#b9c4cc}
        </style></head><body><main class="page">\(logoMarkup)<section id="home" class="menu"><button data-garryspad-phrase="new_game" onclick="showWorlds()"></button></section><section id="worlds" class="menu hidden"><button class="map" onclick="start('gm_construct')">gm_construct</button><button class="map" onclick="start('gm_flatgrass')">gm_flatgrass</button></section></main><script>
        document.querySelectorAll('[data-garryspad-phrase]').forEach(function(node){node.textContent=window.language.Update(node.getAttribute('data-garryspad-phrase'))})
        function showWorlds(){home.className='menu hidden';worlds.className='menu'}
        function start(map){window.webkit.messageHandlers.garrysPAD.postMessage({action:'startMap',map:map})}
        </script></body></html>
        """
    }
}

/// WKWebView can install its double-tap recognizer after construction, so the
/// native lock is re-applied during layout as well as at attachment time. This
/// leaves single taps and the scroll view's pan gesture untouched.
private final class GModZoomLockedWebView: WKWebView {
    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        enforceZoomLock()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        enforceZoomLock()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        enforceZoomLock()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        enforceZoomLock()
    }

    private func enforceZoomLock() {
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 1
        if scrollView.zoomScale != 1 { scrollView.zoomScale = 1 }
        scrollView.pinchGestureRecognizer?.isEnabled = false
        disableDoubleTapRecognizers(in: scrollView)
    }

    private func disableDoubleTapRecognizers(in view: UIView) {
        for recognizer in view.gestureRecognizers ?? [] {
            guard let tap = recognizer as? UITapGestureRecognizer,
                  tap.numberOfTapsRequired > 1 else {
                continue
            }
            tap.isEnabled = false
        }
        for subview in view.subviews {
            disableDoubleTapRecognizers(in: subview)
        }
    }
}

/// Native layer behind the transparent stock menu HTML. GMod's background.lua
/// slowly zooms and rotates each background; this keeps the same visual cue
/// without asking the HTML application to own background rendering.
private final class GModHomeMenuContainerView: UIView {
    let backgroundImageView = UIImageView()
    let webView: WKWebView

    private let gradientLayer = CAGradientLayer()

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)

        backgroundColor = .black
        clipsToBounds = true

        backgroundImageView.translatesAutoresizingMaskIntoConstraints = false
        backgroundImageView.contentMode = .scaleAspectFill
        backgroundImageView.clipsToBounds = false
        addSubview(backgroundImageView)

        let gradientHost = UIView()
        gradientHost.translatesAutoresizingMaskIntoConstraints = false
        gradientHost.isUserInteractionEnabled = false
        addSubview(gradientHost)
        gradientHost.layer.addSublayer(gradientLayer)
        gradientLayer.colors = [
            UIColor.black.withAlphaComponent(0.74).cgColor,
            UIColor.black.withAlphaComponent(0.34).cgColor,
            UIColor.clear.cgColor,
        ]
        gradientLayer.locations = [0.0, 0.42, 1.0]
        gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)

        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)

        NSLayoutConstraint.activate([
            backgroundImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -24),
            backgroundImageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 24),
            backgroundImageView.topAnchor.constraint(equalTo: topAnchor, constant: -24),
            backgroundImageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 24),

            gradientHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            gradientHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            gradientHost.topAnchor.constraint(equalTo: topAnchor),
            gradientHost.bottomAnchor.constraint(equalTo: bottomAnchor),

            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        gradientHost.tag = 9_451
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let gradientHost = viewWithTag(9_451) {
            gradientLayer.frame = gradientHost.bounds
        }
    }

    func setBackgroundImage(_ image: UIImage?) {
        backgroundImageView.image = image
        stopBackgroundAnimation()
        guard image != nil else { return }

        backgroundImageView.transform = .identity
        UIView.animate(
            withDuration: 30,
            delay: 0,
            options: [.curveLinear, .allowUserInteraction, .autoreverse, .repeat]
        ) {
            self.backgroundImageView.transform =
                CGAffineTransform(scaleX: 1.12, y: 1.12)
                .rotated(by: -5 * .pi / 180)
        }
    }

    func stopBackgroundAnimation() {
        backgroundImageView.layer.removeAllAnimations()
        backgroundImageView.transform = .identity
    }
}

/// The stock GMod loading document from the user-supplied content pack. The
/// host only supplies the same GameDetails/SetStatusChanged values Source
/// normally injects and rewrites the engine-only mapimage URL to this pack's
/// VPK-backed scheme.
struct GModStockLoadingView: UIViewRepresentable {
    private static let scheme = "garryspadloading"
    private static let loadingPath = "garrysmod/html/loading.html"

    let pack: GarrysPADContentPack
    let assetSource: GModContentPackAssetSource?
    let map: GModBundledMap
    let languageCode: String
    let gameModeTitle: String
    let status: String
    let task: String
    let progress: GModPlayableSessionLoadingProgress

    func makeCoordinator() -> Coordinator {
        Coordinator(
            pack: pack,
            assetSource: assetSource,
            map: map,
            languageCode: languageCode,
            gameModeTitle: gameModeTitle,
            status: status,
            task: task,
            progress: progress
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            context.coordinator.contentHandler,
            forURLScheme: Self.scheme
        )
        configuration.setURLSchemeHandler(
            context.coordinator.contentHandler,
            forURLScheme: "asset"
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = true
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.bounces = false
        webView.customUserAgent =
            "Valve Source Client GarrysPAD/iPad Chrome/120.0"
        webView.accessibilityIdentifier = "garryspad.loading.web"
        if let entry = try? pack.entry(for: Self.loadingPath),
           entry.compressionMethod == 0,
           let url = URL(string: "\(Self.scheme)://content/\(Self.loadingPath)") {
            webView.load(URLRequest(url: url))
        } else {
            webView.loadHTMLString(
                """
                <html><body style="margin:0;background:#111;color:#fff;
                font-family:Helvetica,Arial,sans-serif;overflow:hidden">
                <div style="position:fixed;left:28px;top:24px">
                <strong style="font-size:26px">Garry's PAD</strong><br>
                <span style="font-size:15px">\(map.rawValue)</span><br>
                <span id="garryspad-gamemode" style="font-size:13px;opacity:.72">
                </span></div>
                <div style="position:fixed;inset:0;display:grid;place-items:center;
                font-size:88px;font-weight:bold;text-shadow:0 2px 18px #000">g</div>
                </body></html>
                """,
                baseURL: nil
            )
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(
            map: map,
            languageCode: languageCode,
            gameModeTitle: gameModeTitle,
            status: status,
            task: task,
            progress: progress,
            in: webView
        )
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        fileprivate let contentHandler: ContentSchemeHandler
        private var map: GModBundledMap
        private var languageCode: String
        private var gameModeTitle: String
        private var status: String
        private var task: String
        private var progress: GModPlayableSessionLoadingProgress

        init(
            pack: GarrysPADContentPack,
            assetSource: GModContentPackAssetSource?,
            map: GModBundledMap,
            languageCode: String,
            gameModeTitle: String,
            status: String,
            task: String,
            progress: GModPlayableSessionLoadingProgress
        ) {
            let source = assetSource
            contentHandler = ContentSchemeHandler(pack: pack, assetSource: source)
            self.map = map
            self.languageCode = languageCode
            self.gameModeTitle = gameModeTitle
            self.status = status
            self.task = task
            self.progress = progress
        }

        func update(
            map: GModBundledMap,
            languageCode: String,
            gameModeTitle: String,
            status: String,
            task: String,
            progress: GModPlayableSessionLoadingProgress,
            in webView: WKWebView
        ) {
            self.map = map
            self.languageCode = languageCode
            self.gameModeTitle = gameModeTitle
            self.status = status
            self.task = task
            self.progress = progress
            webView.evaluateJavaScript(Self.script(
                map: map,
                languageCode: languageCode,
                gameModeTitle: gameModeTitle,
                status: status,
                task: task,
                progress: progress
            ))
        }

        func webView(
            _ webView: WKWebView,
            didFinish navigation: WKNavigation!
        ) {
            webView.evaluateJavaScript(Self.script(
                map: map,
                languageCode: languageCode,
                gameModeTitle: gameModeTitle,
                status: status,
                task: task,
                progress: progress
            ))
        }

        private static func script(
            map: GModBundledMap,
            languageCode: String,
            gameModeTitle: String,
            status: String,
            task: String,
            progress: GModPlayableSessionLoadingProgress
        ) -> String {
            let mapName = quoted(map.rawValue)
            let language = quoted(languageCode)
            let gameMode = quoted(gameModeTitle)
            let statusText = quoted(status)
            let taskText = quoted(task)
            let percent = Swift.max(0, Swift.min(100, progress.percentComplete))
            let imageURL = quoted(
                "\(GModStockLoadingView.scheme)://content/maps/thumb/" +
                    "\(map.rawValue).png"
            )
            return """
            (function(){
              var map=\(mapName), image=\(imageURL), status=\(statusText),
                  task=\(taskText), language=\(language), gameMode=\(gameMode),
                  percent=\(percent);
              if(typeof GameDetails==='function'){
                GameDetails(
                  "Garry's PAD","",map,1,"","sandbox",1,language,gameMode
                );
              }
              var gameModeNode=document.getElementById('garryspad-gamemode');
              if(gameModeNode) gameModeNode.textContent=gameMode;
              var mapImage=document.querySelector('#mapimg');
              if(mapImage) mapImage.setAttribute('src',image);
              document.body.style.backgroundImage="url('"+image+"')";
              if(typeof SetStatusChanged==='function') SetStatusChanged(status);
              var statusBox=document.querySelector('#spambox');
              if(statusBox){statusBox.textContent=status;statusBox.style.cssText=
                'position:fixed;right:24px;bottom:82px;padding:6px 10px;'+
                'background:rgba(0,0,0,.55);color:white;font:13px monospace;';}
              var box=document.getElementById('garryspad-real-progress');
              if(!box){
                box=document.createElement('div');
                box.id='garryspad-real-progress';
                box.style.cssText='position:fixed;right:24px;bottom:20px;width:'+
                  'min(420px,calc(100vw - 48px));padding:10px 12px;box-sizing:'+
                  'border-box;background:rgba(0,0,0,.68);color:white;font:'+
                  '13px monospace;z-index:2147483647';
                box.innerHTML='<div style="display:flex;gap:18px">'+
                  '<span id="garryspad-progress-task" style="flex:1"></span>'+
                  '<span id="garryspad-progress-percent"></span></div>'+
                  '<div style="height:7px;margin-top:7px;background:'+
                  'rgba(255,255,255,.22);overflow:hidden">'+
                  '<div id="garryspad-progress-fill" style="height:100%;'+
                  'background:#fff;width:0"></div></div>';
                document.body.appendChild(box);
              }
              var taskNode=document.getElementById('garryspad-progress-task');
              var percentNode=document.getElementById('garryspad-progress-percent');
              var fill=document.getElementById('garryspad-progress-fill');
              if(taskNode) taskNode.textContent=task;
              if(percentNode) percentNode.textContent=percent+'%';
              if(fill) fill.style.width=percent+'%';
            })();
            """
        }

        private static func quoted(_ value: String) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: [value]),
                  let array = String(data: data, encoding: .utf8),
                  array.count >= 2 else { return "\"\"" }
            return String(array.dropFirst().dropLast())
        }
    }
}

private final class ContentSchemeHandler: NSObject, WKURLSchemeHandler {
    private let pack: GarrysPADContentPack
    private let assetSource: GModContentPackAssetSource?

    init(
        pack: GarrysPADContentPack,
        assetSource: GModContentPackAssetSource? = nil
    ) {
        self.pack = pack
        self.assetSource = assetSource
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let path = Self.logicalPath(for: url)
        do {
            guard let data = try data(
                forLogicalPath: path,
                maximumByteCount: 64 * 1_024 * 1_024
            ) else {
                throw URLError(.fileDoesNotExist)
            }
            task.didReceive(URLResponse(
                url: url,
                mimeType: Self.mimeType(path),
                expectedContentLength: data.count,
                textEncodingName: Self.isText(path) ? "utf-8" : nil
            ))
            task.didReceive(data)
            task.didFinish()
        } catch {
            task.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    /// Resolve the same logical namespaces the Source `asset://` bridge exposes:
    /// first the selected content pack, then nested VPKs, then the package's
    /// audited client-content fallback.
    func data(
        forLogicalPath logicalPath: String,
        maximumByteCount: UInt64
    ) throws -> Data? {
        let path = logicalPath
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty,
              !path.split(separator: "/").contains("..") else {
            return nil
        }

        var packCandidates = [path]
        if !path.hasPrefix("garrysmod/"),
           !path.hasPrefix("platform/"),
           !path.hasPrefix("sourceengine/") {
            packCandidates.append("garrysmod/\(path)")
        }

        for candidate in packCandidates where pack.contains(candidate) {
            let byteCount = try pack.byteCount(for: candidate) ?? 0
            guard byteCount <= maximumByteCount else {
                return nil
            }
            if let entry = try pack.entry(for: candidate),
               entry.compressionMethod == 0 {
                return try pack.data(
                    for: candidate,
                    maximumByteCount: maximumByteCount
                )
            }
        }

        if let assetSource,
           let resolved = try assetSource.data(
            for: path,
            maximumByteCount: maximumByteCount
           ) {
            return resolved
        }

        // The Swift package already carries an audited GMod client-content
        // subset. This covers gamemode logos and material PNGs omitted from the
        // transfer-sized Playground ZIP.
        if let bundled = try? GModGameAssets.clientContentData(for: path),
           UInt64(bundled.count) <= maximumByteCount {
            return bundled
        }

        // Visual fallbacks only. Do not report them as the requested asset.
        if path == "gamemodes/sandbox/logo.png" {
            return try data(
                forLogicalPath: "html/img/gmod_logo_brave.png",
                maximumByteCount: maximumByteCount
            )
        }
        if path.hasPrefix("maps/thumb/") {
            return try data(
                forLogicalPath: "html/img/downloading.png",
                maximumByteCount: maximumByteCount
            )
        }
        if path == "materials/icon16/cross.png" {
            return try data(
                forLogicalPath: "html/img/cross.png",
                maximumByteCount: maximumByteCount
            )
        }

        return nil
    }

    private static func logicalPath(for url: URL) -> String {
        let path = url.path.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        guard url.scheme?.lowercased() == "asset" else { return path }

        switch url.host?.lowercased() {
        case "mapimage":
            let mapName = path.isEmpty ? "invalid_map" : path
            return "maps/thumb/\(mapName).png"
        case "garrysmod":
            return path
        case let host?:
            return path.isEmpty ? host : "\(host)/\(path)"
        case nil:
            return path
        }
    }

    private static func isText(_ path: String) -> Bool {
        ["html", "css", "js", "txt", "json"].contains(
            URL(fileURLWithPath: path).pathExtension.lowercased()
        )
    }

    static func mimeType(_ path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "html": return "text/html"
        case "css": return "text/css"
        case "js": return "text/javascript"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        default: return "application/octet-stream"
        }
    }
}
