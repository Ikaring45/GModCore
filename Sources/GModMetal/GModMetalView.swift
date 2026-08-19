import SwiftUI
import MetalKit
import QuartzCore
import Foundation
import simd
import GModEngine

public struct GModMetalFrameRequest: Sendable, Equatable {
    public let fixedTickCount: Int
    public let viewportWidth: Int
    public let viewportHeight: Int

    public init(
        fixedTickCount: Int,
        viewportWidth: Int,
        viewportHeight: Int
    ) {
        self.fixedTickCount = fixedTickCount
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
    }
}

public struct GModMetalView:
    UIViewRepresentable
{

    @Binding private var stats: String
    private let worldScene: GModMetalWorldScene?
    private let onFrame: @Sendable (GModMetalFrameRequest) -> Void

    public init(
        stats: Binding<String>,
        worldScene: GModMetalWorldScene? = nil,
        onFrame: @escaping @Sendable (GModMetalFrameRequest) -> Void = { _ in }
    ) {
        self._stats = stats
        self.worldScene = worldScene
        self.onFrame = onFrame
    }

    public func makeCoordinator()
        -> Coordinator
    {
        Coordinator(
            stats: $stats,
            worldScene: worldScene,
            onFrame: onFrame
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

        view.depthStencilPixelFormat =
            .depth32Float

        view.clearDepth = 1.0

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
        context.coordinator.submit(worldScene: worldScene)
    }

    // MARK: - Coordinator

    public final class Coordinator:
        NSObject,
        MTKViewDelegate
    {

        private var stats:
            Binding<String>

        private let onFrame:
            @Sendable (GModMetalFrameRequest) -> Void

        private var reportedViewport:
            SIMD2<Int>?

        private let engine =
            GMEngine()

        private var commandQueue:
            MTLCommandQueue?

        private var trianglePipeline:
            MTLRenderPipelineState?

        private var worldPipeline:
            MTLRenderPipelineState?

        private var depthState:
            MTLDepthStencilState?

        private let pendingSceneLock = NSLock()

        private enum PendingWorldScene {
            case replace(GModMetalWorldScene)
            case clear
        }

        private struct CachedWorldMesh {
            let identifier: String
            let vertexCount: Int
            let indexCount: Int
            let vertexBuffer: MTLBuffer
            let indexBuffer: MTLBuffer
        }

        private struct WorldGPUVertex {
            let position: SIMD4<Float>
            let normal: SIMD4<Float>
        }

        private struct WorldUniforms {
            let viewProjection: simd_float4x4
            let lightDirection: SIMD4<Float>
        }

        private enum WorldSceneError: Error, CustomStringConvertible {
            case emptyIdentifier
            case emptyVertices
            case mismatchedArrays(positions: Int, normals: Int)
            case convertedArrayMismatch
            case emptyIndices
            case incompleteTriangle(indexCount: Int)
            case invalidPosition(index: Int)
            case invalidNormal(index: Int)
            case zeroNormal(index: Int)
            case invalidIndex(index: UInt32, vertexCount: Int)
            case invalidCameraEye
            case invalidCameraForward
            case zeroCameraForward
            case vertexBufferAllocationFailed
            case indexBufferAllocationFailed

            var description: String {
                switch self {
                case .emptyIdentifier:
                    return "mesh identifier is empty"
                case .emptyVertices:
                    return "mesh has no vertices"
                case let .mismatchedArrays(positions, normals):
                    return "position/normal counts differ (\(positions)/\(normals))"
                case .convertedArrayMismatch:
                    return "Source/Metal array counts differ"
                case .emptyIndices:
                    return "mesh has no indices"
                case let .incompleteTriangle(indexCount):
                    return "index count \(indexCount) is not divisible by three"
                case let .invalidPosition(index):
                    return "vertex \(index) has a non-finite position"
                case let .invalidNormal(index):
                    return "vertex \(index) has a non-finite normal"
                case let .zeroNormal(index):
                    return "vertex \(index) has a zero-length normal"
                case let .invalidIndex(index, vertexCount):
                    return "index \(index) is outside 0..<\(vertexCount)"
                case .invalidCameraEye:
                    return "camera eye is non-finite"
                case .invalidCameraForward:
                    return "camera forward is non-finite"
                case .zeroCameraForward:
                    return "camera forward has zero length"
                case .vertexBufferAllocationFailed:
                    return "Metal vertex-buffer allocation failed"
                case .indexBufferAllocationFailed:
                    return "Metal index-buffer allocation failed"
                }
            }
        }

        private var pendingWorldScene:
            PendingWorldScene?

        /// Accessed only by MTKView's serialized draw callback.
        private var activeWorldScene:
            GModMetalWorldScene?

        /// Accessed only by MTKView's serialized draw callback.
        private var cachedWorldMesh:
            CachedWorldMesh?

        private var worldSceneIssue:
            String?

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
            worldScene: GModMetalWorldScene?,
            onFrame: @escaping @Sendable (GModMetalFrameRequest) -> Void
        ) {
            self.stats = stats
            self.onFrame = onFrame
            if let worldScene {
                pendingWorldScene = .replace(worldScene)
            } else {
                pendingWorldScene = .clear
            }
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
                    let triangleVertexFunction =
                        library.makeFunction(
                            name:
                                "vertexMain"
                        ),

                    let triangleFragmentFunction =
                        library.makeFunction(
                            name:
                                "fragmentMain"
                        ),

                    let worldVertexFunction =
                        library.makeFunction(
                            name:
                                "worldVertexMain"
                        ),

                    let worldFragmentFunction =
                        library.makeFunction(
                            name:
                                "worldFragmentMain"
                        )
                else {

                    publish(
                        "Metal shader functions missing"
                    )

                    return
                }

                let triangleDescriptor =
                    MTLRenderPipelineDescriptor()

                triangleDescriptor.vertexFunction =
                    triangleVertexFunction

                triangleDescriptor.fragmentFunction =
                    triangleFragmentFunction

                triangleDescriptor
                    .colorAttachments[0]
                    .pixelFormat =
                        view.colorPixelFormat

                triangleDescriptor.depthAttachmentPixelFormat =
                    view.depthStencilPixelFormat

                trianglePipeline =
                    try device
                        .makeRenderPipelineState(
                            descriptor:
                                triangleDescriptor
                        )

                let worldDescriptor =
                    MTLRenderPipelineDescriptor()

                worldDescriptor.vertexFunction =
                    worldVertexFunction

                worldDescriptor.fragmentFunction =
                    worldFragmentFunction

                worldDescriptor
                    .colorAttachments[0]
                    .pixelFormat =
                        view.colorPixelFormat

                worldDescriptor.depthAttachmentPixelFormat =
                    view.depthStencilPixelFormat

                worldPipeline =
                    try device
                        .makeRenderPipelineState(
                            descriptor:
                                worldDescriptor
                        )

                let depthDescriptor =
                    MTLDepthStencilDescriptor()

                depthDescriptor.depthCompareFunction =
                    .less

                depthDescriptor.isDepthWriteEnabled =
                    true

                guard
                    let depthState =
                        device.makeDepthStencilState(
                            descriptor:
                                depthDescriptor
                        )
                else {
                    publish(
                        "Failed to create Metal depth state"
                    )
                    return
                }

                self.depthState = depthState

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
        }

        /// One-slot handoff from SwiftUI/MainActor state to MTKView's draw
        /// callback. Geometry upload and all active-scene mutation stay on the
        /// render callback; the callback never reaches into Lua state.
        func submit(worldScene: GModMetalWorldScene?) {
            pendingSceneLock.lock()
            if let worldScene {
                pendingWorldScene = .replace(worldScene)
            } else {
                pendingWorldScene = .clear
            }
            pendingSceneLock.unlock()
        }

        private func takePendingWorldScene() -> PendingWorldScene? {
            pendingSceneLock.lock()
            let result = pendingWorldScene
            pendingWorldScene = nil
            pendingSceneLock.unlock()
            return result
        }

        private func applyPendingWorldScene(
            device: MTLDevice
        ) {
            guard let pending = takePendingWorldScene() else { return }

            switch pending {
            case .clear:
                activeWorldScene = nil
                worldSceneIssue = nil

            case let .replace(scene):
                do {
                    try Self.validateCamera(scene)

                    let cacheMatches =
                        cachedWorldMesh?.identifier == scene.meshIdentifier &&
                        cachedWorldMesh?.vertexCount == scene.metalPositions.count &&
                        cachedWorldMesh?.indexCount == scene.indices.count

                    if !cacheMatches {
                        cachedWorldMesh = try Self.makeCachedWorldMesh(
                            scene,
                            device: device
                        )
                    }

                    activeWorldScene = scene
                    worldSceneIssue = nil
                } catch {
                    activeWorldScene = nil
                    worldSceneIssue = String(describing: error)
                    publish(
                        "WORLD SCENE REJECTED\n\(error)"
                    )
                }
            }
        }

        private static func makeCachedWorldMesh(
            _ scene: GModMetalWorldScene,
            device: MTLDevice
        ) throws -> CachedWorldMesh {
            try validateMesh(scene)

            let vertices = zip(scene.metalPositions, scene.metalNormals).map {
                position, normal in

                WorldGPUVertex(
                    position: SIMD4<Float>(position, 1),
                    normal: SIMD4<Float>(normal, 0)
                )
            }

            let vertexBuffer = vertices.withUnsafeBytes {
                bytes -> MTLBuffer? in

                guard let address = bytes.baseAddress else { return nil }
                return device.makeBuffer(
                    bytes: address,
                    length: bytes.count,
                    options: .storageModeShared
                )
            }

            guard let vertexBuffer else {
                throw WorldSceneError.vertexBufferAllocationFailed
            }

            let indexBuffer = scene.indices.withUnsafeBytes {
                bytes -> MTLBuffer? in

                guard let address = bytes.baseAddress else { return nil }
                return device.makeBuffer(
                    bytes: address,
                    length: bytes.count,
                    options: .storageModeShared
                )
            }

            guard let indexBuffer else {
                throw WorldSceneError.indexBufferAllocationFailed
            }

            return CachedWorldMesh(
                identifier: scene.meshIdentifier,
                vertexCount: vertices.count,
                indexCount: scene.indices.count,
                vertexBuffer: vertexBuffer,
                indexBuffer: indexBuffer
            )
        }

        private static func validateMesh(
            _ scene: GModMetalWorldScene
        ) throws {
            guard !scene.meshIdentifier.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty else {
                throw WorldSceneError.emptyIdentifier
            }
            guard !scene.sourcePositions.isEmpty else {
                throw WorldSceneError.emptyVertices
            }
            guard scene.sourcePositions.count == scene.sourceNormals.count else {
                throw WorldSceneError.mismatchedArrays(
                    positions: scene.sourcePositions.count,
                    normals: scene.sourceNormals.count
                )
            }
            guard
                scene.metalPositions.count == scene.sourcePositions.count,
                scene.metalNormals.count == scene.sourceNormals.count
            else {
                throw WorldSceneError.convertedArrayMismatch
            }
            guard !scene.indices.isEmpty else {
                throw WorldSceneError.emptyIndices
            }
            guard scene.indices.count.isMultiple(of: 3) else {
                throw WorldSceneError.incompleteTriangle(
                    indexCount: scene.indices.count
                )
            }

            for index in scene.sourcePositions.indices {
                let sourcePosition = scene.sourcePositions[index]
                let metalPosition = scene.metalPositions[index]
                guard isFinite(sourcePosition), isFinite(metalPosition) else {
                    throw WorldSceneError.invalidPosition(index: index)
                }

                let sourceNormal = scene.sourceNormals[index]
                let metalNormal = scene.metalNormals[index]
                guard isFinite(sourceNormal), isFinite(metalNormal) else {
                    throw WorldSceneError.invalidNormal(index: index)
                }
                let normalLengthSquared = simd_length_squared(metalNormal)
                guard normalLengthSquared.isFinite,
                      normalLengthSquared > Float.ulpOfOne
                else {
                    throw WorldSceneError.zeroNormal(index: index)
                }
            }

            let vertexCount = scene.metalPositions.count
            for index in scene.indices where UInt64(index) >= UInt64(vertexCount) {
                throw WorldSceneError.invalidIndex(
                    index: index,
                    vertexCount: vertexCount
                )
            }
        }

        private static func validateCamera(
            _ scene: GModMetalWorldScene
        ) throws {
            guard isFinite(scene.cameraEye), isFinite(scene.metalCameraEye) else {
                throw WorldSceneError.invalidCameraEye
            }
            guard
                isFinite(scene.cameraForward),
                isFinite(scene.metalCameraForward)
            else {
                throw WorldSceneError.invalidCameraForward
            }
            let lengthSquared = simd_length_squared(scene.metalCameraForward)
            guard lengthSquared.isFinite,
                  lengthSquared > Float.ulpOfOne
            else {
                throw WorldSceneError.zeroCameraForward
            }
        }

        private static func isFinite(_ value: SIMD3<Float>) -> Bool {
            value.x.isFinite && value.y.isFinite && value.z.isFinite
        }

        public func draw(
            in view: MTKView
        ) {

            reportDrawableSize(view.drawableSize)

            guard let device = view.device else { return }
            applyPendingWorldScene(device: device)

            guard
                let commandQueue,
                let trianglePipeline,
                let worldPipeline,
                let depthState,
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

            let viewport = reportedViewport ?? SIMD2<Int>(1, 1)
            onFrame(
                GModMetalFrameRequest(
                    fixedTickCount: ticks,
                    viewportWidth: viewport.x,
                    viewportHeight: viewport.y
                )
            )

            statsElapsed += delta
            statsFrames &+= 1
            statsTicks &+= UInt64(ticks)

            updateStatsIfNeeded()

            descriptor.depthAttachment.clearDepth = 1.0
            descriptor.depthAttachment.loadAction = .clear

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

            encoder.setDepthStencilState(depthState)
            encoder.setCullMode(.none)

            if
                let scene = activeWorldScene,
                let mesh = cachedWorldMesh,
                mesh.identifier == scene.meshIdentifier,
                mesh.vertexCount == scene.metalPositions.count,
                mesh.indexCount == scene.indices.count
            {
                drawWorld(
                    scene: scene,
                    mesh: mesh,
                    viewport: viewport,
                    pipeline: worldPipeline,
                    encoder: encoder
                )
            } else {
                drawFallbackTriangle(
                    pipeline: trianglePipeline,
                    encoder: encoder
                )
            }

            encoder.endEncoding()

            commandBuffer.present(
                drawable
            )

            commandBuffer.commit()
        }

        private func drawFallbackTriangle(
            pipeline: MTLRenderPipelineState,
            encoder: MTLRenderCommandEncoder
        ) {
            let angle = Double(engine.rotation)
            let cosine = Float(cos(angle))
            let sine = Float(sin(angle))
            let sourceVertices: [SIMD2<Float>] = [
                SIMD2<Float>(0.0, 0.72),
                SIMD2<Float>(-0.68, -0.60),
                SIMD2<Float>(0.68, -0.60)
            ]
            var vertices = sourceVertices.map { vertex in
                SIMD2<Float>(
                    vertex.x * cosine - vertex.y * sine,
                    vertex.x * sine + vertex.y * cosine
                )
            }

            encoder.setRenderPipelineState(pipeline)
            vertices.withUnsafeBytes { bytes in
                guard let address = bytes.baseAddress else { return }
                encoder.setVertexBytes(
                    address,
                    length: bytes.count,
                    index: 0
                )
            }
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 3
            )
        }

        private func drawWorld(
            scene: GModMetalWorldScene,
            mesh: CachedWorldMesh,
            viewport: SIMD2<Int>,
            pipeline: MTLRenderPipelineState,
            encoder: MTLRenderCommandEncoder
        ) {
            let width = Swift.max(1, viewport.x)
            let height = Swift.max(1, viewport.y)
            let aspect = Float(width) / Float(height)
            let view = Self.makeViewMatrix(
                eye: scene.metalCameraEye,
                forward: scene.metalCameraForward
            )
            let projection = Self.makePerspectiveMatrix(
                verticalFieldOfViewRadians: 75 * .pi / 180,
                aspect: aspect,
                near: 1,
                far: 65_536
            )
            var uniforms = WorldUniforms(
                viewProjection: simd_mul(projection, view),
                lightDirection: SIMD4<Float>(0.35, 0.80, 0.48, 0)
            )

            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(
                mesh.vertexBuffer,
                offset: 0,
                index: 0
            )
            withUnsafeBytes(of: &uniforms) { bytes in
                guard let address = bytes.baseAddress else { return }
                encoder.setVertexBytes(
                    address,
                    length: bytes.count,
                    index: 1
                )
                encoder.setFragmentBytes(
                    address,
                    length: bytes.count,
                    index: 1
                )
            }
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: mesh.indexCount,
                indexType: .uint32,
                indexBuffer: mesh.indexBuffer,
                indexBufferOffset: 0
            )
        }

        private static func makeViewMatrix(
            eye: SIMD3<Float>,
            forward rawForward: SIMD3<Float>
        ) -> simd_float4x4 {
            let forward = simd_normalize(rawForward)
            let preferredUp = SIMD3<Float>(0, 1, 0)
            let alternateUp = SIMD3<Float>(0, 0, 1)
            let upSeed = abs(simd_dot(forward, preferredUp)) > 0.999
                ? alternateUp
                : preferredUp
            let right = simd_normalize(simd_cross(forward, upSeed))
            let up = simd_cross(right, forward)
            let backward = -forward

            return simd_float4x4(columns: (
                SIMD4<Float>(right.x, up.x, backward.x, 0),
                SIMD4<Float>(right.y, up.y, backward.y, 0),
                SIMD4<Float>(right.z, up.z, backward.z, 0),
                SIMD4<Float>(
                    -simd_dot(right, eye),
                    -simd_dot(up, eye),
                    -simd_dot(backward, eye),
                    1
                )
            ))
        }

        /// Right-handed Metal projection with a [0, 1] depth range.
        private static func makePerspectiveMatrix(
            verticalFieldOfViewRadians fieldOfView: Float,
            aspect: Float,
            near: Float,
            far: Float
        ) -> simd_float4x4 {
            let yScale = 1 / tan(fieldOfView * 0.5)
            let xScale = yScale / Swift.max(aspect, Float.ulpOfOne)
            let zScale = far / (near - far)
            let zTranslation = near * far / (near - far)

            return simd_float4x4(columns: (
                SIMD4<Float>(xScale, 0, 0, 0),
                SIMD4<Float>(0, yScale, 0, 0),
                SIMD4<Float>(0, 0, zScale, -1),
                SIMD4<Float>(0, 0, zTranslation, 0)
            ))
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

            let rendererStats: String
            if let scene = activeWorldScene,
               let mesh = cachedWorldMesh,
               mesh.identifier == scene.meshIdentifier
            {
                rendererStats =
                    "World: \(scene.meshIdentifier) (\(mesh.indexCount / 3) triangles)"
            } else if let worldSceneIssue {
                rendererStats =
                    "Triangle fallback / rejected world: \(worldSceneIssue)"
            } else {
                rendererStats =
                    "Triangle fallback"
            }

            publish(
                """
                ARM64 Swift + Metal
                GPU: \(deviceName)
                \(rendererStats)
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

        struct WorldVertex
        {
            float4 position;
            float4 normal;
        };

        struct WorldUniforms
        {
            float4x4 viewProjection;
            float4 lightDirection;
        };

        struct WorldVertexOutput
        {
            float4 position [[position]];
            float3 normal;
        };

        vertex WorldVertexOutput worldVertexMain(
            const device WorldVertex *vertices
                [[buffer(0)]],

            constant WorldUniforms &uniforms
                [[buffer(1)]],

            uint vertexID
                [[vertex_id]]
        )
        {
            WorldVertexOutput output;
            WorldVertex vertex = vertices[vertexID];
            output.position =
                uniforms.viewProjection * vertex.position;
            output.normal = vertex.normal.xyz;
            return output;
        }

        fragment float4 worldFragmentMain(
            WorldVertexOutput input [[stage_in]],

            constant WorldUniforms &uniforms
                [[buffer(1)]]
        )
        {
            float3 normal = normalize(input.normal);
            float3 light = normalize(uniforms.lightDirection.xyz);
            float diffuse = max(dot(normal, light), 0.0);
            float hemisphere = 0.18 + 0.20 * (normal.y * 0.5 + 0.5);
            float brightness = min(1.0, hemisphere + diffuse * 0.72);
            float3 baseColor = float3(0.48, 0.61, 0.72);
            return float4(baseColor * brightness, 1.0);
        }
        """
    }
}
