import SwiftUI
import WebKit

public struct GModMainView: View {

    @State private var status = """
    Starting...
    """

    public init() {}

    public var body: some View {
        VStack(spacing: 16) {

            Text("GMod iPad")
                .font(.largeTitle)
                .bold()

            Text(status)
                .font(.system(.body, design: .monospaced))
                .multilineTextAlignment(.center)

            GModWebGPUTestView(
                status: $status
            )
            .frame(maxWidth: .infinity)
            .frame(height: 420)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 16
                )
            )
        }
        .padding()
    }
}

private struct GModWebGPUTestView:
    UIViewRepresentable
{

    @Binding var status: String

    func makeCoordinator() -> Coordinator {
        Coordinator(status: $status)
    }

    func makeUIView(
        context: Context
    ) -> WKWebView {

        let configuration =
            WKWebViewConfiguration()

        configuration
            .defaultWebpagePreferences
            .allowsContentJavaScript = true

        configuration
            .userContentController
            .add(
                context.coordinator,
                name: "gmod"
            )

        let webView = WKWebView(
            frame: .zero,
            configuration: configuration
        )

        /*
         Use a local file instead of loadHTMLString.

         This also moves us closer to the final
         GMod architecture where HTML/JS/WASM
         resources live together.
        */

        do {

            let directory =
                FileManager
                    .default
                    .temporaryDirectory
                    .appendingPathComponent(
                        "GModWebGPU",
                        isDirectory: true
                    )

            try FileManager.default
                .createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )

            let file =
                directory
                    .appendingPathComponent(
                        "index.html"
                    )

            try Self.testPage
                .write(
                    to: file,
                    atomically: true,
                    encoding: .utf8
                )

            webView.loadFileURL(
                file,
                allowingReadAccessTo: directory
            )

        } catch {

            DispatchQueue.main.async {
                status =
                    "HTML LOAD ERROR\n\(error)"
            }
        }

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

    // MARK: - Coordinator

    final class Coordinator:
        NSObject,
        WKScriptMessageHandler
    {

        private var status:
            Binding<String>

        init(
            status: Binding<String>
        ) {
            self.status = status
        }

        func userContentController(
            _ userContentController:
                WKUserContentController,

            didReceive message:
                WKScriptMessage
        ) {

            guard
                message.name == "gmod"
            else {
                return
            }

            guard
                let text =
                    message.body as? String
            else {
                return
            }

            DispatchQueue.main.async {

                self.status
                    .wrappedValue = text
            }
        }
    }

    // MARK: - WASM

    /*
     Existing C++ -> WASM add(20, 22) test.

     Expected:
     42
    */

    private static let wasmBase64 = """
AGFzbQEAAAABBwFgAn9/AX8DAgEABQMBAAIGCAF/AUGAiAQLBxgCBm1lbW9yeQIAC2dtX3Rlc3RfYWRkAAAKCQEHACABIABqCwA4BG5hbWUADQxnbV90ZXN0Lndhc20BDgEAC2dtX3Rlc3RfYWRkBxIBAA9fX3N0YWNrX3BvaW50ZXIAfwlwcm9kdWNlcnMBDHByb2Nlc3NlZC1ieQEFY2xhbmdfMTcuMC4wIChodHRwczovL2dpdGh1Yi5jb20vc3dpZnRsYW5nL2xsdm0tcHJvamVjdC5naXQgMTA5OTliNmQwMzRmZTMxOGYzZDU2YzgzYmRkYjY1NzI1OTNhOGJiMCkASQ90YXJnZXRfZmVhdHVyZXMEKwptdWx0aXZhbHVlKw9tdXRhYmxlLWdsb2JhbHMrD3JlZmVyZW5jZS10eXBlcysIc2lnbi1leHQ=
"""

    // MARK: - HTML / WebGPU

    private static var testPage: String {

        """
        <!doctype html>

        <html>

        <head>

        <meta
            name="viewport"
            content="
                width=device-width,
                initial-scale=1.0,
                maximum-scale=1.0
            "
        >

        <style>

        html,
        body {
            margin: 0;
            width: 100%;
            height: 100%;
            overflow: hidden;
            background: #000;
        }

        canvas {
            display: block;
            width: 100%;
            height: 100%;
            background: #000;
        }

        #overlay {
            position: absolute;

            left: 14px;
            top: 14px;

            color: white;

            font-family:
                ui-monospace,
                SFMono-Regular,
                Menlo,
                monospace;

            font-size: 13px;

            white-space: pre-line;

            pointer-events: none;
        }

        </style>

        </head>

        <body>

        <canvas id="gpuCanvas"></canvas>

        <div id="overlay">
        Initializing...
        </div>

        <script>

        const wasmBase64 =
            "\(wasmBase64)";

        const overlay =
            document.getElementById(
                "overlay"
            );

        function send(message) {

            overlay.textContent =
                message;

            window
                .webkit
                .messageHandlers
                .gmod
                .postMessage(
                    message
                );
        }

        function decodeBase64(base64) {

            const binary =
                atob(base64);

            const bytes =
                new Uint8Array(
                    binary.length
                );

            for (
                let i = 0;
                i < binary.length;
                ++i
            ) {

                bytes[i] =
                    binary.charCodeAt(i);
            }

            return bytes;
        }

        async function start() {

            try {

                // -------------------------
                // 1. WASM
                // -------------------------

                const bytes =
                    decodeBase64(
                        wasmBase64
                    );

                const wasm =
                    await WebAssembly
                        .instantiate(
                            bytes.buffer
                        );

                const add =
                    wasm
                        .instance
                        .exports
                        .gm_test_add;

                if (
                    typeof add !==
                    "function"
                ) {

                    throw new Error(
                        "gm_test_add missing"
                    );
                }

                const wasmResult =
                    add(
                        20,
                        22
                    );

                send(
                    "C++ -> WASM OK\\n" +
                    "Result: " +
                    wasmResult +
                    "\\n\\n" +
                    "Checking WebGPU..."
                );

                // -------------------------
                // 2. WebGPU availability
                // -------------------------

                if (
                    !navigator.gpu
                ) {

                    send(
                        "C++ -> WASM OK\\n" +
                        "Result: " +
                        wasmResult +
                        "\\n\\n" +
                        "WebGPU: UNAVAILABLE\\n" +
                        "Secure context: " +
                        window.isSecureContext
                    );

                    return;
                }

                // -------------------------
                // 3. GPU Adapter
                // -------------------------

                const adapter =
                    await navigator
                        .gpu
                        .requestAdapter({
                            powerPreference:
                                "high-performance"
                        });

                if (!adapter) {

                    throw new Error(
                        "WebGPU adapter not found"
                    );
                }

                // -------------------------
                // 4. GPU Device
                // -------------------------

                const device =
                    await adapter
                        .requestDevice();

                // -------------------------
                // 5. Canvas
                // -------------------------

                const canvas =
                    document
                        .getElementById(
                            "gpuCanvas"
                        );

                const context =
                    canvas
                        .getContext(
                            "webgpu"
                        );

                if (!context) {

                    throw new Error(
                        "webgpu canvas context unavailable"
                    );
                }

                const dpr =
                    window.devicePixelRatio ||
                    1;

                canvas.width =
                    Math.max(
                        1,
                        Math.floor(
                            canvas.clientWidth *
                            dpr
                        )
                    );

                canvas.height =
                    Math.max(
                        1,
                        Math.floor(
                            canvas.clientHeight *
                            dpr
                        )
                    );

                const format =
                    navigator
                        .gpu
                        .getPreferredCanvasFormat();

                context.configure({

                    device:
                        device,

                    format:
                        format,

                    alphaMode:
                        "opaque"
                });

                // -------------------------
                // 6. WGSL shader
                // -------------------------

                const shader =
                    device.createShaderModule({

                    code: `

                    @vertex
                    fn vertexMain(
                        @builtin(vertex_index)
                        vertexIndex: u32
                    )
                    -> @builtin(position)
                       vec4<f32>
                    {

                        var positions =
                            array<vec2<f32>, 3>(

                                vec2<f32>(
                                     0.0,
                                     0.75
                                ),

                                vec2<f32>(
                                    -0.7,
                                    -0.65
                                ),

                                vec2<f32>(
                                     0.7,
                                    -0.65
                                )
                            );

                        let p =
                            positions[
                                vertexIndex
                            ];

                        return vec4<f32>(
                            p.x,
                            p.y,
                            0.0,
                            1.0
                        );
                    }

                    @fragment
                    fn fragmentMain()
                    -> @location(0)
                       vec4<f32>
                    {

                        return vec4<f32>(
                            0.10,
                            0.75,
                            1.00,
                            1.00
                        );
                    }

                    `
                });

                // -------------------------
                // 7. Pipeline
                // -------------------------

                const pipeline =
                    device
                        .createRenderPipeline({

                    layout:
                        "auto",

                    vertex: {

                        module:
                            shader,

                        entryPoint:
                            "vertexMain"
                    },

                    fragment: {

                        module:
                            shader,

                        entryPoint:
                            "fragmentMain",

                        targets: [
                            {
                                format:
                                    format
                            }
                        ]
                    },

                    primitive: {

                        topology:
                            "triangle-list"
                    }
                });

                // -------------------------
                // 8. Render
                // -------------------------

                const encoder =
                    device
                        .createCommandEncoder();

                const pass =
                    encoder
                        .beginRenderPass({

                    colorAttachments: [
                        {

                            view:
                                context
                                    .getCurrentTexture()
                                    .createView(),

                            clearValue: {

                                r: 0.015,
                                g: 0.020,
                                b: 0.030,
                                a: 1.0
                            },

                            loadOp:
                                "clear",

                            storeOp:
                                "store"
                        }
                    ]
                });

                pass.setPipeline(
                    pipeline
                );

                pass.draw(
                    3
                );

                pass.end();

                device.queue.submit([
                    encoder.finish()
                ]);

                // -------------------------
                // Success
                // -------------------------

                send(
                    "C++ -> WASM OK\\n" +
                    "Result: " +
                    wasmResult +
                    "\\n\\n" +
                    "WebGPU: OK\\n" +
                    "Format: " +
                    format +
                    "\\n" +
                    "Secure context: " +
                    window.isSecureContext
                );

            } catch (error) {

                send(
                    "TEST ERROR\\n\\n" +
                    String(
                        error &&
                        error.stack
                            ? error.stack
                            : error
                    )
                );
            }
        }

        start();

        </script>

        </body>

        </html>
        """
    }
}
