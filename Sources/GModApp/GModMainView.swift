import SwiftUI
import WebKit

public struct GModMainView: View {

    @State private var status = "Starting C++ WebAssembly..."

    public init() {}

    public var body: some View {
        VStack(spacing: 20) {

            Text("GMod iPad")
                .font(.largeTitle)
                .bold()

            Text(status)
                .multilineTextAlignment(.center)
                .monospaced()

            GModWasmView(status: $status)
                .frame(width: 1, height: 1)
                .opacity(0)
        }
        .padding()
    }
}

private struct GModWasmView: UIViewRepresentable {

    @Binding var status: String

    func makeCoordinator() -> Coordinator {
        Coordinator(status: $status)
    }

    func makeUIView(context: Context) -> WKWebView {

        let configuration = WKWebViewConfiguration()

        configuration
            .userContentController
            .add(
                context.coordinator,
                name: "gmod"
            )

        configuration
            .defaultWebpagePreferences
            .allowsContentJavaScript = true

        let webView = WKWebView(
            frame: .zero,
            configuration: configuration
        )

        webView.loadHTMLString(
            Self.testPage,
            baseURL: nil
        )

        return webView
    }

    func updateUIView(
        _ uiView: WKWebView,
        context: Context
    ) {
    }

    static func dismantleUIView(
        _ uiView: WKWebView,
        coordinator: Coordinator
    ) {
        uiView
            .configuration
            .userContentController
            .removeScriptMessageHandler(
                forName: "gmod"
            )
    }

    final class Coordinator:
        NSObject,
        WKScriptMessageHandler
    {

        private var status: Binding<String>

        init(status: Binding<String>) {
            self.status = status
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {

            guard message.name == "gmod" else {
                return
            }

            DispatchQueue.main.async {

                if let text = message.body as? String {
                    self.status.wrappedValue = text
                }
            }
        }
    }

    private static let wasmBase64 = """
AGFzbQEAAAABBwFgAn9/AX8DAgEABQMBAAIGCAF/AUGAiAQLBxgCBm1lbW9yeQIAC2dtX3Rlc3RfYWRkAAAKCQEHACABIABqCwA4BG5hbWUADQxnbV90ZXN0Lndhc20BDgEAC2dtX3Rlc3RfYWRkBxIBAA9fX3N0YWNrX3BvaW50ZXIAfwlwcm9kdWNlcnMBDHByb2Nlc3NlZC1ieQEFY2xhbmdfMTcuMC4wIChodHRwczovL2dpdGh1Yi5jb20vc3dpZnRsYW5nL2xsdm0tcHJvamVjdC5naXQgMTA5OTliNmQwMzRmZTMxOGYzZDU2YzgzYmRkYjY1NzI1OTNhOGJiMCkASQ90YXJnZXRfZmVhdHVyZXMEKwptdWx0aXZhbHVlKw9tdXRhYmxlLWdsb2JhbHMrD3JlZmVyZW5jZS10eXBlcysIc2lnbi1leHQ=
"""

    private static var testPage: String {

        """
        <!doctype html>

        <html>
        <head>
            <meta charset="utf-8">
        </head>

        <body>

        <script>

        const wasmBase64 = "\(wasmBase64)";

        function send(message) {
            window.webkit
                .messageHandlers
                .gmod
                .postMessage(message);
        }

        try {

            const binary =
                atob(wasmBase64);

            const bytes =
                new Uint8Array(
                    binary.length
                );

            for (
                let i = 0;
                i < binary.length;
                i++
            ) {
                bytes[i] =
                    binary.charCodeAt(i);
            }

            WebAssembly
                .instantiate(
                    bytes.buffer
                )
                .then(result => {

                    const add =
                        result
                            .instance
                            .exports
                            .gm_test_add;

                    const value =
                        add(20, 22);

                    send(
                        "C++ → WASM OK\\nResult: "
                        + value
                    );

                })
                .catch(error => {

                    send(
                        "WASM ERROR\\n"
                        + error
                    );

                });

        } catch (error) {

            send(
                "JavaScript ERROR\\n"
                + error
            );
        }

        </script>

        </body>
        </html>
        """
    }
}
