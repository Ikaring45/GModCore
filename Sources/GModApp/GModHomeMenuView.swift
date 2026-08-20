import AVFoundation
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

    func makeCoordinator() -> Coordinator {
        Coordinator(
            pack: pack,
            assetSource: assetSource,
            fallbackBackgroundJPEG: backgroundJPEG,
            onSelectMap: onSelectMap
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
            source: Self.engineFacadeScript,
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

        let webView = WKWebView(frame: .zero, configuration: configuration)
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
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stopBackgroundAnimation()
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

        private let pack: GarrysPADContentPack
        private let assetSource: GModContentPackAssetSource?
        private let fallbackBackgroundJPEG: Data
        private var soundPlayers: [String: AVAudioPlayer] = [:]
        private weak var backgroundContainer: GModHomeMenuContainerView?

        init(
            pack: GarrysPADContentPack,
            assetSource: GModContentPackAssetSource?,
            fallbackBackgroundJPEG: Data,
            onSelectMap: @escaping (GModBundledMap) -> Void
        ) {
            self.pack = pack
            self.assetSource = assetSource
            self.fallbackBackgroundJPEG = fallbackBackgroundJPEG
            contentHandler = ContentSchemeHandler(
                pack: pack,
                assetSource: assetSource
            )
            self.onSelectMap = onSelectMap
            super.init()
            try? AVAudioSession.sharedInstance().setCategory(
                .ambient,
                options: [.mixWithOthers]
            )
        }

        func installBackground(into container: GModHomeMenuContainerView) {
            backgroundContainer = container
            let data = preferredBackgroundData()
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
               let name = body["map"] as? String,
               let map = GModBundledMap(rawValue: name) {
                onSelectMap(map)
                return
            }

            if action == "sound",
               let name = body["name"] as? String {
                playSound(named: name)
                return
            }

            if action == "diagnostic" {
                let level = body["level"] as? String ?? "info"
                let text = body["message"] as? String ?? ""
                print("[Garry's PAD][Menu][\(level)] \(text)")
                return
            }

            guard action == "lua",
                  let command = body["command"] as? String else {
                return
            }

            if let map = Self.mapCommand(in: command) {
                onSelectMap(map)
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

        private func playSound(named rawName: String) {
            let name = rawName
                .replacingOccurrences(of: "\\", with: "/")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .lowercased()
            guard !name.isEmpty,
                  !name.split(separator: "/").contains(".."),
                  ["wav", "mp3"].contains(
                      URL(fileURLWithPath: name).pathExtension.lowercased()
                  ) else {
                return
            }
            let logicalPath = name.hasPrefix("sound/")
                ? name
                : "sound/\(name)"
            if let existing = soundPlayers[logicalPath] {
                existing.currentTime = 0
                existing.play()
                return
            }
            guard let assetSource else { return }
            let data: Data
            do {
                guard let loaded = try assetSource.data(for: logicalPath) else {
                    return
                }
                data = loaded
            } catch {
                return
            }
            guard let player = try? AVAudioPlayer(data: data) else { return }
            player.prepareToPlay()
            soundPlayers[logicalPath] = player
            player.play()
        }

        private static func mapCommand(in command: String) -> GModBundledMap? {
            let compact = command
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "'", with: "\"")
                .lowercased()
            guard compact.contains("runconsolecommand(\"map\",") else {
                return nil
            }
            if compact.contains("\"gm_construct\"") { return .construct }
            if compact.contains("\"gm_flatgrass\"") { return .flatgrass }
            return nil
        }

        static let serverSettingsScript = """
        if (typeof UpdateServerSettings === 'function') {
          UpdateServerSettings({sv_lan:'1',p2p_enabled:'0',p2p_friendsonly:'0',
            maxplayers:'1',hostname:"Garry's PAD",settings:{}});
        }
        """
    }

    private static let engineFacadeScript = """
    window.util={MotionSensorAvailable:function(cb){if(typeof cb==='function')cb(false);return false;}};
    window.language={Update:function(key,cb){var labels={
      back_to_main_menu:'Back to Main Menu',resume_game:'Resume Game',
      new_game:'Start New Game',find_mp_game:'Find Multiplayer Game',
      addons:'Addons',dupes:'Dupes',saves:'Saves',demos:'Demos',
      options:'Options',quit:'Quit',disconnect:'Disconnect',
      problems:'Problems',games:'Games',start_game:'Start Game',search:'Search'};
      var value=labels[key]||key.replace(/_/g,' ');if(typeof cb==='function')cb(value);return value;}};
    """

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
        UpdateLanguages(['en.png']);
        UpdateLanguage('en');
        UpdateVersion("Garry's PAD",'2026.08.20','unknown');
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
        </style></head><body><main class="page">\(logoMarkup)<section id="home" class="menu"><button onclick="showWorlds()">START NEW GAME</button></section><section id="worlds" class="menu hidden"><div class="title">Choose a world</div><button class="map" onclick="start('gm_construct')">gm_construct<small>Sandbox</small></button><button class="map" onclick="start('gm_flatgrass')">gm_flatgrass<small>Sandbox</small></button></section></main><script>
        function showWorlds(){home.className='menu hidden';worlds.className='menu'}
        function start(map){window.webkit.messageHandlers.garrysPAD.postMessage({action:'startMap',map:map})}
        </script></body></html>
        """
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
    let status: String

    func makeCoordinator() -> Coordinator {
        Coordinator(
            pack: pack,
            assetSource: assetSource,
            map: map,
            status: status
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
                "<html><body style='margin:0;background:#111;color:#fff;" +
                    "font:24px Helvetica;display:grid;place-items:center'>" +
                    "Loading…</body></html>",
                baseURL: nil
            )
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(map: map, status: status, in: webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        fileprivate let contentHandler: ContentSchemeHandler
        private var map: GModBundledMap
        private var status: String

        init(
            pack: GarrysPADContentPack,
            assetSource: GModContentPackAssetSource?,
            map: GModBundledMap,
            status: String
        ) {
            let source = assetSource
            contentHandler = ContentSchemeHandler(pack: pack, assetSource: source)
            self.map = map
            self.status = status
        }

        func update(map: GModBundledMap, status: String, in webView: WKWebView) {
            self.map = map
            self.status = status
            webView.evaluateJavaScript(Self.script(map: map, status: status))
        }

        func webView(
            _ webView: WKWebView,
            didFinish navigation: WKNavigation!
        ) {
            webView.evaluateJavaScript(Self.script(map: map, status: status))
        }

        private static func script(map: GModBundledMap, status: String) -> String {
            let mapName = quoted(map.rawValue)
            let statusText = quoted(status)
            let imageURL = quoted(
                "\(GModStockLoadingView.scheme)://content/maps/thumb/" +
                    "\(map.rawValue).png"
            )
            return """
            (function(){
              var map=\(mapName), image=\(imageURL), status=\(statusText);
              if(typeof GameDetails==='function'){
                GameDetails("Garry's PAD","",map,1,"","sandbox",1,"en","Sandbox");
              }
              var mapImage=document.querySelector('#mapimg');
              if(mapImage) mapImage.setAttribute('src',image);
              document.body.style.backgroundImage="url('"+image+"')";
              if(typeof SetStatusChanged==='function') SetStatusChanged(status);
              var statusBox=document.querySelector('#spambox');
              if(statusBox){statusBox.textContent=status;statusBox.style.cssText=
                'position:fixed;right:24px;bottom:20px;padding:8px 12px;'+
                'background:rgba(0,0,0,.55);color:white;font:13px monospace;';}
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
