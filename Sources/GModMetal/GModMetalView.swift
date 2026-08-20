import SwiftUI
import MetalKit
import QuartzCore
import Foundation
import simd
import GModEngine

/// Separates UIKit's logical point viewport from Metal's physical drawable.
/// GLua/VGUI and pointer mapping use logical points; world projection uses the
/// drawable aspect so Retina scale changes never shrink UI coordinates.
public struct GModMetalViewportDimensions: Sendable, Equatable {
    public let logicalWidth: Int
    public let logicalHeight: Int
    public let drawableWidth: Int
    public let drawableHeight: Int

    public init?(logicalSize: CGSize, drawableSize: CGSize) {
        guard let logicalWidth = Self.dimension(logicalSize.width),
              let logicalHeight = Self.dimension(logicalSize.height),
              let drawableWidth = Self.dimension(drawableSize.width),
              let drawableHeight = Self.dimension(drawableSize.height) else {
            return nil
        }
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.drawableWidth = drawableWidth
        self.drawableHeight = drawableHeight
    }

    public var logicalAspectRatio: Double {
        Double(logicalWidth) / Double(logicalHeight)
    }

    public var drawableAspectRatio: Double {
        Double(drawableWidth) / Double(drawableHeight)
    }

    private static func dimension(_ value: CGFloat) -> Int? {
        guard value.isFinite, value > 0, value <= CGFloat(Int.max) else {
            return nil
        }
        let rounded = value.rounded()
        guard rounded >= 1 else { return nil }
        return Int(rounded)
    }
}

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
    private let surfaceScene: GModMetalSurfaceScene?
    private let onFrame: @Sendable (GModMetalFrameRequest) -> Void

    public init(
        stats: Binding<String>,
        worldScene: GModMetalWorldScene? = nil,
        surfaceScene: GModMetalSurfaceScene? = nil,
        onFrame: @escaping @Sendable (GModMetalFrameRequest) -> Void = { _ in }
    ) {
        self._stats = stats
        self.worldScene = worldScene
        self.surfaceScene = surfaceScene
        self.onFrame = onFrame
    }

    public func makeCoordinator()
        -> Coordinator
    {
        Coordinator(
            stats: $stats,
            worldScene: worldScene,
            surfaceScene: surfaceScene,
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

        let colorPixelFormat: MTLPixelFormat =
            .bgra8Unorm

        let depthPixelFormat: MTLPixelFormat =
            .depth32Float

        view.colorPixelFormat =
            colorPixelFormat

        view.depthStencilPixelFormat =
            depthPixelFormat

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
            device: device,
            colorPixelFormat: colorPixelFormat,
            depthPixelFormat: depthPixelFormat
        )

        view.delegate =
            context.coordinator

        return view
    }

    public func updateUIView(
        _ uiView: MTKView,
        context: Context
    ) {
        context.coordinator.reportViewport(
            logicalSize: uiView.bounds.size,
            drawableSize: uiView.drawableSize
        )
        context.coordinator.submit(
            worldScene: worldScene,
            surfaceScene: surfaceScene
        )
    }

    // MARK: - Coordinator

    public final class Coordinator:
        NSObject,
        MTKViewDelegate
    {

        @MainActor
        private final class StatsSink {
            private var stats: Binding<String>

            init(stats: Binding<String>) {
                self.stats = stats
            }

            func publish(_ message: String) {
                stats.wrappedValue = message
            }
        }

        private let statsSink: StatsSink

        private let onFrame:
            @Sendable (GModMetalFrameRequest) -> Void

        private let viewportLock = NSLock()

        private var reportedViewportDimensions:
            GModMetalViewportDimensions?

        private let engine =
            GMEngine()

        private var commandQueue:
            MTLCommandQueue?

        private var trianglePipeline:
            MTLRenderPipelineState?

        private var worldPipeline:
            MTLRenderPipelineState?

        private var surfaceSolidPipeline:
            MTLRenderPipelineState?

        private var surfaceTexturedPipeline:
            MTLRenderPipelineState?

        private var depthState:
            MTLDepthStencilState?

        private var surfaceDepthState:
            MTLDepthStencilState?

        private var surfaceSamplerState:
            MTLSamplerState?

        private let pendingSceneLock = NSLock()

        private enum PendingWorldScene {
            case replace(GModMetalWorldScene)
            case clear
        }

        private enum PendingSurfaceScene {
            case replace(GModMetalSurfaceScene)
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

        private struct SurfaceGPUVertex {
            let position: SIMD2<Float>
            let uv: SIMD2<Float>
            let color: SIMD4<Float>
        }

        private struct CachedSurfaceTexture {
            let bitmap: GModMetalSurfaceBitmap
            let texture: MTLTexture
        }

        private struct SurfaceUploadBudget {
            static let maximumTextureCount = 8
            static let maximumByteCount = 8 * 1_024 * 1_024
            static let maximumSingleTextureByteCount = 8 * 1_024 * 1_024

            var remainingTextureCount = SurfaceUploadBudget.maximumTextureCount
            var remainingByteCount = SurfaceUploadBudget.maximumByteCount
            var deferredTextureCount = 0

            mutating func reserve(byteCount: Int) -> Bool {
                guard byteCount >= 0,
                      byteCount <= Self.maximumSingleTextureByteCount,
                      remainingTextureCount > 0,
                      byteCount <= remainingByteCount else {
                    deferredTextureCount += 1
                    return false
                }
                remainingTextureCount -= 1
                remainingByteCount -= byteCount
                return true
            }
        }

        private enum SurfaceTextureCachePolicy {
            static let maximumTextureCount = 2_048
            static let maximumByteCount = 32 * 1_024 * 1_024
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

        private var pendingSurfaceScene:
            PendingSurfaceScene?

        /// Accessed only by MTKView's serialized draw callback.
        private var activeWorldScene:
            GModMetalWorldScene?

        /// Accessed only by MTKView's serialized draw callback.
        private var cachedWorldMesh:
            CachedWorldMesh?

        private var worldSceneIssue:
            String?

        /// Accessed only by MTKView's serialized draw callback.
        private var activeSurfaceScene:
            GModMetalSurfaceScene?

        /// Accessed only by MTKView's serialized draw callback.
        private var cachedSurfaceTextures:
            [String: CachedSurfaceTexture] = [:]

        /// Least-recently-used keys, oldest first. Accessed only by the
        /// serialized MTKView draw callback.
        private var cachedSurfaceTextureOrder:
            [String] = []

        private var cachedSurfaceTextureByteCount = 0

        private var surfaceSceneIssue:
            String?

        private var lastSurfaceDrawCount = 0

        private var lastSurfaceDroppedDrawCount = 0

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

        @MainActor
        init(
            stats: Binding<String>,
            worldScene: GModMetalWorldScene?,
            surfaceScene: GModMetalSurfaceScene? = nil,
            onFrame: @escaping @Sendable (GModMetalFrameRequest) -> Void
        ) {
            statsSink = StatsSink(stats: stats)
            self.onFrame = onFrame
            if let worldScene {
                pendingWorldScene = .replace(worldScene)
            } else {
                pendingWorldScene = .clear
            }
            if let surfaceScene {
                pendingSurfaceScene = .replace(surfaceScene)
            } else {
                pendingSurfaceScene = .clear
            }
        }

        func setup(
            device: MTLDevice,
            colorPixelFormat: MTLPixelFormat,
            depthPixelFormat: MTLPixelFormat
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
                        ),

                    let surfaceVertexFunction =
                        library.makeFunction(
                            name:
                                "surfaceVertexMain"
                        ),

                    let surfaceSolidFragmentFunction =
                        library.makeFunction(
                            name:
                                "surfaceSolidFragmentMain"
                        ),

                    let surfaceTexturedFragmentFunction =
                        library.makeFunction(
                            name:
                                "surfaceTexturedFragmentMain"
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
                        colorPixelFormat

                triangleDescriptor.depthAttachmentPixelFormat =
                    depthPixelFormat

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
                        colorPixelFormat

                worldDescriptor.depthAttachmentPixelFormat =
                    depthPixelFormat

                worldPipeline =
                    try device
                        .makeRenderPipelineState(
                            descriptor:
                                worldDescriptor
                        )

                let surfaceSolidDescriptor =
                    Self.makeSurfacePipelineDescriptor(
                        vertexFunction: surfaceVertexFunction,
                        fragmentFunction: surfaceSolidFragmentFunction,
                        colorPixelFormat: colorPixelFormat,
                        depthPixelFormat: depthPixelFormat
                    )

                surfaceSolidPipeline =
                    try device.makeRenderPipelineState(
                        descriptor: surfaceSolidDescriptor
                    )

                let surfaceTexturedDescriptor =
                    Self.makeSurfacePipelineDescriptor(
                        vertexFunction: surfaceVertexFunction,
                        fragmentFunction: surfaceTexturedFragmentFunction,
                        colorPixelFormat: colorPixelFormat,
                        depthPixelFormat: depthPixelFormat
                    )

                surfaceTexturedPipeline =
                    try device.makeRenderPipelineState(
                        descriptor: surfaceTexturedDescriptor
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

                let surfaceDepthDescriptor =
                    MTLDepthStencilDescriptor()

                surfaceDepthDescriptor.depthCompareFunction =
                    .always

                surfaceDepthDescriptor.isDepthWriteEnabled =
                    false

                guard
                    let surfaceDepthState =
                        device.makeDepthStencilState(
                            descriptor: surfaceDepthDescriptor
                        )
                else {
                    publish(
                        "Failed to create Metal surface depth state"
                    )
                    return
                }

                self.surfaceDepthState = surfaceDepthState

                let samplerDescriptor = MTLSamplerDescriptor()
                samplerDescriptor.minFilter = .linear
                samplerDescriptor.magFilter = .linear
                samplerDescriptor.mipFilter = .notMipmapped
                samplerDescriptor.sAddressMode = .clampToEdge
                samplerDescriptor.tAddressMode = .clampToEdge

                guard let surfaceSamplerState = device.makeSamplerState(
                    descriptor: samplerDescriptor
                ) else {
                    publish(
                        "Failed to create Metal surface sampler"
                    )
                    return
                }

                self.surfaceSamplerState = surfaceSamplerState

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
            reportViewport(
                logicalSize: view.bounds.size,
                drawableSize: size
            )
        }

        func reportViewport(logicalSize: CGSize, drawableSize: CGSize) {
            guard let replacement = GModMetalViewportDimensions(
                logicalSize: logicalSize,
                drawableSize: drawableSize
            ) else { return }
            viewportLock.lock()
            if reportedViewportDimensions != replacement {
                reportedViewportDimensions = replacement
            }
            viewportLock.unlock()
        }

        private func currentViewportDimensions()
            -> GModMetalViewportDimensions?
        {
            viewportLock.lock()
            defer { viewportLock.unlock() }
            return reportedViewportDimensions
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

        /// Atomically replaces both renderer inputs so a SwiftUI update cannot
        /// pair a new world camera with an older surface frame.
        func submit(
            worldScene: GModMetalWorldScene?,
            surfaceScene: GModMetalSurfaceScene?
        ) {
            pendingSceneLock.lock()
            if let worldScene {
                pendingWorldScene = .replace(worldScene)
            } else {
                pendingWorldScene = .clear
            }
            if let surfaceScene {
                pendingSurfaceScene = .replace(surfaceScene)
            } else {
                pendingSurfaceScene = .clear
            }
            pendingSceneLock.unlock()
        }

        /// One-slot handoff for a fully materialized surface frame. It carries
        /// no runtime/Lua references and replaces older, unconsumed frames.
        func submit(surfaceScene: GModMetalSurfaceScene?) {
            pendingSceneLock.lock()
            if let surfaceScene {
                pendingSurfaceScene = .replace(surfaceScene)
            } else {
                pendingSurfaceScene = .clear
            }
            pendingSceneLock.unlock()
        }

        private func takePendingScenes() -> (
            world: PendingWorldScene?,
            surface: PendingSurfaceScene?
        ) {
            pendingSceneLock.lock()
            let result = (pendingWorldScene, pendingSurfaceScene)
            pendingWorldScene = nil
            pendingSurfaceScene = nil
            pendingSceneLock.unlock()
            return result
        }

        private func applyPendingWorldScene(
            _ pending: PendingWorldScene?,
            device: MTLDevice
        ) {
            guard let pending else { return }

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

        private func applyPendingSurfaceScene(
            _ pending: PendingSurfaceScene?
        ) {
            guard let pending else { return }

            switch pending {
            case .clear:
                activeSurfaceScene = nil
                clearCachedSurfaceTextures()
                surfaceSceneIssue = nil
                lastSurfaceDrawCount = 0
                lastSurfaceDroppedDrawCount = 0

            case let .replace(scene):
                guard scene.viewportWidth > 0, scene.viewportHeight > 0 else {
                    activeSurfaceScene = nil
                    clearCachedSurfaceTextures()
                    surfaceSceneIssue =
                        "invalid viewport \(scene.viewportWidth)x\(scene.viewportHeight)"
                    lastSurfaceDrawCount = 0
                    lastSurfaceDroppedDrawCount = 0
                    return
                }

                let retainedKeys = Set(scene.commands.compactMap {
                    command -> String? in
                    switch command {
                    case .solidRectangle:
                        return nil
                    case let .texturedRectangle(rectangle):
                        return rectangle.bitmap.cacheIdentifier
                    case let .text(text):
                        return text.glyphBitmap.cacheIdentifier
                    }
                })
                pruneCachedSurfaceTextures(retaining: retainedKeys)
                activeSurfaceScene = scene
                surfaceSceneIssue = nil
                lastSurfaceDrawCount = 0
                lastSurfaceDroppedDrawCount = 0
            }
        }

        private static func makeSurfacePipelineDescriptor(
            vertexFunction: MTLFunction,
            fragmentFunction: MTLFunction,
            colorPixelFormat: MTLPixelFormat,
            depthPixelFormat: MTLPixelFormat
        ) -> MTLRenderPipelineDescriptor {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
            descriptor.depthAttachmentPixelFormat = depthPixelFormat

            let color = descriptor.colorAttachments[0]!
            color.isBlendingEnabled = true
            color.rgbBlendOperation = .add
            color.alphaBlendOperation = .add
            color.sourceRGBBlendFactor = .one
            color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.sourceAlphaBlendFactor = .one
            color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return descriptor
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

            reportViewport(
                logicalSize: view.bounds.size,
                drawableSize: view.drawableSize
            )

            guard let device = view.device else { return }
            let pendingScenes = takePendingScenes()
            applyPendingWorldScene(pendingScenes.world, device: device)
            applyPendingSurfaceScene(pendingScenes.surface)

            guard
                let commandQueue,
                let trianglePipeline,
                let worldPipeline,
                let surfaceSolidPipeline,
                let surfaceTexturedPipeline,
                let depthState,
                let surfaceDepthState,
                let surfaceSamplerState,
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

            let viewportDimensions = currentViewportDimensions()
            let logicalViewport = SIMD2<Int>(
                viewportDimensions?.logicalWidth ?? 1,
                viewportDimensions?.logicalHeight ?? 1
            )
            let drawableViewport = SIMD2<Int>(
                viewportDimensions?.drawableWidth ?? 1,
                viewportDimensions?.drawableHeight ?? 1
            )
            onFrame(
                GModMetalFrameRequest(
                    fixedTickCount: ticks,
                    viewportWidth: logicalViewport.x,
                    viewportHeight: logicalViewport.y
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
                    viewport: drawableViewport,
                    pipeline: worldPipeline,
                    encoder: encoder
                )
            } else {
                drawFallbackTriangle(
                    pipeline: trianglePipeline,
                    encoder: encoder
                )
            }

            if let surfaceScene = activeSurfaceScene {
                lastSurfaceDrawCount = drawSurface(
                    scene: surfaceScene,
                    device: device,
                    solidPipeline: surfaceSolidPipeline,
                    texturedPipeline: surfaceTexturedPipeline,
                    depthState: surfaceDepthState,
                    sampler: surfaceSamplerState,
                    encoder: encoder
                )
            } else {
                lastSurfaceDrawCount = 0
                lastSurfaceDroppedDrawCount = 0
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
            let vertices = sourceVertices.map { vertex in
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

        private func drawSurface(
            scene: GModMetalSurfaceScene,
            device: MTLDevice,
            solidPipeline: MTLRenderPipelineState,
            texturedPipeline: MTLRenderPipelineState,
            depthState: MTLDepthStencilState,
            sampler: MTLSamplerState,
            encoder: MTLRenderCommandEncoder
        ) -> Int {
            var viewport = SIMD2<Float>(
                Float(scene.viewportWidth),
                Float(scene.viewportHeight)
            )
            guard viewport.x.isFinite, viewport.y.isFinite,
                  viewport.x > 0, viewport.y > 0
            else {
                lastSurfaceDroppedDrawCount = 0
                surfaceSceneIssue = "surface viewport cannot be represented by Metal"
                return 0
            }

            surfaceSceneIssue = nil
            encoder.setDepthStencilState(depthState)
            encoder.setCullMode(.none)
            encoder.setFragmentSamplerState(sampler, index: 0)

            var drawn = 0
            var uploadBudget = SurfaceUploadBudget()
            let drawAdmission = GModMetalSurfaceDrawCommandBudget()
                .admission(for: scene.commands.count)
            lastSurfaceDroppedDrawCount = drawAdmission.droppedCommandCount
            for command in scene.commands.prefix(
                drawAdmission.admittedCommandCount
            ) {
                switch command {
                case let .solidRectangle(rectangle):
                    drawSurfaceQuad(
                        frame: rectangle.frame,
                        uv: GModMetalSurfaceRect(
                            x: 0,
                            y: 0,
                            width: 1,
                            height: 1
                        ),
                        color: rectangle.color,
                        viewport: &viewport,
                        pipeline: solidPipeline,
                        texture: nil,
                        encoder: encoder
                    )
                    drawn += 1

                case let .texturedRectangle(rectangle):
                    guard let texture = surfaceTexture(
                        for: rectangle.bitmap,
                        device: device,
                        uploadBudget: &uploadBudget
                    ) else { continue }
                    drawSurfaceQuad(
                        frame: rectangle.frame,
                        uv: rectangle.uv,
                        color: rectangle.color,
                        viewport: &viewport,
                        pipeline: texturedPipeline,
                        texture: texture,
                        encoder: encoder
                    )
                    drawn += 1

                case let .text(text):
                    guard let texture = surfaceTexture(
                        for: text.glyphBitmap,
                        device: device,
                        uploadBudget: &uploadBudget
                    ) else { continue }
                    drawSurfaceQuad(
                        frame: text.frame,
                        uv: text.uv,
                        color: text.color,
                        viewport: &viewport,
                        pipeline: texturedPipeline,
                        texture: texture,
                        encoder: encoder
                    )
                    drawn += 1
                }
            }
            var issues: [String] = []
            if let surfaceSceneIssue { issues.append(surfaceSceneIssue) }
            if drawAdmission.droppedCommandCount > 0 {
                issues.append(
                    "dropped \(drawAdmission.droppedCommandCount) surface " +
                        "draw command(s); render limit is " +
                        "\(GModMetalSurfaceDrawCommandBudget.defaultMaximumCommandCount)"
                )
            }
            if uploadBudget.deferredTextureCount > 0 {
                issues.append(
                    "deferred \(uploadBudget.deferredTextureCount) new surface " +
                    "texture upload(s); per-frame budget is " +
                    "\(SurfaceUploadBudget.maximumTextureCount) textures / " +
                    "\(SurfaceUploadBudget.maximumByteCount) bytes"
                )
            }
            surfaceSceneIssue = issues.isEmpty
                ? nil
                : issues.joined(separator: "; ")
            return drawn
        }

        private func drawSurfaceQuad(
            frame: GModMetalSurfaceRect,
            uv: GModMetalSurfaceRect,
            color: GModMetalSurfaceColor,
            viewport: inout SIMD2<Float>,
            pipeline: MTLRenderPipelineState,
            texture: MTLTexture?,
            encoder: MTLRenderCommandEncoder
        ) {
            let x0 = frame.x
            let y0 = frame.y
            let x1 = frame.x + frame.width
            let y1 = frame.y + frame.height
            let u0 = uv.x
            let v0 = uv.y
            let u1 = uv.x + uv.width
            let v1 = uv.y + uv.height
            let tint = SIMD4<Float>(
                color.red,
                color.green,
                color.blue,
                color.alpha
            )
            let vertices = [
                SurfaceGPUVertex(
                    position: SIMD2<Float>(x0, y0),
                    uv: SIMD2<Float>(u0, v0),
                    color: tint
                ),
                SurfaceGPUVertex(
                    position: SIMD2<Float>(x1, y0),
                    uv: SIMD2<Float>(u1, v0),
                    color: tint
                ),
                SurfaceGPUVertex(
                    position: SIMD2<Float>(x0, y1),
                    uv: SIMD2<Float>(u0, v1),
                    color: tint
                ),
                SurfaceGPUVertex(
                    position: SIMD2<Float>(x1, y1),
                    uv: SIMD2<Float>(u1, v1),
                    color: tint
                )
            ]

            encoder.setRenderPipelineState(pipeline)
            vertices.withUnsafeBytes { bytes in
                guard let address = bytes.baseAddress else { return }
                encoder.setVertexBytes(
                    address,
                    length: bytes.count,
                    index: 0
                )
            }
            withUnsafeBytes(of: &viewport) { bytes in
                guard let address = bytes.baseAddress else { return }
                encoder.setVertexBytes(
                    address,
                    length: bytes.count,
                    index: 1
                )
            }
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(
                type: .triangleStrip,
                vertexStart: 0,
                vertexCount: vertices.count
            )
        }

        private func surfaceTexture(
            for bitmap: GModMetalSurfaceBitmap,
            device: MTLDevice,
            uploadBudget: inout SurfaceUploadBudget
        ) -> MTLTexture? {
            if let cached = cachedSurfaceTextures[bitmap.cacheIdentifier],
               cached.bitmap == bitmap {
                touchCachedSurfaceTexture(bitmap.cacheIdentifier)
                return cached.texture
            }

            let byteCount = bitmap.premultipliedRGBA8.count
            guard byteCount <= SurfaceUploadBudget.maximumSingleTextureByteCount
            else {
                surfaceSceneIssue =
                    "surface texture exceeds the upload limit: " +
                    "\(bitmap.resourceIdentifier) (\(byteCount) bytes)"
                return nil
            }
            guard uploadBudget.reserve(byteCount: byteCount) else {
                return nil
            }

            prepareSurfaceTextureCacheInsertion(
                key: bitmap.cacheIdentifier,
                byteCount: byteCount
            )

            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: bitmap.width,
                height: bitmap.height,
                mipmapped: false
            )
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead]
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                surfaceSceneIssue =
                    "Metal texture allocation failed for \(bitmap.resourceIdentifier)"
                return nil
            }

            let uploaded = bitmap.premultipliedRGBA8.withUnsafeBytes {
                bytes -> Bool in
                guard let address = bytes.baseAddress else { return false }
                texture.replace(
                    region: MTLRegionMake2D(
                        0,
                        0,
                        bitmap.width,
                        bitmap.height
                    ),
                    mipmapLevel: 0,
                    withBytes: address,
                    bytesPerRow: bitmap.width * 4
                )
                return true
            }
            guard uploaded else {
                surfaceSceneIssue =
                    "Metal texture upload failed for \(bitmap.resourceIdentifier)"
                return nil
            }

            cachedSurfaceTextures[bitmap.cacheIdentifier] = CachedSurfaceTexture(
                bitmap: bitmap,
                texture: texture
            )
            cachedSurfaceTextureOrder.append(bitmap.cacheIdentifier)
            cachedSurfaceTextureByteCount += byteCount
            return texture
        }

        private func clearCachedSurfaceTextures() {
            cachedSurfaceTextures.removeAll(keepingCapacity: true)
            cachedSurfaceTextureOrder.removeAll(keepingCapacity: true)
            cachedSurfaceTextureByteCount = 0
        }

        private func pruneCachedSurfaceTextures(
            retaining retainedKeys: Set<String>
        ) {
            let keysToRemove = cachedSurfaceTextureOrder.filter {
                !retainedKeys.contains($0)
            }
            for key in keysToRemove {
                removeCachedSurfaceTexture(key)
            }
        }

        private func touchCachedSurfaceTexture(_ key: String) {
            cachedSurfaceTextureOrder.removeAll { $0 == key }
            cachedSurfaceTextureOrder.append(key)
        }

        private func removeCachedSurfaceTexture(_ key: String) {
            if let removed = cachedSurfaceTextures.removeValue(forKey: key) {
                cachedSurfaceTextureByteCount -=
                    removed.bitmap.premultipliedRGBA8.count
            }
            cachedSurfaceTextureOrder.removeAll { $0 == key }
            cachedSurfaceTextureByteCount = max(0, cachedSurfaceTextureByteCount)
        }

        private func prepareSurfaceTextureCacheInsertion(
            key: String,
            byteCount: Int
        ) {
            removeCachedSurfaceTexture(key)
            while !cachedSurfaceTextureOrder.isEmpty,
                  cachedSurfaceTextures.count >=
                    SurfaceTextureCachePolicy.maximumTextureCount ||
                  cachedSurfaceTextureByteCount + byteCount >
                    SurfaceTextureCachePolicy.maximumByteCount {
                removeCachedSurfaceTexture(cachedSurfaceTextureOrder[0])
            }
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

            let surfaceStats: String
            if let scene = activeSurfaceScene {
                let diagnostics = scene.diagnostics
                let summary =
                    "UI: \(lastSurfaceDrawCount)/\(diagnostics.resolvedCommandCount) " +
                    "rendered (solid \(diagnostics.solidRectangleCount), " +
                    "PNG \(diagnostics.texturedRectangleCount), " +
                    "text \(diagnostics.textCount)); " +
                    "unresolved \(diagnostics.unresolvedCommands.count); " +
                    "dropped capture " +
                    "\(diagnostics.captureDiagnostics.droppedCommandCount), " +
                    "scene \(diagnostics.droppedSnapshotCommandCount), " +
                    "draw \(lastSurfaceDroppedDrawCount); " +
                    "scene bitmaps \(diagnostics.retainedBitmapCount) / " +
                    "\(diagnostics.retainedBitmapByteCount) bytes; " +
                    "GPU cache \(cachedSurfaceTextures.count) textures / " +
                    "\(cachedSurfaceTextureByteCount) bytes"
                if let surfaceSceneIssue {
                    surfaceStats = summary + "; issue: \(surfaceSceneIssue)"
                } else {
                    surfaceStats = summary
                }
            } else if let surfaceSceneIssue {
                surfaceStats = "UI rejected: \(surfaceSceneIssue)"
            } else {
                surfaceStats = "UI: none"
            }

            publish(
                """
                ARM64 Swift + Metal
                GPU: \(deviceName)
                \(rendererStats)
                \(surfaceStats)
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

            DispatchQueue.main.async { [statsSink] in
                statsSink.publish(message)
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
            WorldVertex sourceVertex = vertices[vertexID];
            output.position =
                uniforms.viewProjection * sourceVertex.position;
            output.normal = sourceVertex.normal.xyz;
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

        struct SurfaceVertex
        {
            float2 position;
            float2 uv;
            float4 color;
        };

        struct SurfaceVertexOutput
        {
            float4 position [[position]];
            float2 uv;
            float4 color;
        };

        vertex SurfaceVertexOutput surfaceVertexMain(
            const device SurfaceVertex *vertices
                [[buffer(0)]],

            constant float2 &viewport
                [[buffer(1)]],

            uint vertexID
                [[vertex_id]]
        )
        {
            SurfaceVertex sourceVertex = vertices[vertexID];
            float2 normalized = sourceVertex.position / viewport;
            SurfaceVertexOutput output;
            output.position = float4(
                normalized.x * 2.0 - 1.0,
                1.0 - normalized.y * 2.0,
                0.0,
                1.0
            );
            output.uv = sourceVertex.uv;
            output.color = sourceVertex.color;
            return output;
        }

        fragment float4 surfaceSolidFragmentMain(
            SurfaceVertexOutput input [[stage_in]]
        )
        {
            return float4(
                input.color.rgb * input.color.a,
                input.color.a
            );
        }

        fragment float4 surfaceTexturedFragmentMain(
            SurfaceVertexOutput input [[stage_in]],

            texture2d<float> bitmap [[texture(0)]],

            sampler bitmapSampler [[sampler(0)]]
        )
        {
            float4 sample = bitmap.sample(bitmapSampler, input.uv);
            return float4(
                sample.rgb * input.color.rgb * input.color.a,
                sample.a * input.color.a
            );
        }
        """
    }
}
