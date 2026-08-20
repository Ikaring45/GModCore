import AVFoundation
import Foundation
import SwiftUI
import WebKit
import GModGameAssets
import GModGameSession

/// Serves the original GMod menu HTML/CSS/JS/templates/images directly from
/// the user's content ZIP. Swift only supplies the engine callbacks.
struct GModHomeMenuView: UIViewRepresentable {
    private static let scheme = "garryspad"
    private static let menuPath = "garrysmod/html/menu.html"

    let pack: GarrysPADContentPack
    let assetSource: GModContentPackAssetSource?
    let backgroundJPEG: Data
    let logoPNG: Data?
    let onSelectMap: (GModBundledMap) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            pack: pack,
            assetSource: assetSource,
            onSelectMap: onSelectMap
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
            source: Self.menuBridgeScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.bounces = false
        webView.customUserAgent = "Valve Source Client GarrysPAD/iPad"
        webView.accessibilityIdentifier = "garryspad.home.web"

        if let entry = try? pack.entry(for: Self.menuPath),
           entry.compressionMethod == 0,
           let url = URL(string: "\(Self.scheme)://content/\(Self.menuPath)") {
            webView.load(URLRequest(url: url))
        } else {
            // Older transfer packs compressed HTML. Keep them usable while
            // new Full packs load the real document tree above.
            webView.loadHTMLString(fallbackHTML, baseURL: nil)
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onSelectMap = onSelectMap
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: Coordinator.messageName
        )
        webView.stopLoading()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        static let messageName = "garrysPAD"
        let contentHandler: ContentSchemeHandler
        var onSelectMap: (GModBundledMap) -> Void
        private let assetSource: GModContentPackAssetSource?
        private var soundPlayers: [String: AVAudioPlayer] = [:]

        init(
            pack: GarrysPADContentPack,
            assetSource: GModContentPackAssetSource?,
            onSelectMap: @escaping (GModBundledMap) -> Void
        ) {
            let source = assetSource
            contentHandler = ContentSchemeHandler(pack: pack, assetSource: source)
            assetSource = source
            self.onSelectMap = onSelectMap
            super.init()
            try? AVAudioSession.sharedInstance().setCategory(
                .ambient,
                options: [.mixWithOthers]
            )
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == Self.messageName,
                  let body = message.body as? [String: Any],
                  let action = body["action"] as? String else { return }
            if action == "startMap",
               let name = body["map"] as? String,
               let map = GModBundledMap(rawValue: name) {
                onSelectMap(map)
                return
            }
            if action == "sound", let name = body["name"] as? String {
                playSound(named: name)
                return
            }
            guard action == "lua", let command = body["command"] as? String else {
                return
            }
            if let map = Self.mapCommand(in: command) {
                onSelectMap(map)
            } else if command.contains("UpdateServerSettings") {
                message.webView?.evaluateJavaScript(Self.serverSettingsScript)
            }
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
                  ) else { return }
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
            guard compact.contains("runconsolecommand(\"map\",") else { return nil }
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
      function format(cmd,args){var out='',arg=1;for(var i=0;i<cmd.length;i++){
        if(cmd[i]==='%'&&i+1<cmd.length){i++;if(cmd[i]==='s'){var v=String(args[arg++]);
          out+='"'+v.replace(/["\\\\]/g,'\\$&')+'"';continue;}
          if(cmd[i]==='i'){out+=String(args[arg++]);continue;}}out+=cmd[i];}return out;}
      window.lua=window.lua||{};
      window.lua.Run=function(cmd){window.webkit.messageHandlers.garrysPAD.postMessage(
        {action:'lua',command:format(String(cmd),arguments)});};
      window.lua.PlaySound=function(name){window.webkit.messageHandlers.garrysPAD.postMessage(
        {action:'sound',name:String(name)});};
      function configure(){if(typeof UpdateGamemodes!=='function'||!window.gScope){
        return setTimeout(configure,30);}UpdateGamemodes({'1':{menusystem:true,maps:'^gm_',
        name:'sandbox',title:'Sandbox'}});UpdateCurrentGamemode('sandbox');
        UpdateMaps({Sandbox:['gm_construct','gm_flatgrass']});UpdateLanguages(['en.png']);
        UpdateLanguage('en');UpdateVersion("Garry's PAD",'2026.08.20','unknown');
        \(Coordinator.serverSettingsScript)
        document.documentElement.style.background="#15191d url('\(scheme)://content/garrysmod/html/img/bg.jpg') center/cover fixed no-repeat";
        document.body.style.backgroundColor='transparent';}
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
        let contentHandler: ContentSchemeHandler
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
            task.didFailWithError(URLError(.badURL)); return
        }
        let path = Self.logicalPath(for: url)
        do {
            let data: Data
            if pack.contains(path) {
                data = try pack.data(
                    for: path,
                    maximumByteCount: 64 * 1_024 * 1_024
                )
            } else if let resolved = try assetSource?.data(for: path) {
                data = resolved
            } else {
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

    private static func mimeType(_ path: String) -> String {
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
