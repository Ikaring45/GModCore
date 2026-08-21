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
    private let dynamicEntityScene: GModMetalDynamicEntityScene?
    private let surfaceScene: GModMetalSurfaceScene?
    private let preferredFramesPerSecond: Int
    private let onFrame: @Sendable (GModMetalFrameRequest) -> Void
    private let onWorldFrameEvent: @Sendable (GModMetalWorldFrameEvent) -> Void
    private let onWorldFramePresented: @Sendable (String) -> Void

    public init(
        stats: Binding<String>,
        worldScene: GModMetalWorldScene? = nil,
        dynamicEntityScene: GModMetalDynamicEntityScene? = nil,
        surfaceScene: GModMetalSurfaceScene? = nil,
        preferredFramesPerSecond: Int = 120,
        onFrame: @escaping @Sendable (GModMetalFrameRequest) -> Void = { _ in },
        onWorldFrameEvent: @escaping @Sendable (GModMetalWorldFrameEvent) -> Void =
            { _ in },
        onWorldFramePresented: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self._stats = stats
        self.worldScene = worldScene
        self.dynamicEntityScene = dynamicEntityScene
        self.surfaceScene = surfaceScene
        self.preferredFramesPerSecond = preferredFramesPerSecond <= 60 ? 60 : 120
        self.onFrame = onFrame
        self.onWorldFrameEvent = onWorldFrameEvent
        self.onWorldFramePresented = onWorldFramePresented
    }

    public func makeCoordinator()
        -> Coordinator
    {
        Coordinator(
            stats: $stats,
            worldScene: worldScene,
            dynamicEntityScene: dynamicEntityScene,
            surfaceScene: surfaceScene,
            onFrame: onFrame,
            onWorldFrameEvent: onWorldFrameEvent,
            onWorldFramePresented: onWorldFramePresented
        )
    }

    public func makeUIView(
        context: Context
    ) -> MTKView {

        guard
            let device =
                MTLCreateSystemDefaultDevice()
        else {

            if let meshIdentifier = worldScene?.meshIdentifier {
                context.coordinator.reportRendererFailure(
                    meshIdentifier: meshIdentifier,
                    reason: .metalDeviceUnavailable
                )
            }

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
            GModMetalWorldColorSpaceContract.drawablePixelFormat

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

        // iPadOS may cap the realized cadence to the display/device limit;
        // this is the user's real 60/120 host request, not a claimed FPS.
        view.preferredFramesPerSecond = preferredFramesPerSecond

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
        let requestedFrameRate = preferredFramesPerSecond <= 60 ? 60 : 120
        if uiView.preferredFramesPerSecond != requestedFrameRate {
            uiView.preferredFramesPerSecond = requestedFrameRate
        }
        context.coordinator.reportViewport(
            logicalSize: uiView.bounds.size,
            drawableSize: uiView.drawableSize
        )
        context.coordinator.submit(
            worldScene: worldScene,
            dynamicEntityScene: dynamicEntityScene,
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

        /// Serializes the render callback and GPU completion callback without
        /// retaining the UIView coordinator in a Sendable command handler.
        private final class WorldFramePresentationSink: @unchecked Sendable {
            private let lock = NSLock()
            private let eventCallback:
                @Sendable (GModMetalWorldFrameEvent) -> Void
            private let legacyPresentationCallback: @Sendable (String) -> Void
            private var inFlightIdentifier: String?
            private var terminalIdentifiers: Set<String> = []
            private var progressByIdentifier:
                [String: GModMetalWorldTextureUploadProgress] = [:]

            init(
                eventCallback: @escaping @Sendable
                    (GModMetalWorldFrameEvent) -> Void,
                legacyPresentationCallback: @escaping @Sendable (String) -> Void
            ) {
                self.eventCallback = eventCallback
                self.legacyPresentationCallback = legacyPresentationCallback
            }

            func reserve(_ identifier: String) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                guard !terminalIdentifiers.contains(identifier),
                      inFlightIdentifier != identifier else {
                    return false
                }
                inFlightIdentifier = identifier
                return true
            }

            func finish(
                _ identifier: String,
                succeeded: Bool,
                status: String,
                errorDescription: String?
            ) {
                lock.lock()
                if inFlightIdentifier == identifier {
                    inFlightIdentifier = nil
                }
                let shouldPublish = !terminalIdentifiers.contains(identifier)
                if shouldPublish {
                    terminalIdentifiers.insert(identifier)
                }
                lock.unlock()
                if shouldPublish {
                    if succeeded {
                        publish(.presented(meshIdentifier: identifier))
                    } else {
                        publish(.failed(GModMetalWorldRendererFailure(
                            meshIdentifier: identifier,
                            reason: .commandBufferFailed(
                                status: status,
                                detail: errorDescription
                            )
                        )))
                    }
                }
            }

            func publishProgress(
                _ progress: GModMetalWorldTextureUploadProgress
            ) {
                lock.lock()
                guard !terminalIdentifiers.contains(progress.meshIdentifier),
                      progressByIdentifier[progress.meshIdentifier] != progress else {
                    lock.unlock()
                    return
                }
                progressByIdentifier[progress.meshIdentifier] = progress
                lock.unlock()
                publish(.textureUploadProgress(progress))
            }

            func fail(
                meshIdentifier: String,
                reason: GModMetalWorldRendererFailureReason
            ) {
                lock.lock()
                guard !terminalIdentifiers.contains(meshIdentifier) else {
                    lock.unlock()
                    return
                }
                terminalIdentifiers.insert(meshIdentifier)
                if inFlightIdentifier == meshIdentifier {
                    inFlightIdentifier = nil
                }
                lock.unlock()
                publish(.failed(GModMetalWorldRendererFailure(
                    meshIdentifier: meshIdentifier,
                    reason: reason
                )))
            }

            private func publish(_ event: GModMetalWorldFrameEvent) {
                eventCallback(event)
                if case let .presented(meshIdentifier) = event {
                    legacyPresentationCallback(meshIdentifier)
                }
            }
        }

        private let statsSink: StatsSink

        private let onFrame:
            @Sendable (GModMetalFrameRequest) -> Void

        private let worldFramePresentationSink: WorldFramePresentationSink

        private let viewportLock = NSLock()

        private var reportedViewportDimensions:
            GModMetalViewportDimensions?

        private let engine =
            GMEngine()

        private var commandQueue:
            MTLCommandQueue?

        private var worldPipeline:
            MTLRenderPipelineState?

        private var worldTexturedPipeline:
            MTLRenderPipelineState?

        private var worldLightmappedPipeline:
            MTLRenderPipelineState?

        private var worldTexturedLightmappedPipeline:
            MTLRenderPipelineState?

        private var worldMissingMaterialPipeline:
            MTLRenderPipelineState?

        private var dynamicEntityTexturedPipeline:
            MTLRenderPipelineState?

        private var dynamicEntityMissingMaterialPipeline:
            MTLRenderPipelineState?

        private var worldSkyboxPipeline:
            MTLRenderPipelineState?

        private var worldWaterSolidPipeline:
            MTLRenderPipelineState?

        private var worldWaterNormalPipeline:
            MTLRenderPipelineState?

        private var surfaceSolidPipeline:
            MTLRenderPipelineState?

        private var surfaceTexturedPipeline:
            MTLRenderPipelineState?

        private var depthState:
            MTLDepthStencilState?

        private var surfaceDepthState:
            MTLDepthStencilState?

        private var skyboxDepthState:
            MTLDepthStencilState?

        private var waterDepthState:
            MTLDepthStencilState?

        private var surfaceSamplerStates:
            [GModMetalSurfaceSamplerConfiguration: MTLSamplerState] = [:]

        private var worldSamplerState:
            MTLSamplerState?

        private var worldLightmapSamplerState:
            MTLSamplerState?

        private var skyboxSamplerState:
            MTLSamplerState?

        private var worldSamplerStates:
            [GModMetalWorldSamplerConfiguration: MTLSamplerState] = [:]

        private let pendingSceneLock = NSLock()

        private enum PendingWorldScene {
            case replace(GModMetalWorldScene)
            case clear
        }

        private enum PendingSurfaceScene {
            case replace(GModMetalSurfaceScene)
            case clear
        }

        private enum PendingDynamicEntityScene {
            case replace(GModMetalDynamicEntityScene)
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
            let uv: SIMD2<Float>
            let lightmapUV: SIMD2<Float>
        }

        private struct WorldUniforms {
            let viewProjection: simd_float4x4
            let lightDirection: SIMD4<Float>
        }

        private struct WorldWaterUniforms {
            /// Premultiplied fog color and fallback alpha.
            let fogColorAndAlpha: SIMD4<Float>
            /// Unit scroll direction, real VMT rate, and frozen Source time.
            let scrollDirectionRateAndTime: SIMD4<Float>
        }

        /// Resource-local Studio vertex. The entity pose is supplied separately
        /// so transform-only publications never rebuild or upload geometry.
        private struct DynamicEntityGPUVertex {
            let position: SIMD4<Float>
            let normal: SIMD4<Float>
            let uv: SIMD2<Float>
        }

        private struct DynamicEntityTransformUniforms {
            let metalXAxis: SIMD4<Float>
            let metalYAxis: SIMD4<Float>
            let metalZAxis: SIMD4<Float>
            let metalTranslation: SIMD4<Float>
        }

        private struct CachedDynamicEntityGeometry {
            let resourceID: GModMetalDynamicEntityResourceID
            let vertexCount: Int
            let indexCount: Int
            let byteCount: Int
            let vertexBuffer: MTLBuffer
            let indexBuffer: MTLBuffer
        }

        private struct DynamicEntityTextureKey: Hashable {
            let bitmapCacheIdentifier: String
        }

        private struct CachedDynamicEntityTexture {
            let bitmap: GModMetalSurfaceBitmap
            let byteCount: Int
            let texture: MTLTexture
        }

        private struct DynamicEntityGeometryFailure {
            let resourceID: GModMetalDynamicEntityResourceID
            let reason: String
        }

        private struct DynamicEntityTextureFailure {
            let bitmap: GModMetalSurfaceBitmap
            let reason: String
        }

        private enum DynamicEntitySceneIssue: CustomStringConvertible {
            case staleGeneration(
                received: GModMetalDynamicEntitySceneGeneration,
                active: GModMetalDynamicEntitySceneGeneration
            )
            case staleRevision(received: UInt64, active: UInt64)
            case geometryCapacity(String)
            case geometryUpload(
                resourceID: GModMetalDynamicEntityResourceID,
                reason: String
            )
            case textureUpload(key: DynamicEntityTextureKey, reason: String)

            var description: String {
                switch self {
                case let .staleGeneration(received, active):
                    return "ignored stale dynamic generation " +
                        "\(Self.label(received)); active is \(Self.label(active))"
                case let .staleRevision(received, active):
                    return "ignored stale dynamic revision \(received); " +
                        "active is \(active)"
                case let .geometryCapacity(reason):
                    return reason
                case let .geometryUpload(resourceID, reason):
                    return "\(Self.resourceLabel(resourceID)): \(reason)"
                case let .textureUpload(key, reason):
                    return "texture \(key.bitmapCacheIdentifier): \(reason)"
                }
            }

            private static func label(
                _ generation: GModMetalDynamicEntitySceneGeneration
            ) -> String {
                "\(generation.application)/\(generation.lane)/" +
                    "\(generation.sourceConnection.rawValue)"
            }

            private static func resourceLabel(
                _ id: GModMetalDynamicEntityResourceID
            ) -> String {
                "\(id.normalizedModelPath)#\(id.checksum):" +
                    "body=\(id.bodyValue):skin=\(id.skinFamilyIndex)"
            }
        }

        private enum DynamicEntityGPUCachePolicy {
            static let maximumGeometryByteCount = 128 * 1_024 * 1_024
            static let maximumTextureCount = 512
            static let maximumTextureByteCount = 64 * 1_024 * 1_024
        }

        private struct DynamicEntityUploadBudget {
            static let maximumResourceCount = 1
            static let maximumByteCount = 16 * 1_024 * 1_024

            private(set) var remainingResourceCount = maximumResourceCount
            private(set) var remainingByteCount = maximumByteCount

            mutating func reserve(byteCount: Int) -> Bool {
                guard byteCount >= 0, remainingResourceCount > 0 else {
                    return false
                }
                if byteCount > remainingByteCount {
                    // A resource larger than the ordinary per-frame allowance
                    // is admitted alone so retained data cannot stall forever.
                    guard remainingResourceCount == Self.maximumResourceCount,
                          remainingByteCount == Self.maximumByteCount else {
                        return false
                    }
                    remainingResourceCount = 0
                    remainingByteCount = 0
                    return true
                }
                remainingResourceCount -= 1
                remainingByteCount -= byteCount
                return true
            }
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

        private struct CachedWorldLightmap {
            let identifier: String
            let width: Int
            let height: Int
            let byteCount: Int
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
            case textureCoordinateArrayMismatch
            case lightmapTextureCoordinateArrayMismatch
            case emptyIndices
            case incompleteTriangle(indexCount: Int)
            case invalidPosition(index: Int)
            case invalidNormal(index: Int)
            case zeroNormal(index: Int)
            case invalidIndex(index: UInt32, vertexCount: Int)
            case invalidTextureCoordinate(index: Int)
            case invalidLightmapTextureCoordinate(index: Int)
            case invalidMaterialRange(index: Int)
            case invalidSkyboxRanges
            case invalidSky3DMetadata
            case invalidWaterMaterialRange(index: Int)
            case invalidCameraEye
            case invalidCameraForward
            case zeroCameraForward
            case invalidCameraUp
            case degenerateCameraBasis
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
                case .textureCoordinateArrayMismatch:
                    return "position/texture-coordinate counts differ"
                case .lightmapTextureCoordinateArrayMismatch:
                    return "position/lightmap-coordinate counts differ"
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
                case let .invalidTextureCoordinate(index):
                    return "texture coordinate \(index) is non-finite"
                case let .invalidLightmapTextureCoordinate(index):
                    return "lightmap coordinate \(index) is outside finite 0...1"
                case let .invalidMaterialRange(index):
                    return "material range \(index) is invalid or overlaps the index buffer"
                case .invalidSkyboxRanges:
                    return "skybox ranges must contain one named set of six unique faces"
                case .invalidSky3DMetadata:
                    return "3D sky ranges require finite sky_camera origin and positive scale"
                case let .invalidWaterMaterialRange(index):
                    return "water material range \(index) contains non-finite or mismatched Source inputs"
                case .invalidCameraEye:
                    return "camera eye is non-finite"
                case .invalidCameraForward:
                    return "camera forward is non-finite"
                case .zeroCameraForward:
                    return "camera forward has zero length"
                case .invalidCameraUp:
                    return "camera up is non-finite"
                case .degenerateCameraBasis:
                    return "camera forward and up do not form a basis"
                case .vertexBufferAllocationFailed:
                    return "Metal vertex-buffer allocation failed"
                case .indexBufferAllocationFailed:
                    return "Metal index-buffer allocation failed"
                }
            }
        }

        private enum WorldLightmapTextureError: Error, CustomStringConvertible {
            case emptyIdentifier
            case invalidDimensions(width: Int, height: Int)
            case capacityExceeded(width: Int, height: Int, byteCount: Int)
            case byteCountMismatch(actual: Int, expected: Int)
            case textureAllocationFailed

            var description: String {
                switch self {
                case .emptyIdentifier:
                    return "lightmap atlas identifier is empty"
                case let .invalidDimensions(width, height):
                    return "lightmap atlas dimensions are invalid (\(width)x\(height))"
                case let .capacityExceeded(width, height, byteCount):
                    return "lightmap atlas \(width)x\(height) / \(byteCount) bytes exceeds " +
                        "the \(GModMetalWorldLightmapAtlas.maximumWidth)x" +
                        "\(GModMetalWorldLightmapAtlas.maximumHeight) / " +
                        "\(GModMetalWorldLightmapAtlas.maximumByteCount)-byte renderer cap"
                case let .byteCountMismatch(actual, expected):
                    return "lightmap atlas has \(actual) bytes; expected \(expected)"
                case .textureAllocationFailed:
                    return "Metal lightmap texture allocation failed"
                }
            }
        }

        private var pendingWorldScene:
            PendingWorldScene?

        private var pendingSurfaceScene:
            PendingSurfaceScene?

        private var pendingDynamicEntityScene:
            PendingDynamicEntityScene?

        /// Accessed only by MTKView's serialized draw callback.
        private var activeWorldScene:
            GModMetalWorldScene?

        /// Accessed only by MTKView's serialized draw callback.
        private var activeDynamicEntityScene:
            GModMetalDynamicEntityScene?

        private var cachedDynamicEntityGeometry:
            [GModMetalDynamicEntityResourceID: CachedDynamicEntityGeometry] = [:]

        private var cachedDynamicEntityGeometryByteCount = 0

        private var dynamicEntityGeometryFailures:
            [GModMetalDynamicEntityResourceID: DynamicEntityGeometryFailure] = [:]

        private var cachedDynamicEntityTextures:
            [DynamicEntityTextureKey: CachedDynamicEntityTexture] = [:]

        private var cachedDynamicEntityTextureOrder:
            [DynamicEntityTextureKey] = []

        private var cachedDynamicEntityTextureByteCount = 0

        private var dynamicEntityTextureFailures:
            [DynamicEntityTextureKey: DynamicEntityTextureFailure] = [:]

        private var dynamicEntitySceneIssue: DynamicEntitySceneIssue?

        private var lastDynamicEntityInstanceDrawCount = 0

        private var lastDynamicEntityRangeDrawCount = 0

        private var lastDynamicEntityCheckerRangeCount = 0

        /// Accessed only by MTKView's serialized draw callback.
        private var cachedWorldMesh:
            CachedWorldMesh?

        private var cachedWorldTextures:
            [String: CachedSurfaceTexture] = [:]

        private var cachedWorldLightmap:
            CachedWorldLightmap?

        private var worldSceneIssue:
            String?

        private var worldLightmapIssue:
            String?

        private var rendererSetupFailureReason:
            GModMetalWorldRendererFailureReason?

        private var worldTextureUploadFailureReason:
            GModMetalWorldRendererFailureReason?

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

        private var lastWorldTexturedRangeCount = 0

        private var lastWorldMissingMaterialRangeCount = 0

        private var lastWorldPendingTextureRangeCount = 0

        private var lastWorldLightmappedRangeCount = 0

        private var lastSkyboxRenderedFaceCount = 0

        private var lastSkyboxMissingFaceCount = 0

        private var lastSkyboxPendingFaceCount = 0

        private var lastWaterRenderedRangeCount = 0

        private var lastWaterNormalMappedRangeCount = 0

        private var lastWaterMissingMaterialRangeCount = 0

        private var lastWaterPendingNormalRangeCount = 0

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
            dynamicEntityScene: GModMetalDynamicEntityScene? = nil,
            surfaceScene: GModMetalSurfaceScene? = nil,
            onFrame: @escaping @Sendable (GModMetalFrameRequest) -> Void,
            onWorldFrameEvent: @escaping @Sendable
                (GModMetalWorldFrameEvent) -> Void,
            onWorldFramePresented: @escaping @Sendable (String) -> Void
        ) {
            statsSink = StatsSink(stats: stats)
            self.onFrame = onFrame
            worldFramePresentationSink = WorldFramePresentationSink(
                eventCallback: onWorldFrameEvent,
                legacyPresentationCallback: onWorldFramePresented
            )
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
            if let dynamicEntityScene {
                pendingDynamicEntityScene = .replace(dynamicEntityScene)
            } else {
                pendingDynamicEntityScene = .clear
            }
        }

        func setup(
            device: MTLDevice,
            colorPixelFormat: MTLPixelFormat,
            depthPixelFormat: MTLPixelFormat
        ) {

            rendererSetupFailureReason = nil

            deviceName =
                device.name

            guard
                let queue =
                    device.makeCommandQueue()
            else {

                recordRendererSetupFailure(
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
                let worldVertexFunction =
                        library.makeFunction(
                            name:
                                "worldVertexMain"
                        ),

                    let dynamicEntityVertexFunction =
                        library.makeFunction(
                            name:
                                "dynamicEntityVertexMain"
                        ),

                    let worldFragmentFunction =
                        library.makeFunction(
                            name:
                                "worldFragmentMain"
                        ),

                    let worldTexturedFragmentFunction =
                        library.makeFunction(
                            name:
                                "worldTexturedFragmentMain"
                        ),

                    let worldLightmappedFragmentFunction =
                        library.makeFunction(
                            name:
                                "worldLightmappedFragmentMain"
                        ),

                    let worldTexturedLightmappedFragmentFunction =
                        library.makeFunction(
                            name:
                                "worldTexturedLightmappedFragmentMain"
                        ),

                    let worldMissingMaterialFragmentFunction =
                        library.makeFunction(
                            name:
                                "worldMissingMaterialFragmentMain"
                        ),

                    let worldSkyboxFragmentFunction =
                        library.makeFunction(
                            name:
                                "worldSkyboxFragmentMain"
                        ),

                    let worldWaterSolidFragmentFunction =
                        library.makeFunction(
                            name:
                                "worldWaterSolidFragmentMain"
                        ),

                    let worldWaterNormalFragmentFunction =
                        library.makeFunction(
                            name:
                                "worldWaterNormalFragmentMain"
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

                    recordRendererSetupFailure(
                        "Metal shader functions missing"
                    )

                    return
                }

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

                let worldTexturedDescriptor =
                    MTLRenderPipelineDescriptor()
                worldTexturedDescriptor.vertexFunction = worldVertexFunction
                worldTexturedDescriptor.fragmentFunction =
                    worldTexturedFragmentFunction
                worldTexturedDescriptor.colorAttachments[0].pixelFormat =
                    colorPixelFormat
                worldTexturedDescriptor.depthAttachmentPixelFormat =
                    depthPixelFormat
                worldTexturedPipeline = try device.makeRenderPipelineState(
                    descriptor: worldTexturedDescriptor
                )

                let worldLightmappedDescriptor = MTLRenderPipelineDescriptor()
                worldLightmappedDescriptor.vertexFunction = worldVertexFunction
                worldLightmappedDescriptor.fragmentFunction =
                    worldLightmappedFragmentFunction
                worldLightmappedDescriptor.colorAttachments[0].pixelFormat =
                    colorPixelFormat
                worldLightmappedDescriptor.depthAttachmentPixelFormat =
                    depthPixelFormat
                worldLightmappedPipeline = try device.makeRenderPipelineState(
                    descriptor: worldLightmappedDescriptor
                )

                let worldTexturedLightmappedDescriptor =
                    MTLRenderPipelineDescriptor()
                worldTexturedLightmappedDescriptor.vertexFunction = worldVertexFunction
                worldTexturedLightmappedDescriptor.fragmentFunction =
                    worldTexturedLightmappedFragmentFunction
                worldTexturedLightmappedDescriptor.colorAttachments[0].pixelFormat =
                    colorPixelFormat
                worldTexturedLightmappedDescriptor.depthAttachmentPixelFormat =
                    depthPixelFormat
                worldTexturedLightmappedPipeline = try device.makeRenderPipelineState(
                    descriptor: worldTexturedLightmappedDescriptor
                )

                let worldMissingDescriptor = MTLRenderPipelineDescriptor()
                worldMissingDescriptor.vertexFunction = worldVertexFunction
                worldMissingDescriptor.fragmentFunction =
                    worldMissingMaterialFragmentFunction
                worldMissingDescriptor.colorAttachments[0].pixelFormat =
                    colorPixelFormat
                worldMissingDescriptor.depthAttachmentPixelFormat =
                    depthPixelFormat
                worldMissingMaterialPipeline = try device.makeRenderPipelineState(
                    descriptor: worldMissingDescriptor
                )

                let dynamicEntityTexturedDescriptor =
                    MTLRenderPipelineDescriptor()
                dynamicEntityTexturedDescriptor.vertexFunction =
                    dynamicEntityVertexFunction
                dynamicEntityTexturedDescriptor.fragmentFunction =
                    worldTexturedFragmentFunction
                dynamicEntityTexturedDescriptor.colorAttachments[0].pixelFormat =
                    colorPixelFormat
                dynamicEntityTexturedDescriptor.depthAttachmentPixelFormat =
                    depthPixelFormat
                dynamicEntityTexturedPipeline = try device.makeRenderPipelineState(
                    descriptor: dynamicEntityTexturedDescriptor
                )

                let dynamicEntityMissingDescriptor =
                    MTLRenderPipelineDescriptor()
                dynamicEntityMissingDescriptor.vertexFunction =
                    dynamicEntityVertexFunction
                dynamicEntityMissingDescriptor.fragmentFunction =
                    worldMissingMaterialFragmentFunction
                dynamicEntityMissingDescriptor.colorAttachments[0].pixelFormat =
                    colorPixelFormat
                dynamicEntityMissingDescriptor.depthAttachmentPixelFormat =
                    depthPixelFormat
                dynamicEntityMissingMaterialPipeline =
                    try device.makeRenderPipelineState(
                        descriptor: dynamicEntityMissingDescriptor
                    )

                let worldSkyboxDescriptor = MTLRenderPipelineDescriptor()
                worldSkyboxDescriptor.vertexFunction = worldVertexFunction
                worldSkyboxDescriptor.fragmentFunction = worldSkyboxFragmentFunction
                worldSkyboxDescriptor.colorAttachments[0].pixelFormat =
                    colorPixelFormat
                worldSkyboxDescriptor.depthAttachmentPixelFormat =
                    depthPixelFormat
                worldSkyboxPipeline = try device.makeRenderPipelineState(
                    descriptor: worldSkyboxDescriptor
                )

                let worldWaterSolidDescriptor =
                    Self.makeWorldWaterPipelineDescriptor(
                        vertexFunction: worldVertexFunction,
                        fragmentFunction: worldWaterSolidFragmentFunction,
                        colorPixelFormat: colorPixelFormat,
                        depthPixelFormat: depthPixelFormat
                    )
                worldWaterSolidPipeline = try device.makeRenderPipelineState(
                    descriptor: worldWaterSolidDescriptor
                )

                let worldWaterNormalDescriptor =
                    Self.makeWorldWaterPipelineDescriptor(
                        vertexFunction: worldVertexFunction,
                        fragmentFunction: worldWaterNormalFragmentFunction,
                        colorPixelFormat: colorPixelFormat,
                        depthPixelFormat: depthPixelFormat
                    )
                worldWaterNormalPipeline = try device.makeRenderPipelineState(
                    descriptor: worldWaterNormalDescriptor
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
                    recordRendererSetupFailure(
                        "Failed to create Metal depth state"
                    )
                    return
                }

                self.depthState = depthState

                let skyboxDepthDescriptor = MTLDepthStencilDescriptor()
                skyboxDepthDescriptor.depthCompareFunction =
                    GModMetalSkyboxRenderContract.depthCompareAlwaysPasses
                        ? .always
                        : .less
                skyboxDepthDescriptor.isDepthWriteEnabled =
                    GModMetalSkyboxRenderContract.depthWritesEnabled
                guard let skyboxDepthState = device.makeDepthStencilState(
                    descriptor: skyboxDepthDescriptor
                ) else {
                    recordRendererSetupFailure(
                        "Failed to create Metal skybox depth state"
                    )
                    return
                }
                self.skyboxDepthState = skyboxDepthState

                let waterDepthDescriptor = MTLDepthStencilDescriptor()
                waterDepthDescriptor.depthCompareFunction = .less
                waterDepthDescriptor.isDepthWriteEnabled = false
                guard let waterDepthState = device.makeDepthStencilState(
                    descriptor: waterDepthDescriptor
                ) else {
                    recordRendererSetupFailure(
                        "Failed to create Metal water depth state"
                    )
                    return
                }
                self.waterDepthState = waterDepthState

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
                    recordRendererSetupFailure(
                        "Failed to create Metal surface depth state"
                    )
                    return
                }

                self.surfaceDepthState = surfaceDepthState

                var surfaceSamplerStates:
                    [GModMetalSurfaceSamplerConfiguration: MTLSamplerState] = [:]
                for configuration in
                    GModMetalSurfaceSamplerConfiguration.allSourceConfigurations {
                    let samplerDescriptor = MTLSamplerDescriptor()
                    samplerDescriptor.minFilter = configuration.minification == .point
                        ? .nearest
                        : .linear
                    samplerDescriptor.magFilter = configuration.magnification == .point
                        ? .nearest
                        : .linear
                    samplerDescriptor.mipFilter = .notMipmapped
                    samplerDescriptor.maxAnisotropy = configuration.maximumAnisotropy
                    samplerDescriptor.sAddressMode = .clampToEdge
                    samplerDescriptor.tAddressMode = .clampToEdge
                    guard let samplerState = device.makeSamplerState(
                        descriptor: samplerDescriptor
                    ) else {
                        recordRendererSetupFailure(
                            "Failed to create Metal surface sampler " +
                                "\(configuration)"
                        )
                        return
                    }
                    surfaceSamplerStates[configuration] = samplerState
                }
                self.surfaceSamplerStates = surfaceSamplerStates

                let worldSamplerDescriptor = MTLSamplerDescriptor()
                worldSamplerDescriptor.minFilter = .linear
                worldSamplerDescriptor.magFilter = .linear
                worldSamplerDescriptor.mipFilter = .notMipmapped
                worldSamplerDescriptor.sAddressMode = .repeat
                worldSamplerDescriptor.tAddressMode = .repeat
                guard let worldSamplerState = device.makeSamplerState(
                    descriptor: worldSamplerDescriptor
                ) else {
                    recordRendererSetupFailure(
                        "Failed to create Metal world sampler"
                    )
                    return
                }
                self.worldSamplerState = worldSamplerState

                let worldLightmapSamplerDescriptor = MTLSamplerDescriptor()
                worldLightmapSamplerDescriptor.minFilter = .linear
                worldLightmapSamplerDescriptor.magFilter = .linear
                worldLightmapSamplerDescriptor.mipFilter = .notMipmapped
                worldLightmapSamplerDescriptor.sAddressMode = .clampToEdge
                worldLightmapSamplerDescriptor.tAddressMode = .clampToEdge
                guard let worldLightmapSamplerState = device.makeSamplerState(
                    descriptor: worldLightmapSamplerDescriptor
                ) else {
                    recordRendererSetupFailure(
                        "Failed to create Metal world lightmap sampler"
                    )
                    return
                }
                self.worldLightmapSamplerState = worldLightmapSamplerState

                let skyboxSamplerDescriptor = MTLSamplerDescriptor()
                skyboxSamplerDescriptor.minFilter = .linear
                skyboxSamplerDescriptor.magFilter = .linear
                skyboxSamplerDescriptor.mipFilter = .notMipmapped
                skyboxSamplerDescriptor.sAddressMode = .clampToEdge
                skyboxSamplerDescriptor.tAddressMode = .clampToEdge
                guard let skyboxSamplerState = device.makeSamplerState(
                    descriptor: skyboxSamplerDescriptor
                ) else {
                    recordRendererSetupFailure(
                        "Failed to create Metal skybox sampler"
                    )
                    return
                }
                self.skyboxSamplerState = skyboxSamplerState

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

                recordRendererSetupFailure(
                    "Metal pipeline creation failed: \(error)"
                )
            }
        }

        private func recordRendererSetupFailure(_ detail: String) {
            rendererSetupFailureReason = .setupFailed(detail)
            publish(detail)
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

        /// Atomically replaces renderer inputs so a SwiftUI update cannot pair
        /// a new world camera with an older entity or Surface publication.
        func submit(
            worldScene: GModMetalWorldScene?,
            dynamicEntityScene: GModMetalDynamicEntityScene?,
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
            if let dynamicEntityScene {
                pendingDynamicEntityScene = .replace(dynamicEntityScene)
            } else {
                pendingDynamicEntityScene = .clear
            }
            pendingSceneLock.unlock()
        }

        func submit(
            worldScene: GModMetalWorldScene?,
            surfaceScene: GModMetalSurfaceScene?
        ) {
            submit(
                worldScene: worldScene,
                dynamicEntityScene: nil,
                surfaceScene: surfaceScene
            )
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
            dynamicEntity: PendingDynamicEntityScene?,
            surface: PendingSurfaceScene?
        ) {
            pendingSceneLock.lock()
            let result = (
                pendingWorldScene,
                pendingDynamicEntityScene,
                pendingSurfaceScene
            )
            pendingWorldScene = nil
            pendingDynamicEntityScene = nil
            pendingSurfaceScene = nil
            pendingSceneLock.unlock()
            return result
        }

        private func applyPendingDynamicEntityScene(
            _ pending: PendingDynamicEntityScene?
        ) {
            guard let pending else { return }
            guard case let .replace(scene) = pending else {
                activeDynamicEntityScene = nil
                resetDynamicEntityCaches()
                dynamicEntitySceneIssue = nil
                lastDynamicEntityInstanceDrawCount = 0
                lastDynamicEntityRangeDrawCount = 0
                lastDynamicEntityCheckerRangeCount = 0
                return
            }
            guard scene.retainedGeometryByteCount <=
                    DynamicEntityGPUCachePolicy.maximumGeometryByteCount else {
                dynamicEntitySceneIssue =
                    .geometryCapacity(
                        "dynamic geometry publication exceeds 128 MiB renderer cap"
                    )
                return
            }

            if let active = activeDynamicEntityScene {
                if active.generation == scene.generation {
                    guard scene.revision > active.revision else {
                        if scene.revision < active.revision {
                            dynamicEntitySceneIssue = .staleRevision(
                                received: scene.revision,
                                active: active.revision
                            )
                        }
                        return
                    }
                    activeDynamicEntityScene = scene
                    pruneDynamicEntityCaches(for: scene)
                } else {
                    guard !Self.dynamicEntityGeneration(
                        scene.generation,
                        precedes: active.generation
                    ) else {
                        dynamicEntitySceneIssue = .staleGeneration(
                            received: scene.generation,
                            active: active.generation
                        )
                        return
                    }
                    resetDynamicEntityCaches()
                    activeDynamicEntityScene = scene
                }
            } else {
                resetDynamicEntityCaches()
                activeDynamicEntityScene = scene
            }
            dynamicEntitySceneIssue = nil
            lastDynamicEntityInstanceDrawCount = 0
            lastDynamicEntityRangeDrawCount = 0
            lastDynamicEntityCheckerRangeCount = 0
        }

        private static func dynamicEntityGeneration(
            _ lhs: GModMetalDynamicEntitySceneGeneration,
            precedes rhs: GModMetalDynamicEntitySceneGeneration
        ) -> Bool {
            if lhs.application != rhs.application {
                return lhs.application < rhs.application
            }
            if lhs.lane != rhs.lane { return lhs.lane < rhs.lane }
            return lhs.sourceConnection.rawValue < rhs.sourceConnection.rawValue
        }

        private func applyPendingWorldScene(
            _ pending: PendingWorldScene?,
            device: MTLDevice
        ) {
            guard let pending else { return }

            switch pending {
            case .clear:
                activeWorldScene = nil
                cachedWorldTextures.removeAll(keepingCapacity: true)
                cachedWorldLightmap = nil
                worldTextureUploadFailureReason = nil
                lastWorldTexturedRangeCount = 0
                lastWorldMissingMaterialRangeCount = 0
                lastWorldPendingTextureRangeCount = 0
                lastWorldLightmappedRangeCount = 0
                lastSkyboxRenderedFaceCount = 0
                lastSkyboxMissingFaceCount = 0
                lastSkyboxPendingFaceCount = 0
                lastWaterRenderedRangeCount = 0
                lastWaterNormalMappedRangeCount = 0
                lastWaterMissingMaterialRangeCount = 0
                lastWaterPendingNormalRangeCount = 0
                worldSceneIssue = nil
                worldLightmapIssue = nil

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
                        cachedWorldTextures.removeAll(keepingCapacity: true)
                        cachedWorldLightmap = nil
                    }

                    let priorLightmapIssue = worldLightmapIssue
                    if let atlas = scene.lightmapAtlas {
                        let lightmapCacheMatches =
                            cachedWorldLightmap?.identifier == atlas.identifier &&
                            cachedWorldLightmap?.width == atlas.width &&
                            cachedWorldLightmap?.height == atlas.height &&
                            cachedWorldLightmap?.byteCount ==
                                atlas.linearRGBA16Float.count
                        if !lightmapCacheMatches {
                            do {
                                cachedWorldLightmap = try Self.makeWorldLightmapTexture(
                                    atlas,
                                    device: device
                                )
                                worldLightmapIssue = nil
                            } catch {
                                cachedWorldLightmap = nil
                                let detail = String(describing: error)
                                worldLightmapIssue = detail
                                activeWorldScene = nil
                                worldFramePresentationSink.fail(
                                    meshIdentifier: scene.meshIdentifier,
                                    reason: .lightmapUploadFailed(
                                        resourceIdentifier: atlas.identifier,
                                        detail: detail
                                    )
                                )
                                publish(
                                    "WORLD LIGHTMAP UPLOAD FAILED\n\(detail)"
                                )
                                return
                            }
                        } else {
                            worldLightmapIssue = nil
                        }
                    } else {
                        cachedWorldLightmap = nil
                        worldLightmapIssue = GModMetalWorldLightmapRenderContract
                            .fallbackReason(
                                for: scene.lightmapDiagnostics.atlasStatus
                        )
                    }
                    if let worldLightmapIssue,
                       worldLightmapIssue != priorLightmapIssue {
                        publish(
                            "WORLD LIGHTMAP FALLBACK\n\(worldLightmapIssue)"
                        )
                    }

                    activeWorldScene = scene
                    worldSceneIssue = nil
                } catch {
                    activeWorldScene = nil
                    let detail = String(describing: error)
                    worldSceneIssue = detail
                    worldFramePresentationSink.fail(
                        meshIdentifier: scene.meshIdentifier,
                        reason: .sceneRejected(detail)
                    )
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

        private func resetDynamicEntityCaches() {
            cachedDynamicEntityGeometry.removeAll(keepingCapacity: true)
            cachedDynamicEntityGeometryByteCount = 0
            dynamicEntityGeometryFailures.removeAll(keepingCapacity: true)
            cachedDynamicEntityTextures.removeAll(keepingCapacity: true)
            cachedDynamicEntityTextureOrder.removeAll(keepingCapacity: true)
            cachedDynamicEntityTextureByteCount = 0
            dynamicEntityTextureFailures.removeAll(keepingCapacity: true)
        }

        private func pruneDynamicEntityCaches(
            for scene: GModMetalDynamicEntityScene
        ) {
            let retainedResourceIDs = Set(scene.resources.map(\.id))
            for key in Array(cachedDynamicEntityGeometry.keys) where
                !retainedResourceIDs.contains(key) {
                removeCachedDynamicEntityGeometry(for: key)
            }
            dynamicEntityGeometryFailures =
                dynamicEntityGeometryFailures.filter {
                    retainedResourceIDs.contains($0.key)
                }

            let retainedTextureKeys: Set<DynamicEntityTextureKey> = Set(
                scene.resources.flatMap { resource in
                    resource.drawRanges.compactMap { range in
                        guard let bitmap = range.materialResolution.bitmap else {
                            return nil
                        }
                        return Self.dynamicEntityTextureKey(
                            bitmap: bitmap
                        )
                    }
                }
            )
            for key in Array(cachedDynamicEntityTextures.keys) where
                !retainedTextureKeys.contains(key) {
                removeCachedDynamicEntityTexture(for: key)
            }
            dynamicEntityTextureFailures =
                dynamicEntityTextureFailures.filter {
                    retainedTextureKeys.contains($0.key)
                }
        }

        private func removeCachedDynamicEntityGeometry(
            for resourceID: GModMetalDynamicEntityResourceID
        ) {
            guard let removed = cachedDynamicEntityGeometry.removeValue(
                forKey: resourceID
            ) else { return }
            cachedDynamicEntityGeometryByteCount = Swift.max(
                0,
                cachedDynamicEntityGeometryByteCount - removed.byteCount
            )
        }

        private func removeCachedDynamicEntityTexture(
            for key: DynamicEntityTextureKey
        ) {
            if let removed = cachedDynamicEntityTextures.removeValue(forKey: key) {
                cachedDynamicEntityTextureByteCount = Swift.max(
                    0,
                    cachedDynamicEntityTextureByteCount - removed.byteCount
                )
            }
            cachedDynamicEntityTextureOrder.removeAll { $0 == key }
        }

        private static func dynamicEntityTextureKey(
            bitmap: GModMetalSurfaceBitmap
        ) -> DynamicEntityTextureKey {
            DynamicEntityTextureKey(
                bitmapCacheIdentifier: bitmap.cacheIdentifier
            )
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

        private static func makeWorldWaterPipelineDescriptor(
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

            // Water fragments return premultiplied fog color. They read world
            // depth but never write it, so transparent surfaces cannot hide
            // later overlays or fight their paired `_beneath` material.
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

            let vertices = scene.metalPositions.indices.map { index in
                WorldGPUVertex(
                    position: SIMD4<Float>(scene.metalPositions[index], 1),
                    normal: SIMD4<Float>(scene.metalNormals[index], 0),
                    uv: scene.sourceTextureCoordinates[index],
                    lightmapUV: scene.sourceLightmapTextureCoordinates[index]
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

        private static func makeWorldLightmapTexture(
            _ atlas: GModMetalWorldLightmapAtlas,
            device: MTLDevice
        ) throws -> CachedWorldLightmap {
            guard !atlas.identifier.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty else {
                throw WorldLightmapTextureError.emptyIdentifier
            }
            guard atlas.width > 0, atlas.height > 0 else {
                throw WorldLightmapTextureError.invalidDimensions(
                    width: atlas.width,
                    height: atlas.height
                )
            }
            let pixels = atlas.width.multipliedReportingOverflow(by: atlas.height)
            let expectedBytes = pixels.partialValue.multipliedReportingOverflow(by: 8)
            let expectedByteCount = pixels.overflow || expectedBytes.overflow
                ? Int.max
                : expectedBytes.partialValue
            guard atlas.width <= GModMetalWorldLightmapAtlas.maximumWidth,
                  atlas.height <= GModMetalWorldLightmapAtlas.maximumHeight,
                  expectedByteCount <= GModMetalWorldLightmapAtlas.maximumByteCount
            else {
                throw WorldLightmapTextureError.capacityExceeded(
                    width: atlas.width,
                    height: atlas.height,
                    byteCount: expectedByteCount
                )
            }
            guard atlas.linearRGBA16Float.count == expectedByteCount else {
                throw WorldLightmapTextureError.byteCountMismatch(
                    actual: atlas.linearRGBA16Float.count,
                    expected: expectedByteCount
                )
            }

            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float,
                width: atlas.width,
                height: atlas.height,
                mipmapped: false
            )
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw WorldLightmapTextureError.textureAllocationFailed
            }
            atlas.linearRGBA16Float.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                texture.replace(
                    region: MTLRegionMake2D(0, 0, atlas.width, atlas.height),
                    mipmapLevel: 0,
                    withBytes: base,
                    bytesPerRow: atlas.width * 8
                )
            }
            return CachedWorldLightmap(
                identifier: atlas.identifier,
                width: atlas.width,
                height: atlas.height,
                byteCount: atlas.linearRGBA16Float.count,
                texture: texture
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
            guard scene.sourceTextureCoordinates.count == scene.sourcePositions.count else {
                throw WorldSceneError.textureCoordinateArrayMismatch
            }
            guard scene.sourceLightmapTextureCoordinates.count ==
                    scene.sourcePositions.count else {
                throw WorldSceneError.lightmapTextureCoordinateArrayMismatch
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
                let uv = scene.sourceTextureCoordinates[index]
                guard uv.x.isFinite, uv.y.isFinite else {
                    throw WorldSceneError.invalidTextureCoordinate(index: index)
                }
                let lightmapUV = scene.sourceLightmapTextureCoordinates[index]
                guard lightmapUV.x.isFinite, lightmapUV.y.isFinite,
                      scene.lightmapAtlas == nil || (
                        lightmapUV.x >= 0 && lightmapUV.x <= 1 &&
                        lightmapUV.y >= 0 && lightmapUV.y <= 1
                      ) else {
                    throw WorldSceneError.invalidLightmapTextureCoordinate(index: index)
                }
            }

            let vertexCount = scene.metalPositions.count
            for index in scene.indices where UInt64(index) >= UInt64(vertexCount) {
                throw WorldSceneError.invalidIndex(
                    index: index,
                    vertexCount: vertexCount
                )
            }
            var covered = 0
            for (index, range) in scene.materialRanges.enumerated() {
                guard range.firstIndex == covered,
                      range.indexCount > 0,
                      range.indexCount.isMultiple(of: 3),
                      range.firstIndex <= scene.indices.count,
                      range.indexCount <= scene.indices.count - range.firstIndex else {
                    throw WorldSceneError.invalidMaterialRange(index: index)
                }
                if let surface = range.waterSurface {
                    guard surface.surfaceZ.isFinite,
                          surface.minimumZ.isFinite,
                          surface.minimumZ <= surface.surfaceZ else {
                        throw WorldSceneError.invalidWaterMaterialRange(index: index)
                    }
                    if let material = range.waterMaterial {
                        guard !material.resourceIdentifier.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty,
                        material.fogColor.x.isFinite,
                        material.fogColor.y.isFinite,
                        material.fogColor.z.isFinite,
                        material.reflectionAmount?.isFinite ?? true,
                        material.refractionAmount?.isFinite ?? true,
                        material.fogStart?.isFinite ?? true,
                        material.fogEnd?.isFinite ?? true,
                        material.textureScrollRate?.isFinite ?? true,
                        material.textureScrollAngleDegrees?.isFinite ?? true else {
                            throw WorldSceneError.invalidWaterMaterialRange(index: index)
                        }
                    }
                } else if range.waterMaterial != nil {
                    throw WorldSceneError.invalidWaterMaterialRange(index: index)
                }
                covered += range.indexCount
            }
            guard scene.materialRanges.isEmpty || covered == scene.indices.count else {
                throw WorldSceneError.invalidMaterialRange(
                    index: scene.materialRanges.count
                )
            }
            if scene.materialRanges.contains(where: { $0.renderLayer == .sky3D }) {
                guard let sky3D = scene.sky3D,
                      isFinite(sky3D.sourceOrigin),
                      sky3D.scale.isFinite,
                      sky3D.scale > 0 else {
                    throw WorldSceneError.invalidSky3DMetadata
                }
            }
            let skyboxRanges = scene.materialRanges.filter {
                $0.skyboxFace != nil
            }
            if !skyboxRanges.isEmpty {
                let names = Set(skyboxRanges.compactMap(\.skyboxName))
                let faces = Set(skyboxRanges.compactMap(\.skyboxFace))
                guard names.count == 1,
                      skyboxRanges.count == GModMetalSkyboxFace.allCases.count,
                      faces.count == GModMetalSkyboxFace.allCases.count else {
                    throw WorldSceneError.invalidSkyboxRanges
                }
            }
        }

        func reportRendererFailure(
            meshIdentifier: String,
            reason: GModMetalWorldRendererFailureReason
        ) {
            worldFramePresentationSink.fail(
                meshIdentifier: meshIdentifier,
                reason: reason
            )
        }

        private struct WorldUploadBudget {
            static let maximumTextureCount = 1
            static let maximumByteCount = 16 * 1_024 * 1_024

            var remainingTextureCount = maximumTextureCount
            var remainingByteCount = maximumByteCount

            mutating func reserve(byteCount: Int) -> Bool {
                guard byteCount >= 0,
                      remainingTextureCount > 0 else { return false }
                if byteCount > remainingByteCount {
                    // A retained Source bitmap larger than the ordinary
                    // per-frame budget must still make forward progress. Admit
                    // it alone; the App-side 128 MiB retention policy remains
                    // the hard allocation boundary.
                    guard remainingTextureCount == Self.maximumTextureCount,
                          remainingByteCount == Self.maximumByteCount else {
                        return false
                    }
                    remainingTextureCount = 0
                    remainingByteCount = 0
                    return true
                }
                remainingTextureCount -= 1
                remainingByteCount -= byteCount
                return true
            }
        }

        private struct WorldDrawResult {
            let uploadedTextureCount: Int
            let requiredTextureCount: Int
            let failureReason: GModMetalWorldRendererFailureReason?

            var isReadyForPresentation: Bool {
                failureReason == nil &&
                    uploadedTextureCount == requiredTextureCount
            }
        }

        private func requiredWorldTextures(
            for scene: GModMetalWorldScene
        ) -> [String: GModMetalSurfaceBitmap] {
            var required: [String: GModMetalSurfaceBitmap] = [:]
            for range in scene.materialRanges {
                switch range.renderLayer {
                case .world:
                    break
                case .sky2D:
                    guard GModMetalSkyVisibilityRenderContract.draws2D(
                        scene.skyboxVisibility
                    ) else { continue }
                case .sky3D:
                    guard GModMetalSkyVisibilityRenderContract.draws3D(
                        scene.skyboxVisibility
                    ) else { continue }
                }
                if let bitmap = range.materialResolution.bitmap {
                    required[Self.worldTextureKey(
                        for: bitmap,
                        isSRGB: true
                    )] = bitmap
                }
                let waterCameraZ: Float
                if range.renderLayer == .sky3D, let sky3D = scene.sky3D {
                    waterCameraZ = GModMetalSky3DProjectionContract.sourceCameraEye(
                        worldEye: scene.cameraEye,
                        sky: sky3D
                    ).z
                } else {
                    waterCameraZ = scene.cameraEye.z
                }
                if let surface = range.waterSurface,
                   let material = range.waterMaterial,
                   GModMetalWaterRenderContract.shouldRender(
                       material,
                       surface: surface,
                       cameraZ: waterCameraZ
                   ),
                   let normalBitmap = material.normalBitmap {
                    required[Self.worldTextureKey(
                        for: normalBitmap,
                        isSRGB: false
                    )] = normalBitmap
                }
            }
            return required
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
            guard isFinite(scene.cameraUp), isFinite(scene.metalCameraUp) else {
                throw WorldSceneError.invalidCameraUp
            }
            let upLengthSquared = simd_length_squared(scene.metalCameraUp)
            let rightLengthSquared = simd_length_squared(simd_cross(
                scene.metalCameraForward,
                scene.metalCameraUp
            ))
            guard upLengthSquared.isFinite,
                  upLengthSquared > Float.ulpOfOne,
                  rightLengthSquared.isFinite,
                  rightLengthSquared > Float.ulpOfOne else {
                throw WorldSceneError.degenerateCameraBasis
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

            guard let device = view.device else {
                if let meshIdentifier = activeWorldScene?.meshIdentifier {
                    worldFramePresentationSink.fail(
                        meshIdentifier: meshIdentifier,
                        reason: .metalDeviceUnavailable
                    )
                }
                return
            }
            let pendingScenes = takePendingScenes()
            applyPendingWorldScene(pendingScenes.world, device: device)
            applyPendingDynamicEntityScene(pendingScenes.dynamicEntity)
            applyPendingSurfaceScene(pendingScenes.surface)

            if let scene = activeWorldScene,
               let rendererSetupFailureReason {
                worldFramePresentationSink.fail(
                    meshIdentifier: scene.meshIdentifier,
                    reason: rendererSetupFailureReason
                )
                return
            }

            guard
                let commandQueue,
                let worldPipeline,
                let worldTexturedPipeline,
                let worldLightmappedPipeline,
                let worldTexturedLightmappedPipeline,
                let worldMissingMaterialPipeline,
                let dynamicEntityTexturedPipeline,
                let dynamicEntityMissingMaterialPipeline,
                let worldSkyboxPipeline,
                let worldWaterSolidPipeline,
                let worldWaterNormalPipeline,
                let surfaceSolidPipeline,
                let surfaceTexturedPipeline,
                let depthState,
                let skyboxDepthState,
                let waterDepthState,
                let surfaceDepthState,
                !surfaceSamplerStates.isEmpty,
                let worldSamplerState,
                let worldLightmapSamplerState,
                let skyboxSamplerState
            else {
                if let meshIdentifier = activeWorldScene?.meshIdentifier {
                    worldFramePresentationSink.fail(
                        meshIdentifier: meshIdentifier,
                        reason: .setupFailed(
                            "required Metal renderer state is unavailable"
                        )
                    )
                }
                return
            }

            // A temporarily unavailable drawable is normal while UIKit is
            // resizing/backgrounding and is not a renderer failure.
            guard let descriptor = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable else {
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

            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                if let meshIdentifier = activeWorldScene?.meshIdentifier {
                    worldFramePresentationSink.fail(
                        meshIdentifier: meshIdentifier,
                        reason: .commandBufferCreationFailed
                    )
                }
                return
            }
            var storedSkyColor = false
            if let scene = activeWorldScene,
               let mesh = cachedWorldMesh,
               mesh.identifier == scene.meshIdentifier,
               mesh.vertexCount == scene.metalPositions.count,
               mesh.indexCount == scene.indices.count {
                worldTextureUploadFailureReason = nil
                // An iPad GPU may keep this attachment in tile memory until
                // the encoder ends. The following ordinary-world pass loads
                // the sky color, so make that inter-pass store explicit rather
                // than depending on the MTKView descriptor's transient
                // default and then mutating the same descriptor in place.
                descriptor.colorAttachments[0].storeAction = .store
                descriptor.depthAttachment.storeAction = .dontCare
                guard let skyEncoder = commandBuffer.makeRenderCommandEncoder(
                    descriptor: descriptor
                ) else {
                    worldFramePresentationSink.fail(
                        meshIdentifier: scene.meshIdentifier,
                        reason: .renderEncoderCreationFailed
                    )
                    return
                }
                skyEncoder.setCullMode(.none)
                drawWorldSky(
                    scene: scene,
                    mesh: mesh,
                    viewport: drawableViewport,
                    device: device,
                    solidPipeline: worldPipeline,
                    texturedPipeline: worldTexturedPipeline,
                    lightmappedPipeline: worldLightmappedPipeline,
                    texturedLightmappedPipeline: worldTexturedLightmappedPipeline,
                    missingMaterialPipeline: worldMissingMaterialPipeline,
                    skyboxPipeline: worldSkyboxPipeline,
                    waterSolidPipeline: worldWaterSolidPipeline,
                    waterNormalPipeline: worldWaterNormalPipeline,
                    worldDepthState: depthState,
                    skyboxDepthState: skyboxDepthState,
                    waterDepthState: waterDepthState,
                    worldSampler: worldSamplerState,
                    lightmapSampler: worldLightmapSamplerState,
                    skyboxSampler: skyboxSamplerState,
                    encoder: skyEncoder
                )
                skyEncoder.endEncoding()
                storedSkyColor = true
            } else {
                worldTextureUploadFailureReason = nil
            }
            // Metal copies a descriptor when an encoder is created, but an
            // independent value keeps the tile store/load boundary explicit
            // on physical iPad hardware. Sky depth is intentionally discarded;
            // Source starts the ordinary world with a fresh depth lifetime.
            let worldDescriptor = descriptor.copy() as! MTLRenderPassDescriptor
            if storedSkyColor {
                worldDescriptor.colorAttachments[0].loadAction = .load
            }
            worldDescriptor.colorAttachments[0].storeAction = .store
            worldDescriptor.depthAttachment.loadAction = .clear
            worldDescriptor.depthAttachment.storeAction = .dontCare
            guard let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: worldDescriptor
            ) else {
                if let meshIdentifier = activeWorldScene?.meshIdentifier {
                    worldFramePresentationSink.fail(
                        meshIdentifier: meshIdentifier,
                        reason: .renderEncoderCreationFailed
                    )
                }
                return
            }

            encoder.setDepthStencilState(depthState)
            encoder.setCullMode(.none)

            var encodedWorldIdentifier: String?
            if
                let scene = activeWorldScene,
                let mesh = cachedWorldMesh,
                mesh.identifier == scene.meshIdentifier,
                mesh.vertexCount == scene.metalPositions.count,
                mesh.indexCount == scene.indices.count
            {
                let drawResult = drawWorld(
                    scene: scene,
                    mesh: mesh,
                    viewport: drawableViewport,
                    device: device,
                    solidPipeline: worldPipeline,
                    texturedPipeline: worldTexturedPipeline,
                    lightmappedPipeline: worldLightmappedPipeline,
                    texturedLightmappedPipeline: worldTexturedLightmappedPipeline,
                    missingMaterialPipeline: worldMissingMaterialPipeline,
                    dynamicEntityTexturedPipeline: dynamicEntityTexturedPipeline,
                    dynamicEntityMissingMaterialPipeline:
                        dynamicEntityMissingMaterialPipeline,
                    skyboxPipeline: worldSkyboxPipeline,
                    waterSolidPipeline: worldWaterSolidPipeline,
                    waterNormalPipeline: worldWaterNormalPipeline,
                    worldDepthState: depthState,
                    skyboxDepthState: skyboxDepthState,
                    waterDepthState: waterDepthState,
                    worldSampler: worldSamplerState,
                    lightmapSampler: worldLightmapSamplerState,
                    skyboxSampler: skyboxSamplerState,
                    encoder: encoder
                )
                worldFramePresentationSink.publishProgress(
                    GModMetalWorldTextureUploadProgress(
                        meshIdentifier: scene.meshIdentifier,
                        uploadedTextureCount: drawResult.uploadedTextureCount,
                        requiredTextureCount: drawResult.requiredTextureCount
                    )
                )
                if let failureReason = drawResult.failureReason {
                    worldFramePresentationSink.fail(
                        meshIdentifier: scene.meshIdentifier,
                        reason: failureReason
                    )
                } else if drawResult.isReadyForPresentation {
                    encodedWorldIdentifier = scene.meshIdentifier
                }
            }

            if let surfaceScene = activeSurfaceScene {
                lastSurfaceDrawCount = drawSurface(
                    scene: surfaceScene,
                    device: device,
                    solidPipeline: surfaceSolidPipeline,
                    texturedPipeline: surfaceTexturedPipeline,
                    depthState: surfaceDepthState,
                    samplers: surfaceSamplerStates,
                    encoder: encoder
                )
            } else {
                lastSurfaceDrawCount = 0
                lastSurfaceDroppedDrawCount = 0
            }

            encoder.endEncoding()

            if let encodedWorldIdentifier,
               worldFramePresentationSink.reserve(encodedWorldIdentifier) {
                commandBuffer.addCompletedHandler {
                    [worldFramePresentationSink] completedBuffer in
                    worldFramePresentationSink.finish(
                        encodedWorldIdentifier,
                        succeeded: completedBuffer.status == .completed,
                        status: String(describing: completedBuffer.status),
                        errorDescription: completedBuffer.error.map {
                            String(describing: $0)
                        }
                    )
                }
            }

            commandBuffer.present(
                drawable
            )

            commandBuffer.commit()
        }

        /// Encodes Source's background passes into their own depth lifetime.
        /// The following ordinary-world encoder clears depth while loading the
        /// sky color, matching Source's 2D sky -> 3D sky -> world ordering.
        private func drawWorldSky(
            scene: GModMetalWorldScene,
            mesh: CachedWorldMesh,
            viewport: SIMD2<Int>,
            device: MTLDevice,
            solidPipeline: MTLRenderPipelineState,
            texturedPipeline: MTLRenderPipelineState,
            lightmappedPipeline: MTLRenderPipelineState,
            texturedLightmappedPipeline: MTLRenderPipelineState,
            missingMaterialPipeline: MTLRenderPipelineState,
            skyboxPipeline: MTLRenderPipelineState,
            waterSolidPipeline: MTLRenderPipelineState,
            waterNormalPipeline: MTLRenderPipelineState,
            worldDepthState: MTLDepthStencilState,
            skyboxDepthState: MTLDepthStencilState,
            waterDepthState: MTLDepthStencilState,
            worldSampler: MTLSamplerState,
            lightmapSampler: MTLSamplerState,
            skyboxSampler: MTLSamplerState,
            encoder: MTLRenderCommandEncoder
        ) {
            let width = Swift.max(1, viewport.x)
            let height = Swift.max(1, viewport.y)
            let sky2DProjection = Self.makePerspectiveMatrix(
                verticalFieldOfViewRadians: 75 * .pi / 180,
                aspect: Float(width) / Float(height),
                near: 1,
                far: 65_536
            )
            encoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
            var uploadBudget = WorldUploadBudget()

            func setUniforms(
                eye: SIMD3<Float>,
                projection: simd_float4x4
            ) {
                let view = Self.makeViewMatrix(
                    eye: eye,
                    forward: scene.metalCameraForward,
                    up: scene.metalCameraUp
                )
                var uniforms = WorldUniforms(
                    viewProjection: simd_mul(projection, view),
                    lightDirection: SIMD4<Float>(0.35, 0.80, 0.48, 0)
                )
                withUnsafeBytes(of: &uniforms) { bytes in
                    guard let address = bytes.baseAddress else { return }
                    encoder.setVertexBytes(address, length: bytes.count, index: 1)
                    encoder.setFragmentBytes(address, length: bytes.count, index: 1)
                }
            }
            func draw(_ range: GModMetalWorldMaterialRange) {
                encoder.drawIndexedPrimitives(
                    type: .triangle,
                    indexCount: range.indexCount,
                    indexType: .uint32,
                    indexBuffer: mesh.indexBuffer,
                    indexBufferOffset: range.firstIndex * MemoryLayout<UInt32>.stride
                )
            }

            let draws2DSky = GModMetalSkyVisibilityRenderContract.draws2D(
                scene.skyboxVisibility
            )
            let skyboxRanges = draws2DSky
                ? scene.materialRanges.filter { $0.renderLayer == .sky2D }
                : []
            setUniforms(
                eye: scene.metalSkyboxCameraEye,
                projection: sky2DProjection
            )
            encoder.setDepthStencilState(skyboxDepthState)
            encoder.setFragmentSamplerState(skyboxSampler, index: 0)
            var rendered = 0
            var missing = 0
            var pending = 0
            for range in skyboxRanges {
                guard let bitmap = range.bitmap else {
                    missing += 1
                    continue
                }
                guard let texture = worldTexture(
                    for: bitmap,
                    device: device,
                    uploadBudget: &uploadBudget
                ) else {
                    pending += 1
                    continue
                }
                encoder.setRenderPipelineState(skyboxPipeline)
                encoder.setFragmentTexture(texture, index: 0)
                if let configuration = range.samplerConfiguration,
                   let sampler = samplerStateForWorldTexture(
                       for: configuration,
                       device: device
                   ) {
                    encoder.setFragmentSamplerState(sampler, index: 0)
                }
                draw(range)
                rendered += 1
            }
            lastSkyboxRenderedFaceCount = rendered
            lastSkyboxMissingFaceCount = missing
            lastSkyboxPendingFaceCount = pending

            guard GModMetalSkyVisibilityRenderContract.draws3D(
                scene.skyboxVisibility
            ) else { return }

            let sky3DRanges = scene.materialRanges.filter {
                $0.renderLayer == .sky3D && $0.waterSurface == nil
            }
            let sky3DWaterRanges = scene.materialRanges.filter {
                $0.renderLayer == .sky3D && $0.waterSurface != nil
            }
            guard !sky3DRanges.isEmpty || !sky3DWaterRanges.isEmpty,
                  let sky3D = scene.sky3D else { return }
            let clipPlanes = GModMetalSky3DProjectionContract.bakedClipPlanes(
                scale: sky3D.scale
            )
            let sky3DProjection = Self.makePerspectiveMatrix(
                verticalFieldOfViewRadians: 75 * .pi / 180,
                aspect: Float(width) / Float(height),
                near: clipPlanes.near,
                far: clipPlanes.far
            )
            setUniforms(
                eye: scene.metalCameraEye,
                projection: sky3DProjection
            )
            encoder.setDepthStencilState(worldDepthState)
            encoder.setFragmentSamplerState(worldSampler, index: 0)
            let lightmapTexture: MTLTexture?
            if let atlas = scene.lightmapAtlas,
               let cachedWorldLightmap,
               cachedWorldLightmap.identifier == atlas.identifier,
               cachedWorldLightmap.width == atlas.width,
               cachedWorldLightmap.height == atlas.height,
               cachedWorldLightmap.byteCount == atlas.linearRGBA16Float.count {
                lightmapTexture = cachedWorldLightmap.texture
            } else {
                lightmapTexture = nil
            }
            encoder.setFragmentTexture(lightmapTexture, index: 1)
            encoder.setFragmentSamplerState(
                lightmapTexture == nil ? nil : lightmapSampler,
                index: 1
            )
            for range in sky3DRanges {
                if let bitmap = range.bitmap,
                   let texture = worldTexture(
                       for: bitmap,
                       device: device,
                       uploadBudget: &uploadBudget
                   ) {
                    encoder.setRenderPipelineState(
                        lightmapTexture == nil
                            ? texturedPipeline
                            : texturedLightmappedPipeline
                    )
                    encoder.setFragmentTexture(texture, index: 0)
                    if let configuration = range.samplerConfiguration,
                       let sampler = samplerStateForWorldTexture(
                           for: configuration,
                           device: device
                       ) {
                        encoder.setFragmentSamplerState(sampler, index: 0)
                    }
                } else if range.bitmap != nil {
                    encoder.setRenderPipelineState(
                        lightmapTexture == nil
                            ? solidPipeline
                            : lightmappedPipeline
                    )
                    encoder.setFragmentTexture(nil, index: 0)
                } else if range.materialName != nil {
                    encoder.setRenderPipelineState(missingMaterialPipeline)
                    encoder.setFragmentTexture(nil, index: 0)
                } else {
                    encoder.setRenderPipelineState(
                        lightmapTexture == nil
                            ? solidPipeline
                            : lightmappedPipeline
                    )
                    encoder.setFragmentTexture(nil, index: 0)
                }
                draw(range)
            }

            let skyCameraZ = GModMetalSky3DProjectionContract.sourceCameraEye(
                worldEye: scene.cameraEye,
                sky: sky3D
            ).z
            encoder.setDepthStencilState(waterDepthState)
            encoder.setFragmentSamplerState(worldSampler, index: 0)
            for range in sky3DWaterRanges {
                guard let surface = range.waterSurface,
                      let material = range.waterMaterial,
                      GModMetalWaterRenderContract.shouldRender(
                        material,
                        surface: surface,
                        cameraZ: skyCameraZ
                      ),
                      let alpha = GModMetalWaterRenderContract.fallbackAlpha(
                        material
                      ) else { continue }
                let angleRadians = (material.textureScrollAngleDegrees ?? 0) *
                    .pi / 180
                let direction = SIMD2<Float>(
                    cos(angleRadians),
                    sin(angleRadians)
                )
                var uniforms = WorldWaterUniforms(
                    fogColorAndAlpha: SIMD4<Float>(
                        material.fogColor * alpha,
                        alpha
                    ),
                    scrollDirectionRateAndTime: SIMD4<Float>(
                        direction.x,
                        direction.y,
                        material.textureScrollRate ?? 0,
                        scene.sourceFixedTime
                    )
                )
                withUnsafeBytes(of: &uniforms) { bytes in
                    guard let address = bytes.baseAddress else { return }
                    encoder.setFragmentBytes(
                        address,
                        length: bytes.count,
                        index: 2
                    )
                }
                if let normalBitmap = material.normalBitmap,
                   let normalTexture = worldTexture(
                    for: normalBitmap,
                    device: device,
                    uploadBudget: &uploadBudget,
                    isSRGB: false
                   ) {
                    encoder.setRenderPipelineState(waterNormalPipeline)
                    encoder.setFragmentTexture(normalTexture, index: 0)
                    let configuration = GModMetalWorldSamplerConfiguration(
                        bitmap: normalBitmap,
                        renderLayer: .sky3D
                    )
                    if let sampler = samplerStateForWorldTexture(
                        for: configuration,
                        device: device
                    ) {
                        encoder.setFragmentSamplerState(sampler, index: 0)
                    }
                } else {
                    encoder.setRenderPipelineState(waterSolidPipeline)
                    encoder.setFragmentTexture(nil, index: 0)
                }
                draw(range)
            }
        }

        private func drawWorld(
            scene: GModMetalWorldScene,
            mesh: CachedWorldMesh,
            viewport: SIMD2<Int>,
            device: MTLDevice,
            solidPipeline: MTLRenderPipelineState,
            texturedPipeline: MTLRenderPipelineState,
            lightmappedPipeline: MTLRenderPipelineState,
            texturedLightmappedPipeline: MTLRenderPipelineState,
            missingMaterialPipeline: MTLRenderPipelineState,
            dynamicEntityTexturedPipeline: MTLRenderPipelineState,
            dynamicEntityMissingMaterialPipeline: MTLRenderPipelineState,
            skyboxPipeline: MTLRenderPipelineState,
            waterSolidPipeline: MTLRenderPipelineState,
            waterNormalPipeline: MTLRenderPipelineState,
            worldDepthState: MTLDepthStencilState,
            skyboxDepthState: MTLDepthStencilState,
            waterDepthState: MTLDepthStencilState,
            worldSampler: MTLSamplerState,
            lightmapSampler: MTLSamplerState,
            skyboxSampler: MTLSamplerState,
            encoder: MTLRenderCommandEncoder
        ) -> WorldDrawResult {
            let width = Swift.max(1, viewport.x)
            let height = Swift.max(1, viewport.y)
            let aspect = Float(width) / Float(height)
            let projection = Self.makePerspectiveMatrix(
                verticalFieldOfViewRadians: 75 * .pi / 180,
                aspect: aspect,
                near: 1,
                far: 65_536
            )

            encoder.setVertexBuffer(
                mesh.vertexBuffer,
                offset: 0,
                index: 0
            )
            var uploadBudget = WorldUploadBudget()
            let ranges = scene.materialRanges.isEmpty
                ? [
                    GModMetalWorldMaterialRange(
                        materialName: nil,
                        firstIndex: 0,
                        indexCount: mesh.indexCount,
                        bitmap: nil
                    )
                ]
                : scene.materialRanges

            func setUniforms(eye: SIMD3<Float>) {
                let view = Self.makeViewMatrix(
                    eye: eye,
                    forward: scene.metalCameraForward,
                    up: scene.metalCameraUp
                )
                var uniforms = WorldUniforms(
                    viewProjection: simd_mul(projection, view),
                    lightDirection: SIMD4<Float>(0.35, 0.80, 0.48, 0)
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
            }

            func draw(_ range: GModMetalWorldMaterialRange) {
                encoder.drawIndexedPrimitives(
                    type: .triangle,
                    indexCount: range.indexCount,
                    indexType: .uint32,
                    indexBuffer: mesh.indexBuffer,
                    indexBufferOffset: range.firstIndex * MemoryLayout<UInt32>.stride
                )
            }

            setUniforms(eye: scene.metalCameraEye)
            encoder.setDepthStencilState(worldDepthState)
            encoder.setFragmentSamplerState(worldSampler, index: 0)
            let lightmapTexture: MTLTexture?
            if let atlas = scene.lightmapAtlas,
               let cachedWorldLightmap,
               cachedWorldLightmap.identifier == atlas.identifier,
               cachedWorldLightmap.width == atlas.width,
               cachedWorldLightmap.height == atlas.height,
               cachedWorldLightmap.byteCount == atlas.linearRGBA16Float.count {
                lightmapTexture = cachedWorldLightmap.texture
            } else {
                lightmapTexture = nil
            }
            encoder.setFragmentTexture(lightmapTexture, index: 1)
            encoder.setFragmentSamplerState(
                lightmapTexture == nil ? nil : lightmapSampler,
                index: 1
            )
            var texturedRangeCount = 0
            var missingRangeCount = 0
            var pendingRangeCount = 0
            var lightmappedRangeCount = 0
            for range in ranges where
                range.renderLayer == .world && range.waterSurface == nil {
                if let bitmap = range.bitmap {
                    if let texture = worldTexture(
                        for: bitmap,
                        device: device,
                        uploadBudget: &uploadBudget
                    ) {
                        encoder.setRenderPipelineState(
                            lightmapTexture == nil
                                ? texturedPipeline
                                : texturedLightmappedPipeline
                        )
                        encoder.setFragmentTexture(texture, index: 0)
                        if let configuration = range.samplerConfiguration,
                           let sampler = samplerStateForWorldTexture(
                               for: configuration,
                               device: device
                           ) {
                            encoder.setFragmentSamplerState(sampler, index: 0)
                        }
                        texturedRangeCount += 1
                        if lightmapTexture != nil {
                            lightmappedRangeCount += 1
                        }
                    } else {
                        // Upload deferral is temporary and is not reported as a
                        // missing Source asset.
                        encoder.setRenderPipelineState(
                            lightmapTexture == nil
                                ? solidPipeline
                                : lightmappedPipeline
                        )
                        encoder.setFragmentTexture(nil, index: 0)
                        pendingRangeCount += 1
                        if lightmapTexture != nil {
                            lightmappedRangeCount += 1
                        }
                    }
                } else if range.materialName != nil {
                    encoder.setRenderPipelineState(missingMaterialPipeline)
                    encoder.setFragmentTexture(nil, index: 0)
                    missingRangeCount += 1
                } else {
                    encoder.setRenderPipelineState(
                        lightmapTexture == nil
                            ? solidPipeline
                            : lightmappedPipeline
                    )
                    encoder.setFragmentTexture(nil, index: 0)
                    if lightmapTexture != nil {
                        lightmappedRangeCount += 1
                    }
                }
                draw(range)
            }

            // Source opaque entities share the ordinary-world depth lifetime:
            // they draw after opaque BSP and before translucent water.
            if let dynamicScene = activeDynamicEntityScene {
                drawDynamicEntities(
                    scene: dynamicScene,
                    device: device,
                    texturedPipeline: dynamicEntityTexturedPipeline,
                    missingMaterialPipeline:
                        dynamicEntityMissingMaterialPipeline,
                    depthState: worldDepthState,
                    encoder: encoder
                )
                // Water ranges are indexed against the BSP-local buffers.
                encoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
            } else {
                lastDynamicEntityInstanceDrawCount = 0
                lastDynamicEntityRangeDrawCount = 0
                lastDynamicEntityCheckerRangeCount = 0
            }

            encoder.setDepthStencilState(waterDepthState)
            encoder.setFragmentSamplerState(worldSampler, index: 0)
            var waterRenderedRangeCount = 0
            var waterNormalMappedRangeCount = 0
            var waterMissingMaterialRangeCount = 0
            var waterPendingNormalRangeCount = 0
            for range in ranges where
                range.renderLayer == .world && range.waterSurface != nil {
                guard let surface = range.waterSurface,
                      let material = range.waterMaterial else {
                    waterMissingMaterialRangeCount += 1
                    continue
                }
                guard GModMetalWaterRenderContract.shouldRender(
                    material,
                    surface: surface,
                    cameraZ: scene.cameraEye.z
                ) else {
                    continue
                }

                guard let alpha = GModMetalWaterRenderContract.fallbackAlpha(
                    material
                ) else {
                    waterMissingMaterialRangeCount += 1
                    continue
                }
                let angleRadians = (material.textureScrollAngleDegrees ?? 0) *
                    .pi / 180
                let direction = SIMD2<Float>(
                    cos(angleRadians),
                    sin(angleRadians)
                )
                var uniforms = WorldWaterUniforms(
                    fogColorAndAlpha: SIMD4<Float>(
                        material.fogColor * alpha,
                        alpha
                    ),
                    scrollDirectionRateAndTime: SIMD4<Float>(
                        direction.x,
                        direction.y,
                        material.textureScrollRate ?? 0,
                        scene.sourceFixedTime
                    )
                )
                withUnsafeBytes(of: &uniforms) { bytes in
                    guard let address = bytes.baseAddress else { return }
                    encoder.setFragmentBytes(
                        address,
                        length: bytes.count,
                        index: 2
                    )
                }

                if let normalBitmap = material.normalBitmap {
                    if let normalTexture = worldTexture(
                        for: normalBitmap,
                        device: device,
                        uploadBudget: &uploadBudget,
                        isSRGB: false
                    ) {
                        encoder.setRenderPipelineState(waterNormalPipeline)
                        encoder.setFragmentTexture(normalTexture, index: 0)
                        let configuration = GModMetalWorldSamplerConfiguration(
                            bitmap: normalBitmap,
                            renderLayer: range.renderLayer
                        )
                        if let sampler = samplerStateForWorldTexture(
                            for: configuration,
                            device: device
                        ) {
                            encoder.setFragmentSamplerState(sampler, index: 0)
                        }
                        waterNormalMappedRangeCount += 1
                    } else {
                        encoder.setRenderPipelineState(waterSolidPipeline)
                        encoder.setFragmentTexture(nil, index: 0)
                        waterPendingNormalRangeCount += 1
                    }
                } else {
                    encoder.setRenderPipelineState(waterSolidPipeline)
                    encoder.setFragmentTexture(nil, index: 0)
                }
                draw(range)
                waterRenderedRangeCount += 1
            }
            lastWorldTexturedRangeCount = texturedRangeCount
            lastWorldMissingMaterialRangeCount = missingRangeCount
            lastWorldPendingTextureRangeCount = pendingRangeCount
            lastWorldLightmappedRangeCount = lightmappedRangeCount
            lastWaterRenderedRangeCount = waterRenderedRangeCount
            lastWaterNormalMappedRangeCount = waterNormalMappedRangeCount
            lastWaterMissingMaterialRangeCount = waterMissingMaterialRangeCount
            lastWaterPendingNormalRangeCount = waterPendingNormalRangeCount

            let requiredTextures = requiredWorldTextures(for: scene)
            let uploadedTextureCount = requiredTextures.reduce(into: 0) {
                count, entry in
                if let cached = cachedWorldTextures[entry.key],
                   cached.bitmap == entry.value {
                    count += 1
                }
            }
            return WorldDrawResult(
                uploadedTextureCount: uploadedTextureCount,
                requiredTextureCount: requiredTextures.count,
                failureReason: worldTextureUploadFailureReason
            )
        }

        private func drawDynamicEntities(
            scene: GModMetalDynamicEntityScene,
            device: MTLDevice,
            texturedPipeline: MTLRenderPipelineState,
            missingMaterialPipeline: MTLRenderPipelineState,
            depthState: MTLDepthStencilState,
            encoder: MTLRenderCommandEncoder
        ) {
            let referencedResourceIDs = Set(scene.instances.map(\.resourceID))
            var geometryUploadBudget = DynamicEntityUploadBudget()
            var textureUploadBudget = DynamicEntityUploadBudget()
            uploadNextDynamicEntityGeometry(
                scene: scene,
                referencedResourceIDs: referencedResourceIDs,
                device: device,
                uploadBudget: &geometryUploadBudget
            )
            uploadNextDynamicEntityTexture(
                scene: scene,
                referencedResourceIDs: referencedResourceIDs,
                device: device,
                uploadBudget: &textureUploadBudget
            )

            let resources = Dictionary(
                uniqueKeysWithValues: scene.resources.map { ($0.id, $0) }
            )
            var instanceDrawCount = 0
            var rangeDrawCount = 0
            var checkerRangeCount = 0
            encoder.setDepthStencilState(depthState)
            encoder.setCullMode(.none)

            for instance in scene.instances {
                guard let resource = resources[instance.resourceID],
                      let geometry = cachedDynamicEntityGeometry[
                        instance.resourceID
                      ],
                      geometry.resourceID == instance.resourceID,
                      geometry.vertexCount == resource.vertices.count,
                      geometry.indexCount == resource.indices.count else {
                    continue
                }

                // The scene's identity is a complete EHANDLE (entry + serial).
                // It deliberately remains distinct even when an entry is reused.
                _ = instance.identity.handle.rawValue
                let transform = instance.metalTransform
                var transformUniforms = DynamicEntityTransformUniforms(
                    metalXAxis: SIMD4<Float>(transform.metalXAxis, 0),
                    metalYAxis: SIMD4<Float>(transform.metalYAxis, 0),
                    metalZAxis: SIMD4<Float>(transform.metalZAxis, 0),
                    metalTranslation: SIMD4<Float>(transform.metalTranslation, 1)
                )
                encoder.setVertexBuffer(
                    geometry.vertexBuffer,
                    offset: 0,
                    index: 0
                )
                withUnsafeBytes(of: &transformUniforms) { bytes in
                    guard let address = bytes.baseAddress else { return }
                    encoder.setVertexBytes(
                        address,
                        length: bytes.count,
                        index: 2
                    )
                }

                var drewInstance = false
                for range in resource.drawRanges {
                    var drawsChecker = true
                    if case let .resolved(_, bitmap) =
                        range.materialResolution,
                       bitmap.alphaRepresentation == .straight {
                        let key = Self.dynamicEntityTextureKey(
                            bitmap: bitmap
                        )
                        if let cached = cachedDynamicEntityTextures[key],
                           cached.bitmap == bitmap {
                            encoder.setRenderPipelineState(texturedPipeline)
                            encoder.setFragmentTexture(cached.texture, index: 0)
                            let configuration =
                                GModMetalWorldSamplerConfiguration(
                                    bitmap: bitmap,
                                    renderLayer: .world
                                )
                            encoder.setFragmentSamplerState(
                                samplerStateForWorldTexture(
                                    for: configuration,
                                    device: device
                                ),
                                index: 0
                            )
                            drawsChecker = false
                        }
                    }
                    if drawsChecker {
                        // Missing, failed, unsupported-alpha, and upload-pending
                        // Source materials all remain visible as the checker.
                        encoder.setRenderPipelineState(missingMaterialPipeline)
                        encoder.setFragmentTexture(nil, index: 0)
                        encoder.setFragmentSamplerState(nil, index: 0)
                        checkerRangeCount += 1
                    }
                    encoder.drawIndexedPrimitives(
                        type: .triangle,
                        indexCount: range.indexCount,
                        indexType: .uint32,
                        indexBuffer: geometry.indexBuffer,
                        indexBufferOffset:
                            range.firstIndex * MemoryLayout<UInt32>.stride
                    )
                    rangeDrawCount += 1
                    drewInstance = true
                }
                if drewInstance { instanceDrawCount += 1 }
            }

            lastDynamicEntityInstanceDrawCount = instanceDrawCount
            lastDynamicEntityRangeDrawCount = rangeDrawCount
            lastDynamicEntityCheckerRangeCount = checkerRangeCount
        }

        private func uploadNextDynamicEntityGeometry(
            scene: GModMetalDynamicEntityScene,
            referencedResourceIDs: Set<GModMetalDynamicEntityResourceID>,
            device: MTLDevice,
            uploadBudget: inout DynamicEntityUploadBudget
        ) {
            for resource in scene.resources where
                referencedResourceIDs.contains(resource.id) {
                if cachedDynamicEntityGeometry[resource.id] != nil { continue }
                if dynamicEntityGeometryFailures[resource.id] != nil { continue }

                let vertexBytes = resource.vertices.count
                    .multipliedReportingOverflow(
                        by: MemoryLayout<DynamicEntityGPUVertex>.stride
                    )
                let indexBytes = resource.indices.count
                    .multipliedReportingOverflow(
                        by: MemoryLayout<UInt32>.stride
                    )
                let totalBytes = vertexBytes.partialValue
                    .addingReportingOverflow(indexBytes.partialValue)
                guard !vertexBytes.overflow, !indexBytes.overflow,
                      !totalBytes.overflow,
                      totalBytes.partialValue == resource.geometryByteCount,
                      totalBytes.partialValue <=
                        DynamicEntityGPUCachePolicy.maximumGeometryByteCount,
                      cachedDynamicEntityGeometryByteCount <=
                        DynamicEntityGPUCachePolicy.maximumGeometryByteCount -
                            totalBytes.partialValue else {
                    recordDynamicEntityGeometryFailure(
                        resourceID: resource.id,
                        reason: "geometry byte count violates 128 MiB GPU cap"
                    )
                    continue
                }
                guard uploadBudget.reserve(byteCount: totalBytes.partialValue) else {
                    return
                }

                let vertices = resource.vertices.map { vertex in
                    DynamicEntityGPUVertex(
                        position: SIMD4<Float>(vertex.metalLocalPosition, 1),
                        normal: SIMD4<Float>(vertex.metalLocalNormal, 0),
                        uv: vertex.textureCoordinate
                    )
                }
                let vertexBuffer = vertices.withUnsafeBytes { bytes -> MTLBuffer? in
                    guard let address = bytes.baseAddress else { return nil }
                    return device.makeBuffer(
                        bytes: address,
                        length: bytes.count,
                        options: .storageModeShared
                    )
                }
                let indexBuffer = resource.indices.withUnsafeBytes {
                    bytes -> MTLBuffer? in
                    guard let address = bytes.baseAddress else { return nil }
                    return device.makeBuffer(
                        bytes: address,
                        length: bytes.count,
                        options: .storageModeShared
                    )
                }
                guard let vertexBuffer, let indexBuffer else {
                    recordDynamicEntityGeometryFailure(
                        resourceID: resource.id,
                        reason: "Metal resource-local buffer allocation failed"
                    )
                    return
                }
                let label = Self.dynamicEntityResourceLabel(resource.id)
                vertexBuffer.label = "Dynamic prop vertices \(label)"
                indexBuffer.label = "Dynamic prop indices \(label)"
                cachedDynamicEntityGeometry[resource.id] =
                    CachedDynamicEntityGeometry(
                        resourceID: resource.id,
                        vertexCount: vertices.count,
                        indexCount: resource.indices.count,
                        byteCount: totalBytes.partialValue,
                        vertexBuffer: vertexBuffer,
                        indexBuffer: indexBuffer
                    )
                cachedDynamicEntityGeometryByteCount += totalBytes.partialValue
                return
            }
        }

        private func uploadNextDynamicEntityTexture(
            scene: GModMetalDynamicEntityScene,
            referencedResourceIDs: Set<GModMetalDynamicEntityResourceID>,
            device: MTLDevice,
            uploadBudget: inout DynamicEntityUploadBudget
        ) {
            var visited = Set<DynamicEntityTextureKey>()
            for resource in scene.resources where
                referencedResourceIDs.contains(resource.id) {
                for range in resource.drawRanges {
                    guard case let .resolved(_, bitmap) =
                            range.materialResolution else { continue }
                    let key = Self.dynamicEntityTextureKey(
                        bitmap: bitmap
                    )
                    guard visited.insert(key).inserted else { continue }
                    if let cached = cachedDynamicEntityTextures[key],
                       cached.bitmap == bitmap {
                        continue
                    }
                    if cachedDynamicEntityTextures[key] != nil {
                        removeCachedDynamicEntityTexture(for: key)
                    }
                    if let failure = dynamicEntityTextureFailures[key],
                       failure.bitmap == bitmap {
                        continue
                    }
                    dynamicEntityTextureFailures.removeValue(forKey: key)

                    guard bitmap.alphaRepresentation == .straight else {
                        recordDynamicEntityTextureFailure(
                            key: key,
                            bitmap: bitmap,
                            reason: "dynamic Source bitmap is not straight-alpha"
                        )
                        continue
                    }
                    let byteCount = bitmap.totalByteCount
                    guard byteCount <=
                            DynamicEntityGPUCachePolicy.maximumTextureByteCount else {
                        recordDynamicEntityTextureFailure(
                            key: key,
                            bitmap: bitmap,
                            reason: "dynamic texture exceeds 64 MiB GPU cache cap"
                        )
                        continue
                    }
                    guard uploadBudget.reserve(byteCount: byteCount) else { return }
                    makeRoomForDynamicEntityTexture(byteCount: byteCount)

                    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: .rgba8Unorm_srgb,
                        width: bitmap.width,
                        height: bitmap.height,
                        mipmapped: bitmap.mipLevels.count > 1
                    )
                    descriptor.mipmapLevelCount = bitmap.mipLevels.count
                    descriptor.usage = .shaderRead
                    descriptor.storageMode = .shared
                    guard let texture = device.makeTexture(descriptor: descriptor)
                    else {
                        recordDynamicEntityTextureFailure(
                            key: key,
                            bitmap: bitmap,
                            reason: "Metal dynamic texture allocation failed"
                        )
                        return
                    }
                    for (level, mip) in bitmap.mipLevels.enumerated() {
                        mip.premultipliedRGBA8.withUnsafeBytes { bytes in
                            guard let base = bytes.baseAddress else { return }
                            texture.replace(
                                region: MTLRegionMake2D(
                                    0,
                                    0,
                                    mip.width,
                                    mip.height
                                ),
                                mipmapLevel: level,
                                withBytes: base,
                                bytesPerRow: mip.width * 4
                            )
                        }
                    }
                    texture.label =
                        "Dynamic prop texture \(Self.dynamicEntityResourceLabel(resource.id))"
                    cachedDynamicEntityTextures[key] =
                        CachedDynamicEntityTexture(
                            bitmap: bitmap,
                            byteCount: byteCount,
                            texture: texture
                        )
                    cachedDynamicEntityTextureOrder.append(key)
                    cachedDynamicEntityTextureByteCount += byteCount
                    return
                }
            }
        }

        private func makeRoomForDynamicEntityTexture(byteCount: Int) {
            while !cachedDynamicEntityTextureOrder.isEmpty &&
                (cachedDynamicEntityTextures.count >=
                    DynamicEntityGPUCachePolicy.maximumTextureCount ||
                 cachedDynamicEntityTextureByteCount >
                    DynamicEntityGPUCachePolicy.maximumTextureByteCount -
                        byteCount) {
                removeCachedDynamicEntityTexture(
                    for: cachedDynamicEntityTextureOrder[0]
                )
            }
        }

        private func recordDynamicEntityGeometryFailure(
            resourceID: GModMetalDynamicEntityResourceID,
            reason: String
        ) {
            dynamicEntityGeometryFailures[resourceID] =
                DynamicEntityGeometryFailure(
                    resourceID: resourceID,
                    reason: reason
                )
            dynamicEntitySceneIssue = .geometryUpload(
                resourceID: resourceID,
                reason: reason
            )
        }

        private func recordDynamicEntityTextureFailure(
            key: DynamicEntityTextureKey,
            bitmap: GModMetalSurfaceBitmap,
            reason: String
        ) {
            dynamicEntityTextureFailures[key] = DynamicEntityTextureFailure(
                bitmap: bitmap,
                reason: reason
            )
            dynamicEntitySceneIssue = .textureUpload(key: key, reason: reason)
        }

        private static func dynamicEntityResourceLabel(
            _ id: GModMetalDynamicEntityResourceID
        ) -> String {
            "\(id.normalizedModelPath)#\(id.checksum):" +
                "body=\(id.bodyValue):skin=\(id.skinFamilyIndex)"
        }

        private func worldTexture(
            for bitmap: GModMetalSurfaceBitmap,
            device: MTLDevice,
            uploadBudget: inout WorldUploadBudget,
            isSRGB: Bool = true
        ) -> MTLTexture? {
            let key = Self.worldTextureKey(for: bitmap, isSRGB: isSRGB)
            if let cached = cachedWorldTextures[key], cached.bitmap == bitmap {
                return cached.texture
            }
            let byteCount = bitmap.totalByteCount
            guard uploadBudget.reserve(
                byteCount: byteCount
            ) else { return nil }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: isSRGB ? .rgba8Unorm_srgb : .rgba8Unorm,
                width: bitmap.width,
                height: bitmap.height,
                mipmapped: bitmap.mipLevels.count > 1
            )
            descriptor.mipmapLevelCount = bitmap.mipLevels.count
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                worldTextureUploadFailureReason = .textureUploadFailed(
                    resourceIdentifier: bitmap.resourceIdentifier,
                    byteCount: byteCount,
                    detail: "MTLDevice.makeTexture returned nil"
                )
                return nil
            }
            for (level, mip) in bitmap.mipLevels.enumerated() {
                mip.premultipliedRGBA8.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress else { return }
                    texture.replace(
                        region: MTLRegionMake2D(0, 0, mip.width, mip.height),
                        mipmapLevel: level,
                        withBytes: base,
                        bytesPerRow: mip.width * 4
                    )
                }
            }
            cachedWorldTextures[key] = CachedSurfaceTexture(
                bitmap: bitmap,
                texture: texture
            )
            return texture
        }

        private static func worldTextureKey(
            for bitmap: GModMetalSurfaceBitmap,
            isSRGB: Bool
        ) -> String {
            (isSRGB ? "srgb:" : "linear:") + bitmap.cacheIdentifier
        }

        private func samplerStateForWorldTexture(
            for configuration: GModMetalWorldSamplerConfiguration,
            device: MTLDevice
        ) -> MTLSamplerState? {
            if let cached = worldSamplerStates[configuration] {
                return cached
            }
            let descriptor = MTLSamplerDescriptor()
            descriptor.minFilter = configuration.minFilter == .nearest
                ? .nearest
                : .linear
            descriptor.magFilter = configuration.magFilter == .nearest
                ? .nearest
                : .linear
            switch configuration.mipFilter {
            case .notMipmapped: descriptor.mipFilter = .notMipmapped
            case .nearest: descriptor.mipFilter = .nearest
            case .linear: descriptor.mipFilter = .linear
            }
            descriptor.sAddressMode = configuration.sAddressMode == .clampToEdge
                ? .clampToEdge
                : .repeat
            descriptor.tAddressMode = configuration.tAddressMode == .clampToEdge
                ? .clampToEdge
                : .repeat
            descriptor.maxAnisotropy = configuration.maximumAnisotropy
            guard let sampler = device.makeSamplerState(descriptor: descriptor)
            else { return nil }
            worldSamplerStates[configuration] = sampler
            return sampler
        }

        private func drawSurface(
            scene: GModMetalSurfaceScene,
            device: MTLDevice,
            solidPipeline: MTLRenderPipelineState,
            texturedPipeline: MTLRenderPipelineState,
            depthState: MTLDepthStencilState,
            samplers: [GModMetalSurfaceSamplerConfiguration: MTLSamplerState],
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
                    let samplerConfiguration =
                        GModMetalSurfaceSamplerConfiguration.source(
                            minification: rectangle.minificationFilter,
                            magnification: rectangle.magnificationFilter
                        )
                    guard let sampler = samplers[samplerConfiguration] else {
                        surfaceSceneIssue =
                            "surface sampler configuration was not prepared: " +
                            "\(samplerConfiguration)"
                        continue
                    }
                    encoder.setFragmentSamplerState(sampler, index: 0)
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
                    let samplerConfiguration =
                        GModMetalSurfaceSamplerConfiguration.source(
                            minification: nil,
                            magnification: nil
                        )
                    guard let sampler = samplers[samplerConfiguration] else {
                        surfaceSceneIssue =
                            "default surface sampler configuration was not prepared"
                        continue
                    }
                    encoder.setFragmentSamplerState(sampler, index: 0)
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

            let byteCount = bitmap.totalByteCount
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
            descriptor.mipmapLevelCount =
                GModMetalSurfaceTextureUploadContract.mipmapLevelCount
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
                    region: MTLRegionMake2D(0, 0, bitmap.width, bitmap.height),
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
                    removed.bitmap.totalByteCount
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
            forward rawForward: SIMD3<Float>,
            up rawUp: SIMD3<Float>
        ) -> simd_float4x4 {
            let forward = simd_normalize(rawForward)
            let projectedUp = rawUp - forward * simd_dot(rawUp, forward)
            let upSeed = simd_normalize(projectedUp)
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
                let diagnostics = scene.materialDiagnostics
                let opaqueWorldRangeCount = Swift.max(
                    0,
                    diagnostics.worldMaterialRangeCount -
                        diagnostics.waterMaterialRangeCount
                )
                let missingPreview = diagnostics.unresolvedWorldMaterialNames
                    .prefix(3)
                    .joined(separator: ", ")
                let lightmapDiagnostics = scene.lightmapDiagnostics
                let lightmapSummary: String
                if let atlas = scene.lightmapAtlas,
                   let cachedWorldLightmap,
                   cachedWorldLightmap.identifier == atlas.identifier {
                    lightmapSummary =
                        "lightmap \(lastWorldLightmappedRangeCount)/" +
                        "\(opaqueWorldRangeCount) opaque ranges from " +
                        "\(atlas.width)x\(atlas.height) RGBA16F"
                } else if let worldLightmapIssue {
                    lightmapSummary = "lightmap fallback: \(worldLightmapIssue)"
                } else {
                    lightmapSummary = "lightmap unavailable"
                }
                rendererStats =
                    "World: \(scene.meshIdentifier) (\(mesh.indexCount / 3) triangles; " +
                    "textures \(lastWorldTexturedRangeCount)/" +
                    "\(opaqueWorldRangeCount), " +
                    "missing \(lastWorldMissingMaterialRangeCount), " +
                    "upload pending \(lastWorldPendingTextureRangeCount); " +
                    "\(lightmapSummary), ignored styles " +
                    "\(lightmapDiagnostics.ignoredAdditionalLightStyleFaceCount), " +
                    "ignored bump \(lightmapDiagnostics.ignoredBumpLightFaceCount), " +
                    "clamped channels \(lightmapDiagnostics.clampedChannelCount); " +
                    "sky \(lastSkyboxRenderedFaceCount)/" +
                    "\(diagnostics.skyboxFaceRangeCount), " +
                    "sky missing \(lastSkyboxMissingFaceCount), " +
                    "sky pending \(lastSkyboxPendingFaceCount); " +
                    "water \(lastWaterRenderedRangeCount)/" +
                    "\(diagnostics.waterMaterialRangeCount), normal " +
                    "\(lastWaterNormalMappedRangeCount), missing " +
                    "\(lastWaterMissingMaterialRangeCount), normal pending " +
                    "\(lastWaterPendingNormalRangeCount), unsupported bump " +
                    "\(diagnostics.unsupportedWaterBumpTextureNames.count))" +
                    (missingPreview.isEmpty ? "" : "; unresolved: \(missingPreview)")
            } else if let worldSceneIssue {
                rendererStats =
                    "World unavailable: \(worldSceneIssue)"
            } else {
                rendererStats =
                    "World loading"
            }

            let dynamicEntityStats: String
            if let scene = activeDynamicEntityScene {
                dynamicEntityStats =
                    "Props: \(lastDynamicEntityInstanceDrawCount)/" +
                    "\(scene.instances.count) instances, " +
                    "\(lastDynamicEntityRangeDrawCount) ranges, " +
                    "checker \(lastDynamicEntityCheckerRangeCount); " +
                    "GPU geometry \(cachedDynamicEntityGeometry.count) / " +
                    "\(cachedDynamicEntityGeometryByteCount) bytes, textures " +
                    "\(cachedDynamicEntityTextures.count)/" +
                    "\(DynamicEntityGPUCachePolicy.maximumTextureCount) / " +
                    "\(cachedDynamicEntityTextureByteCount) bytes" +
                    (dynamicEntitySceneIssue.map { "; issue: \($0)" } ?? "")
            } else if let dynamicEntitySceneIssue {
                dynamicEntityStats = "Props rejected: \(dynamicEntitySceneIssue)"
            } else {
                dynamicEntityStats = "Props: no publication"
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
                \(dynamicEntityStats)
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

        """ + GModMetalWorldColorSpaceContract.metalShaderSupport +
        """

        struct WorldVertex
        {
            float4 position;
            float4 normal;
            float2 uv;
            float2 lightmapUV;
        };

        struct DynamicEntityVertex
        {
            float4 position;
            float4 normal;
            float2 uv;
        };

        struct DynamicEntityTransform
        {
            float4 metalXAxis;
            float4 metalYAxis;
            float4 metalZAxis;
            float4 metalTranslation;
        };

        struct WorldUniforms
        {
            float4x4 viewProjection;
            float4 lightDirection;
        };

        struct WorldWaterUniforms
        {
            float4 fogColorAndAlpha;
            float4 scrollDirectionRateAndTime;
        };

        struct WorldVertexOutput
        {
            float4 position [[position]];
            float3 normal;
            float2 uv;
            float2 lightmapUV;
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
            output.uv = sourceVertex.uv;
            output.lightmapUV = sourceVertex.lightmapUV;
            return output;
        }

        vertex WorldVertexOutput dynamicEntityVertexMain(
            const device DynamicEntityVertex *vertices
                [[buffer(0)]],

            constant WorldUniforms &uniforms
                [[buffer(1)]],

            constant DynamicEntityTransform &model
                [[buffer(2)]],

            uint vertexID
                [[vertex_id]]
        )
        {
            DynamicEntityVertex sourceVertex = vertices[vertexID];
            float3 worldPosition = model.metalTranslation.xyz
                + model.metalXAxis.xyz * sourceVertex.position.x
                + model.metalYAxis.xyz * sourceVertex.position.y
                + model.metalZAxis.xyz * sourceVertex.position.z;
            float3 worldNormal = normalize(
                model.metalXAxis.xyz * sourceVertex.normal.x
                + model.metalYAxis.xyz * sourceVertex.normal.y
                + model.metalZAxis.xyz * sourceVertex.normal.z
            );
            WorldVertexOutput output;
            output.position = uniforms.viewProjection
                * float4(worldPosition, 1.0);
            output.normal = worldNormal;
            output.uv = sourceVertex.uv;
            output.lightmapUV = float2(0.0);
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
            float3 baseLinear = gmodDecodeDisplaySRGB(
                float3(0.48, 0.61, 0.72)
            );
            return gmodWorldOutput(baseLinear * brightness, 1.0);
        }

        fragment float4 worldTexturedFragmentMain(
            WorldVertexOutput input [[stage_in]],

            constant WorldUniforms &uniforms
                [[buffer(1)]],

            texture2d<float> baseTexture [[texture(0)]],

            sampler baseSampler [[sampler(0)]]
        )
        {
            float3 normal = normalize(input.normal);
            float3 light = normalize(uniforms.lightDirection.xyz);
            float diffuse = max(dot(normal, light), 0.0);
            float hemisphere = 0.28 + 0.24 * (normal.y * 0.5 + 0.5);
            float brightness = min(1.0, hemisphere + diffuse * 0.62);
            float4 sample = baseTexture.sample(baseSampler, input.uv);
            return gmodWorldOutput(sample.rgb * brightness, 1.0);
        }

        fragment float4 worldLightmappedFragmentMain(
            WorldVertexOutput input [[stage_in]],

            texture2d<float> lightmapTexture [[texture(1)]],

            sampler lightmapSampler [[sampler(1)]]
        )
        {
            float3 baseLinear = gmodDecodeDisplaySRGB(
                float3(0.48, 0.61, 0.72)
            );
            float3 bakedLight = lightmapTexture.sample(
                lightmapSampler,
                input.lightmapUV
            ).rgb;
            return gmodWorldOutput(baseLinear * bakedLight, 1.0);
        }

        fragment float4 worldTexturedLightmappedFragmentMain(
            WorldVertexOutput input [[stage_in]],

            texture2d<float> baseTexture [[texture(0)]],

            texture2d<float> lightmapTexture [[texture(1)]],

            sampler baseSampler [[sampler(0)]],

            sampler lightmapSampler [[sampler(1)]]
        )
        {
            float3 baseLinear = baseTexture.sample(baseSampler, input.uv).rgb;
            float3 bakedLight = lightmapTexture.sample(
                lightmapSampler,
                input.lightmapUV
            ).rgb;
            return gmodWorldOutput(baseLinear * bakedLight, 1.0);
        }

        fragment float4 worldMissingMaterialFragmentMain(
            WorldVertexOutput input [[stage_in]]
        )
        {
            float2 tile = floor(input.uv * 8.0);
            bool alternate = fmod(tile.x + tile.y, 2.0) != 0.0;
            float3 displayColor = alternate
                ? float3(0.92, 0.05, 0.72)
                : float3(0.06, 0.01, 0.05);
            return gmodWorldOutput(
                gmodDecodeDisplaySRGB(displayColor),
                1.0
            );
        }

        fragment float4 worldSkyboxFragmentMain(
            WorldVertexOutput input [[stage_in]],

            texture2d<float> skyTexture [[texture(0)]],

            sampler skySampler [[sampler(0)]]
        )
        {
            float4 sample = skyTexture.sample(skySampler, input.uv);
            return gmodWorldOutput(sample.rgb, 1.0);
        }

        fragment float4 worldWaterSolidFragmentMain(
            constant WorldWaterUniforms &water
                [[buffer(2)]]
        )
        {
            return gmodWorldOutput(
                gmodDecodeDisplaySRGB(water.fogColorAndAlpha.rgb),
                water.fogColorAndAlpha.a
            );
        }

        fragment float4 worldWaterNormalFragmentMain(
            WorldVertexOutput input [[stage_in]],

            constant WorldWaterUniforms &water
                [[buffer(2)]],

            texture2d<float> normalTexture [[texture(0)]],

            sampler normalSampler [[sampler(0)]]
        )
        {
            float2 direction = water.scrollDirectionRateAndTime.xy;
            float rate = water.scrollDirectionRateAndTime.z;
            float sourceTime = water.scrollDirectionRateAndTime.w;
            float2 animatedUV = input.uv + direction * rate * sourceTime;
            float3 sampledNormal = normalize(
                normalTexture.sample(normalSampler, animatedUV).xyz * 2.0 - 1.0
            );
            float normalLighting = 0.88 + 0.12 * saturate(
                dot(sampledNormal, normalize(float3(0.35, 0.55, 0.76)))
            );
            return gmodWorldOutput(
                gmodDecodeDisplaySRGB(water.fogColorAndAlpha.rgb) *
                    normalLighting,
                water.fogColorAndAlpha.a
            );
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
