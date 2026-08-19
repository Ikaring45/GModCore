import SwiftUI
import MetalKit
import QuartzCore
import Foundation
import GModEngine

public struct GModMetalView:
    UIViewRepresentable
{

    @Binding private var stats: String
    private let onSimulationTicks: (Int) -> Void
    private let onViewportSize: (Int, Int) -> Void

    public init(
        stats: Binding<String>,
        onSimulationTicks: @escaping (Int) -> Void = { _ in },
        // The app must explicitly route this to its CLIENT/MENU runtime. The
        // current console owns a SERVER runtime, so its default remains a
        // deliberate no-op until a client execution context is attached.
        onViewportSize: @escaping (Int, Int) -> Void = { _, _ in }
    ) {
        self._stats = stats
        self.onSimulationTicks = onSimulationTicks
        self.onViewportSize = onViewportSize
    }

    public func makeCoordinator()
        -> Coordinator
    {
        Coordinator(
            stats: $stats,
            onSimulationTicks: onSimulationTicks,
            onViewportSize: onViewportSize
        )
    }

    public func makeUIView(
        context: Context
    ) -> MTKView {

        guard
            let device =
                MTLCreateSystemDefaultDevice()
        else {

            DispatchQueue.main.async {
                stats =
                    "Metal device unavailable"
            }

            return MTKView()
        }

        let view = MTKView(
            frame: .zero,
            device: device
        )

        view.colorPixelFormat =
            .bgra8Unorm

        view.clearColor =
            MTLClearColor(
                red: 0.015,
                green: 0.020,
                blue: 0.030,
                alpha: 1
            )

        // 実際の上限は端末・画面側に任せる。
        view.preferredFramesPerSecond =
            120

        view.enableSetNeedsDisplay =
            false

        view.isPaused =
            false

        context.coordinator.setup(
            view: view,
            device: device
        )

        view.delegate =
            context.coordinator

        return view
    }

    public func updateUIView(
        _ uiView: MTKView,
        context: Context
    ) {
        context.coordinator.reportDrawableSize(uiView.drawableSize)
    }

    // MARK: - Coordinator

    public final class Coordinator:
        NSObject,
        MTKViewDelegate
    {

        private var stats:
            Binding<String>

        private let onSimulationTicks:
            (Int) -> Void

        private let onViewportSize:
            (Int, Int) -> Void

        private var reportedViewport:
            SIMD2<Int>?

        private let engine =
            GMEngine()

        private var commandQueue:
            MTLCommandQueue?

        private var pipeline:
            MTLRenderPipelineState?

        private var lastFrameTime =
            CACurrentMediaTime()

        private var statsElapsed:
            Double = 0

        private var statsFrames:
            UInt64 = 0

        private var statsTicks:
            UInt64 = 0

        private var deviceName =
            "Unknown GPU"

        init(
            stats: Binding<String>,
            onSimulationTicks: @escaping (Int) -> Void,
            onViewportSize: @escaping (Int, Int) -> Void
        ) {
            self.stats = stats
            self.onSimulationTicks = onSimulationTicks
            self.onViewportSize = onViewportSize
        }

        func setup(
            view: MTKView,
            device: MTLDevice
        ) {

            deviceName =
                device.name

            guard
                let queue =
                    device.makeCommandQueue()
            else {

                publish(
                    "Failed to create Metal command queue"
                )

                return
            }

            commandQueue =
                queue

            do {

                let library =
                    try device.makeLibrary(
                        source:
                            Self.shaderSource,
                        options: nil
                    )

                guard
                    let vertexFunction =
                        library.makeFunction(
                            name:
                                "vertexMain"
                        ),

                    let fragmentFunction =
                        library.makeFunction(
                            name:
                                "fragmentMain"
                        )
                else {

                    publish(
                        "Metal shader functions missing"
                    )

                    return
                }

                let descriptor =
                    MTLRenderPipelineDescriptor()

                descriptor.vertexFunction =
                    vertexFunction

                descriptor.fragmentFunction =
                    fragmentFunction

                descriptor
                    .colorAttachments[0]
                    .pixelFormat =
                        view.colorPixelFormat

                pipeline =
                    try device
                        .makeRenderPipelineState(
                            descriptor:
                                descriptor
                        )

                engine.boot()

                lastFrameTime =
                    CACurrentMediaTime()

                publish(
                    """
                    ARM Engine booted
                    \(deviceName)
                    Fixed tick: 0.015
                    """
                )

            } catch {

                publish(
                    """
                    METAL ERROR
                    \(error)
                    """
                )
            }
        }

        public func mtkView(
            _ view: MTKView,
            drawableSizeWillChange size: CGSize
        ) {
            reportDrawableSize(size)
        }

        /// Reports physical drawable pixels, which are the viewport units
        /// exposed by GLua's ScrW/ScrH rather than UIKit point dimensions.
        func reportDrawableSize(_ size: CGSize) {
            let width = Int(size.width.rounded())
            let height = Int(size.height.rounded())
            guard width > 0, height > 0 else { return }
            let replacement = SIMD2<Int>(width, height)
            guard reportedViewport != replacement else { return }
            reportedViewport = replacement
            onViewportSize(width, height)
        }

        public func draw(
            in view: MTKView
        ) {

            reportDrawableSize(view.drawableSize)

            guard
                let commandQueue,
                let pipeline,
                let descriptor =
                    view.currentRenderPassDescriptor,
                let drawable =
                    view.currentDrawable
            else {
                return
            }

            let now =
                CACurrentMediaTime()

            var delta =
                now - lastFrameTime

            lastFrameTime =
                now

            if delta < 0 {
                delta = 0
            }

            if delta > 0.25 {
                delta = 0.25
            }

            let ticks =
                engine.frame(
                    deltaTime:
                        delta
                )

            if ticks > 0 {
                onSimulationTicks(ticks)
            }

            statsElapsed += delta
            statsFrames &+= 1
            statsTicks &+= UInt64(ticks)

            updateStatsIfNeeded()

            let angle =
                Double(engine.rotation)

            let cosine =
                Float(cos(angle))

            let sine =
                Float(sin(angle))

            let sourceVertices:
                [SIMD2<Float>] =
            [
                SIMD2<Float>(
                    0.0,
                    0.72
                ),

                SIMD2<Float>(
                    -0.68,
                    -0.60
                ),

                SIMD2<Float>(
                    0.68,
                    -0.60
                )
            ]

            var vertices =
                sourceVertices.map {
                    vertex in

                    SIMD2<Float>(
                        vertex.x * cosine -
                        vertex.y * sine,

                        vertex.x * sine +
                        vertex.y * cosine
                    )
                }

            guard
                let commandBuffer =
                    commandQueue
                        .makeCommandBuffer(),

                let encoder =
                    commandBuffer
                        .makeRenderCommandEncoder(
                            descriptor:
                                descriptor
                        )
            else {
                return
            }

            encoder.setRenderPipelineState(
                pipeline
            )

            vertices.withUnsafeBytes {
                bytes in

                guard
                    let address =
                        bytes.baseAddress
                else {
                    return
                }

                encoder.setVertexBytes(
                    address,
                    length:
                        bytes.count,
                    index: 0
                )
            }

            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 3
            )

            encoder.endEncoding()

            commandBuffer.present(
                drawable
            )

            commandBuffer.commit()
        }

        private func updateStatsIfNeeded() {

            guard
                statsElapsed >= 1.0
            else {
                return
            }

            let fps =
                Double(statsFrames)
                / statsElapsed

            let ticksPerSecond =
                Double(statsTicks)
                / statsElapsed

            let numericStats =
                String(
                    format:
                    """
                    FPS: %.1f
                    Tick/s: %.2f
                    TickCount: %llu
                    CurTime: %.3f
                    Fixed interval: %.3f
                    """,
                    fps,
                    ticksPerSecond,
                    engine.tickCount,
                    engine.curTime,
                    GMEngine.tickInterval
                )

            publish(
                """
                ARM64 Swift + Metal
                GPU: \(deviceName)
                \(numericStats)
                """
            )

            statsElapsed = 0
            statsFrames = 0
            statsTicks = 0
        }

        private func publish(
            _ message: String
        ) {

            DispatchQueue.main.async {

                self.stats
                    .wrappedValue =
                        message
            }
        }

        // MARK: - Metal shader

        private static let shaderSource =
        """
        #include <metal_stdlib>

        using namespace metal;

        vertex float4 vertexMain(
            const device float2 *positions
                [[buffer(0)]],

            uint vertexID
                [[vertex_id]]
        )
        {
            float2 p =
                positions[vertexID];

            return float4(
                p.x,
                p.y,
                0.0,
                1.0
            );
        }

        fragment float4 fragmentMain()
        {
            return float4(
                0.10,
                0.75,
                1.00,
                1.00
            );
        }
        """
    }
}
