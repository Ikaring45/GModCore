import SwiftUI
import WebKit
import GModGameAssets

struct GModHomeMenuView: UIViewRepresentable {
    let pack: GarrysPADContentPack
    let backgroundJPEG: Data
    let logoPNG: Data?
    let onSelectMap: (GModBundledMap) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelectMap: onSelectMap)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(
            context.coordinator,
            name: Coordinator.messageName
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.bounces = false
        webView.accessibilityIdentifier = "garryspad.home.web"
        webView.loadHTMLString(html, baseURL: nil)
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
        var onSelectMap: (GModBundledMap) -> Void

        init(onSelectMap: @escaping (GModBundledMap) -> Void) {
            self.onSelectMap = onSelectMap
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == Self.messageName,
                  let body = message.body as? [String: Any],
                  body["action"] as? String == "startMap",
                  let rawMap = body["map"] as? String,
                  let map = GModBundledMap(rawValue: rawMap) else {
                return
            }
            onSelectMap(map)
        }
    }

    private var html: String {
        let background = backgroundJPEG.base64EncodedString()
        let logo = logoPNG?.base64EncodedString()
        let logoMarkup = logo.map {
            "<img class='logo' src='data:image/png;base64,\($0)' alt=\"Garry's Mod\">"
        } ?? "<div class='wordmark'>garry's mod</div>"
        return """
        <!doctype html>
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <style>
        *{box-sizing:border-box;-webkit-user-select:none}html,body{margin:0;width:100%;height:100%;overflow:hidden;font-family:Arial,sans-serif;color:white;background:#121416}
        body:before{content:"";position:fixed;inset:0;background:linear-gradient(90deg,rgba(6,9,12,.94) 0%,rgba(9,12,15,.72) 44%,rgba(0,0,0,.18) 100%),url(data:image/jpeg;base64,\(background)) center/cover;transform:scale(1.03)}
        .page{position:relative;height:100%;padding:7vh 7vw;display:flex;flex-direction:column}.logo{width:min(430px,64vw);height:auto}.wordmark{font-size:min(76px,11vw);font-weight:900;letter-spacing:-5px}
        .sub{margin-top:10px;color:#aab4bf;font-size:14px;letter-spacing:2px}.menu{margin-top:auto;margin-bottom:8vh;width:min(520px,82vw)}
        button{display:block;width:100%;border:0;text-align:left;color:#f2f5f7;background:rgba(28,34,39,.88);font-size:clamp(21px,3vw,34px);font-weight:700;padding:18px 22px;margin:10px 0;border-left:5px solid #4b9ce2;border-radius:2px}
        button:active{background:#3c89c8;transform:translateX(4px)}.hidden{display:none}.title{font-size:clamp(25px,4vw,42px);font-weight:700;margin-bottom:17px}.map small{display:block;color:#b9c4cc;font-size:13px;font-weight:400;margin-top:4px}
        .back{font-size:17px;background:rgba(28,34,39,.7);border-left-color:#727d85}.badge{position:absolute;right:24px;bottom:18px;color:#8f9ba5;font:12px monospace}
        </style></head><body><main class="page">\(logoMarkup)<div class="sub">GARRY'S PAD · LOCAL CONTENT PACK</div>
        <section id="home" class="menu"><button onclick="showWorlds()">START NEW GAME</button><button onclick="showWorlds()">PLAY SINGLEPLAYER</button></section>
        <section id="worlds" class="menu hidden"><div class="title">Choose a world</div>
        <button class="map" onclick="start('gm_construct')">gm_construct<small>Sandbox · city and build spaces</small></button>
        <button class="map" onclick="start('gm_flatgrass')">gm_flatgrass<small>Sandbox · open flat world</small></button>
        <button class="back" onclick="showHome()">← Back</button></section>
        <div class="badge">ZIP DIRECT MOUNT · \(pack.entries.count) ENTRIES</div></main>
        <script>
        function showWorlds(){document.getElementById('home').className='menu hidden';document.getElementById('worlds').className='menu'}
        function showHome(){document.getElementById('worlds').className='menu hidden';document.getElementById('home').className='menu'}
        function start(map){window.webkit.messageHandlers.garrysPAD.postMessage({action:'startMap',map:map})}
        </script></body></html>
        """
    }
}
