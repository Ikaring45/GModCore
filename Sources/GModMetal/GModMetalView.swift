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
    private let firstPersonViewModelScene:
        GModMetalFirstPersonViewModelScene?
    private let surfaceScene: GModMetalSurfaceScene?
    private let preferredFramesPerSecond: Int
    private let onFrame: @Sendable (GModMetalFrameRequest) -> Void
    private let onWorldFrameEvent: @Sendable (GModMetalWorldFrameEvent) -> Void
    private let onWorldFramePresented: @Sendable (String) -> Void

    public init(
        stats: Binding<String>,
        worldScene: GModMetalWorldScene? = nil,
        dynamicEntityScene: GModMetalDynamicEntityScene? = nil,
        firstPersonViewModelScene:
            GModMetalFirstPersonViewModelScene? = nil,
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
        self.firstPersonViewModelScene = firstPersonViewModelScene
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
            firstPersonViewModelScene: firstPersonViewModelScene,
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
            firstPersonViewModelScene: firstPersonViewModelScene,
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

        private var dynamicEntityPipelines:
            DynamicEntityRenderPipelines?

        private var firstPersonViewModelTexturedPipeline:
            MTLRenderPipelineState?

        private var worldSkyboxPipeline:
            MTLRenderPipelineState?

        private var worldSunSpritePipeline:
            MTLRenderPipelineState?

        private var worldWaterSolidPipeline:
            MTLRenderPipelineState?

        private var worldWaterNormalPipeline:
            MTLRenderPipelineState?

        private var worldWaterCompositeSolidPipeline:
            MTLRenderPipelineState?

        private var worldWaterCompositeNormalPipeline:
            MTLRenderPipelineState?

        private var worldSceneCopyPipeline:
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

        private enum PendingFirstPersonViewModelScene {
            case replace(GModMetalFirstPersonViewModelScene)
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
            /// Normalized displacement alpha in X; remaining lanes are
            /// reserved for future Source vertex shader inputs.
            let sourceParameters: SIMD4<Float>
        }

        private struct WorldUniforms {
            let viewProjection: simd_float4x4
            let lightDirection: SIMD4<Float>
            let directLinearRGB: SIMD4<Float>
            let ambientLinearRGB: SIMD4<Float>
            /// Metal-space plane; fragments with a negative signed distance
            /// are outside the active water render-target half-space.
            let clipPlane: SIMD4<Float>
            /// Linear fog RGB and an enabled bit in W.
            let fogColorAndEnabled: SIMD4<Float>
            /// Authored baked-space start/end, max density, radial bit.
            let fogStartEndDensityRadial: SIMD4<Float>
            let fogCameraEye: SIMD4<Float>
            let fogCameraForward: SIMD4<Float>
            /// Source Water refraction pass: surface Y, inverse fog range,
            /// enabled bit, followed by the camera ray basis used to encode
            /// `CalcWaterFogAlpha` into target alpha.
            let waterFogSurfaceInverseRangeAndEnabled: SIMD4<Float>
            let waterFogCameraEye: SIMD4<Float>
            let waterFogCameraForward: SIMD4<Float>

            init(
                viewProjection: simd_float4x4,
                lightDirection: SIMD4<Float>,
                directLinearRGB: SIMD4<Float>,
                ambientLinearRGB: SIMD4<Float>,
                clipPlane: SIMD4<Float>,
                fog: GModMetalSky3DFogUniforms? = nil,
                waterRefractionFog: GModMetalWaterRefractionFog? = nil,
                waterFogCameraEye: SIMD3<Float> = .zero,
                waterFogCameraForward: SIMD3<Float> = .zero
            ) {
                self.viewProjection = viewProjection
                self.lightDirection = lightDirection
                self.directLinearRGB = directLinearRGB
                self.ambientLinearRGB = ambientLinearRGB
                self.clipPlane = clipPlane
                if let fog {
                    fogColorAndEnabled = SIMD4<Float>(fog.linearRGB, 1)
                    fogStartEndDensityRadial = SIMD4<Float>(
                        fog.start,
                        fog.end,
                        fog.maximumDensity,
                        fog.isRadial ? 1 : 0
                    )
                    fogCameraEye = SIMD4<Float>(fog.metalCameraEye, 0)
                    fogCameraForward = SIMD4<Float>(fog.metalCameraForward, 0)
                } else {
                    fogColorAndEnabled = .zero
                    fogStartEndDensityRadial = .zero
                    fogCameraEye = .zero
                    fogCameraForward = .zero
                }
                if let waterRefractionFog,
                   waterRefractionFog.fogEnd > waterRefractionFog.fogStart {
                    waterFogSurfaceInverseRangeAndEnabled = SIMD4<Float>(
                        waterRefractionFog.sourceSurfaceZ,
                        1 / (waterRefractionFog.fogEnd -
                            waterRefractionFog.fogStart),
                        1,
                        0
                    )
                    self.waterFogCameraEye = SIMD4<Float>(
                        waterFogCameraEye,
                        0
                    )
                    self.waterFogCameraForward = SIMD4<Float>(
                        waterFogCameraForward,
                        0
                    )
                } else {
                    waterFogSurfaceInverseRangeAndEnabled = .zero
                    self.waterFogCameraEye = .zero
                    self.waterFogCameraForward = .zero
                }
            }
        }

        private struct WorldWaterUniforms {
            /// Authored display-sRGB fog color and opaque fallback alpha.
            let fogColorAndAlpha: SIMD4<Float>
            /// Unit scroll direction, real VMT rate, and frozen Source time.
            let scrollDirectionRateAndTime: SIMD4<Float>
            /// Authored reflect/refract dependent-UV scales and drawable size.
            let sourceAmountsAndViewport: SIMD4<Float>
            /// Metal camera eye and target-presence bits (reflect=1, refract=2).
            let cameraEyeAndTargetFlags: SIMD4<Float>
            /// Authored fog start/end, above-water bit, enabled bit.
            let fogStartEndAboveAndEnabled: SIMD4<Float>
            /// Camera forward and distortion encoding (normal=1, DuDv=2).
            let cameraForwardAndDistortionEncoding: SIMD4<Float>
        }

        /// Secondary bindings used by LightmappedGeneric and
        /// WorldVertexTransition. Every field is four-float aligned so the
        /// Swift value has the same layout as its Metal counterpart.
        private struct WorldTerrainUniforms {
            let detailRow0: SIMD4<Float>
            let detailRow1: SIMD4<Float>
            let blendMaskRow0: SIMD4<Float>
            let blendMaskRow1: SIMD4<Float>
            /// Detail factor, detail mode, has-detail, has-base2.
            let controls: SIMD4<Float>
            /// Has blend-modulate texture, uses displacement derivative LOD;
            /// remaining lanes are reserved.
            let flags: SIMD4<Float>

            static let disabled = Self(
                detailRow0: SIMD4<Float>(1, 0, 0, 0),
                detailRow1: SIMD4<Float>(0, 1, 0, 0),
                blendMaskRow0: SIMD4<Float>(1, 0, 0, 0),
                blendMaskRow1: SIMD4<Float>(0, 1, 0, 0),
                controls: .zero,
                flags: .zero
            )
        }

        private struct WorldSunSpriteUniforms {
            let viewProjection: simd_float4x4
            let basePosition: SIMD4<Float>
            let rightExtent: SIMD4<Float>
            let upExtent: SIMD4<Float>
            let displayRGBAndOpacity: SIMD4<Float>
            let hdrColorScale: SIMD4<Float>
        }

        private struct CachedWaterRenderTargets {
            let width: Int
            let height: Int
            let colorPixelFormat: MTLPixelFormat
            let depthPixelFormat: MTLPixelFormat
            let refractionColor: MTLTexture
            let refractionDepth: MTLTexture
            let reflectionColor: MTLTexture
            let reflectionDepth: MTLTexture
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

        private struct DynamicEntityAppearanceUniforms {
            /// RGB remains authored display-sRGB until the fragment shader;
            /// alpha is the fixed Source blend amount for the selected mode.
            let displayRGBAndAlpha: SIMD4<Float>
        }

        private struct FirstPersonViewModelMaterialUniforms {
            /// Raw linear multiplier written by the supported Source material
            /// proxy. This is intentionally distinct from Entity color32.
            let playerWeaponColorMultiplier: SIMD4<Float>
        }

        private struct DynamicEntityPipelinePair {
            let textured: MTLRenderPipelineState
            let missingMaterial: MTLRenderPipelineState
        }

        private struct DynamicEntityRenderPipelines {
            let opaque: DynamicEntityPipelinePair
            let sourceAlpha: DynamicEntityPipelinePair
            let sourceColorAlpha: MTLRenderPipelineState
            let additive: DynamicEntityPipelinePair

            func pair(
                for blendMode: GModMetalDynamicEntityBlendMode
            ) -> DynamicEntityPipelinePair {
                switch blendMode {
                case .opaque: return opaque
                case .sourceAlpha: return sourceAlpha
                case .additive: return additive
                }
            }
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

            private(set) var remainingResourceCount: Int
            private(set) var remainingByteCount: Int

            init(
                maximumResourceCount: Int = Self.maximumResourceCount,
                maximumByteCount: Int = Self.maximumByteCount
            ) {
                remainingResourceCount = maximumResourceCount
                remainingByteCount = maximumByteCount
            }

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
            case displacementAlphaArrayMismatch
            case emptyIndices
            case incompleteTriangle(indexCount: Int)
            case invalidPosition(index: Int)
            case invalidNormal(index: Int)
            case zeroNormal(index: Int)
            case invalidIndex(index: UInt32, vertexCount: Int)
            case invalidTextureCoordinate(index: Int)
            case invalidLightmapTextureCoordinate(index: Int)
            case invalidDisplacementAlpha(index: Int)
            case invalidMaterialRange(index: Int)
            case invalidTerrainMaterialRange(index: Int)
            case invalidSkyboxRanges
            case invalidSky3DMetadata
            case invalidWaterMaterialRange(index: Int)
            case invalidEnvironmentLighting
            case invalidSunSprite(index: Int)
            case invalidCameraEye
            case invalidCameraFieldOfView
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
                case .displacementAlphaArrayMismatch:
                    return "position/displacement-alpha counts differ"
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
                case let .invalidDisplacementAlpha(index):
                    return "displacement alpha \(index) is outside finite 0...255"
                case let .invalidMaterialRange(index):
                    return "material range \(index) is invalid or overlaps the index buffer"
                case let .invalidTerrainMaterialRange(index):
                    return "terrain material range \(index) contains invalid Source shader inputs"
                case .invalidSkyboxRanges:
                    return "skybox ranges must contain one named set of six unique faces"
                case .invalidSky3DMetadata:
                    return "3D sky ranges require finite sky_camera origin and positive scale"
                case let .invalidWaterMaterialRange(index):
                    return "water material range \(index) contains non-finite or mismatched Source inputs"
                case .invalidEnvironmentLighting:
                    return "compiled light_environment contains invalid Source world-light values"
                case let .invalidSunSprite(index):
                    return "env_sun sprite \(index) contains invalid entity-driven values"
                case .invalidCameraEye:
                    return "camera eye is non-finite"
                case .invalidCameraFieldOfView:
                    return "camera vertical field of view is outside (0, pi)"
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

        private enum WaterRenderTargetError: Error, CustomStringConvertible {
            case invalidDimensions(width: Int, height: Int)
            case colorAllocationFailed(label: String)
            case depthAllocationFailed(label: String)

            var description: String {
                switch self {
                case let .invalidDimensions(width, height):
                    return "water target dimensions are invalid (\(width)x\(height))"
                case let .colorAllocationFailed(label):
                    return "failed to allocate \(label) water color target"
                case let .depthAllocationFailed(label):
                    return "failed to allocate \(label) water depth target"
                }
            }
        }

        private var pendingWorldScene:
            PendingWorldScene?

        private var pendingSurfaceScene:
            PendingSurfaceScene?

        private var pendingDynamicEntityScene:
            PendingDynamicEntityScene?

        private var pendingFirstPersonViewModelScene:
            PendingFirstPersonViewModelScene?

        /// Accessed only by MTKView's serialized draw callback.
        private var activeWorldScene:
            GModMetalWorldScene?

        /// Accessed only by MTKView's serialized draw callback.
        private var activeDynamicEntityScene:
            GModMetalDynamicEntityScene?

        /// Source-authored `c_*.mdl` resource rendered in its own camera-space
        /// depth lifetime after the completed world and before VGUI.
        private var activeFirstPersonViewModelScene:
            GModMetalFirstPersonViewModelScene?

        private var cachedFirstPersonViewModelGeometry:
            CachedDynamicEntityGeometry?

        private var cachedFirstPersonViewModelTextures:
            [DynamicEntityTextureKey: CachedDynamicEntityTexture] = [:]

        private var firstPersonViewModelIssue: String?

        private var lastFirstPersonViewModelRangeDrawCount = 0

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

        /// Serialized render-callback workspace for ordinary model-zero PVS
        /// and frustum selection. Its buffers survive camera-only scenes.
        private let worldVisibilityWorkspace =
            GModMetalWorldVisibilityWorkspace()

        /// Separate cache because Source's 3D sky uses a fixed sky-camera PVS
        /// origin and scaled clip planes while sharing the ordinary view basis.
        private let sky3DVisibilityWorkspace =
            GModMetalWorldVisibilityWorkspace()

        /// Full-resolution Source water views. These are rebuilt only when the
        /// physical drawable or attachment formats change.
        private var cachedWaterRenderTargets:
            CachedWaterRenderTargets?

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

        private var lastWorldVisibilityMetrics:
            GModMetalWorldVisibilityMetrics?

        private var lastWorldVisibilityWasFailOpen = false

        private var lastSkyboxRenderedFaceCount = 0

        private var lastSkyboxMissingFaceCount = 0

        private var lastSkyboxPendingFaceCount = 0

        private var lastWaterRenderedRangeCount = 0

        private var lastWaterNormalMappedRangeCount = 0

        private var lastWaterMissingMaterialRangeCount = 0

        private var lastWaterPendingNormalRangeCount = 0

        private var lastWaterRenderTargetRangeCount = 0

        private var waterRenderTargetIssue: String?

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
            firstPersonViewModelScene:
                GModMetalFirstPersonViewModelScene? = nil,
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
            if let firstPersonViewModelScene {
                pendingFirstPersonViewModelScene =
                    .replace(firstPersonViewModelScene)
            } else {
                pendingFirstPersonViewModelScene = .clear
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

                    let firstPersonViewModelVertexFunction =
                        library.makeFunction(
                            name: "firstPersonViewModelVertexMain"
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

                    let firstPersonViewModelTexturedFragmentFunction =
                        library.makeFunction(
                            name: "firstPersonViewModelTexturedFragmentMain"
                        ),

                    let dynamicEntityTexturedFragmentFunction =
                        library.makeFunction(
                            name: "dynamicEntityTexturedFragmentMain"
                        ),

                    let dynamicEntityColorFragmentFunction =
                        library.makeFunction(
                            name: "dynamicEntityColorFragmentMain"
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

                    let dynamicEntityMissingMaterialFragmentFunction =
                        library.makeFunction(
                            name: "dynamicEntityMissingMaterialFragmentMain"
                        ),

                    let worldSkyboxFragmentFunction =
                        library.makeFunction(
                            name:
                                "worldSkyboxFragmentMain"
                        ),

                    let worldSunSpriteVertexFunction =
                        library.makeFunction(
                            name: "worldSunSpriteVertexMain"
                        ),

                    let worldSunSpriteFragmentFunction =
                        library.makeFunction(
                            name: "worldSunSpriteFragmentMain"
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

                    let worldWaterCompositeSolidFragmentFunction =
                        library.makeFunction(
                            name: "worldWaterCompositeSolidFragmentMain"
                        ),

                    let worldWaterCompositeNormalFragmentFunction =
                        library.makeFunction(
                            name: "worldWaterCompositeNormalFragmentMain"
                        ),

                    let worldSceneCopyVertexFunction =
                        library.makeFunction(name: "worldSceneCopyVertexMain"),

                    let worldSceneCopyFragmentFunction =
                        library.makeFunction(name: "worldSceneCopyFragmentMain"),

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

                func makeDynamicEntityPipelinePair(
                    blendMode: GModMetalDynamicEntityBlendMode
                ) throws -> DynamicEntityPipelinePair {
                    let texturedDescriptor =
                        Self.makeDynamicEntityPipelineDescriptor(
                            vertexFunction: dynamicEntityVertexFunction,
                            fragmentFunction:
                                dynamicEntityTexturedFragmentFunction,
                            blendMode: blendMode,
                            colorPixelFormat: colorPixelFormat,
                            depthPixelFormat: depthPixelFormat
                        )
                    let missingDescriptor =
                        Self.makeDynamicEntityPipelineDescriptor(
                            vertexFunction: dynamicEntityVertexFunction,
                            fragmentFunction:
                                dynamicEntityMissingMaterialFragmentFunction,
                            blendMode: blendMode,
                            colorPixelFormat: colorPixelFormat,
                            depthPixelFormat: depthPixelFormat
                        )
                    return try DynamicEntityPipelinePair(
                        textured: device.makeRenderPipelineState(
                            descriptor: texturedDescriptor
                        ),
                        missingMaterial: device.makeRenderPipelineState(
                            descriptor: missingDescriptor
                        )
                    )
                }
                dynamicEntityPipelines = try DynamicEntityRenderPipelines(
                    opaque: makeDynamicEntityPipelinePair(
                        blendMode: .opaque
                    ),
                    sourceAlpha: makeDynamicEntityPipelinePair(
                        blendMode: .sourceAlpha
                    ),
                    sourceColorAlpha: device.makeRenderPipelineState(
                        descriptor: Self.makeDynamicEntityPipelineDescriptor(
                            vertexFunction: dynamicEntityVertexFunction,
                            fragmentFunction: dynamicEntityColorFragmentFunction,
                            blendMode: .sourceAlpha,
                            colorPixelFormat: colorPixelFormat,
                            depthPixelFormat: depthPixelFormat
                        )
                    ),
                    additive: makeDynamicEntityPipelinePair(
                        blendMode: .additive
                    )
                )

                let firstPersonViewModelDescriptor =
                    MTLRenderPipelineDescriptor()
                firstPersonViewModelDescriptor.vertexFunction =
                    firstPersonViewModelVertexFunction
                firstPersonViewModelDescriptor.fragmentFunction =
                    firstPersonViewModelTexturedFragmentFunction
                firstPersonViewModelDescriptor.colorAttachments[0].pixelFormat =
                    colorPixelFormat
                firstPersonViewModelDescriptor.depthAttachmentPixelFormat =
                    depthPixelFormat
                firstPersonViewModelTexturedPipeline =
                    try device.makeRenderPipelineState(
                        descriptor: firstPersonViewModelDescriptor
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

                let worldSunSpriteDescriptor =
                    Self.makeWorldSunSpritePipelineDescriptor(
                        vertexFunction: worldSunSpriteVertexFunction,
                        fragmentFunction: worldSunSpriteFragmentFunction,
                        colorPixelFormat: colorPixelFormat,
                        depthPixelFormat: depthPixelFormat
                    )
                worldSunSpritePipeline = try device.makeRenderPipelineState(
                    descriptor: worldSunSpriteDescriptor
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

                let worldWaterCompositeSolidDescriptor =
                    Self.makeWorldWaterPipelineDescriptor(
                        vertexFunction: worldVertexFunction,
                        fragmentFunction:
                            worldWaterCompositeSolidFragmentFunction,
                        colorPixelFormat: colorPixelFormat,
                        depthPixelFormat: depthPixelFormat
                    )
                worldWaterCompositeSolidPipeline =
                    try device.makeRenderPipelineState(
                        descriptor: worldWaterCompositeSolidDescriptor
                    )

                let worldWaterCompositeNormalDescriptor =
                    Self.makeWorldWaterPipelineDescriptor(
                        vertexFunction: worldVertexFunction,
                        fragmentFunction:
                            worldWaterCompositeNormalFragmentFunction,
                        colorPixelFormat: colorPixelFormat,
                        depthPixelFormat: depthPixelFormat
                    )
                worldWaterCompositeNormalPipeline =
                    try device.makeRenderPipelineState(
                        descriptor: worldWaterCompositeNormalDescriptor
                    )

                let worldSceneCopyDescriptor = MTLRenderPipelineDescriptor()
                worldSceneCopyDescriptor.vertexFunction =
                    worldSceneCopyVertexFunction
                worldSceneCopyDescriptor.fragmentFunction =
                    worldSceneCopyFragmentFunction
                worldSceneCopyDescriptor.colorAttachments[0].pixelFormat =
                    colorPixelFormat
                worldSceneCopyDescriptor.depthAttachmentPixelFormat =
                    depthPixelFormat
                worldSceneCopyPipeline = try device.makeRenderPipelineState(
                    descriptor: worldSceneCopyDescriptor
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
            firstPersonViewModelScene:
                GModMetalFirstPersonViewModelScene?,
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
            if let firstPersonViewModelScene {
                pendingFirstPersonViewModelScene =
                    .replace(firstPersonViewModelScene)
            } else {
                pendingFirstPersonViewModelScene = .clear
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
                firstPersonViewModelScene: nil,
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
            firstPersonViewModel: PendingFirstPersonViewModelScene?,
            surface: PendingSurfaceScene?
        ) {
            pendingSceneLock.lock()
            let result = (
                pendingWorldScene,
                pendingDynamicEntityScene,
                pendingFirstPersonViewModelScene,
                pendingSurfaceScene
            )
            pendingWorldScene = nil
            pendingDynamicEntityScene = nil
            pendingFirstPersonViewModelScene = nil
            pendingSurfaceScene = nil
            pendingSceneLock.unlock()
            return result
        }

        private func applyPendingFirstPersonViewModelScene(
            _ pending: PendingFirstPersonViewModelScene?
        ) {
            guard let pending else { return }
            guard case let .replace(scene) = pending else {
                activeFirstPersonViewModelScene = nil
                resetFirstPersonViewModelCaches()
                firstPersonViewModelIssue = nil
                lastFirstPersonViewModelRangeDrawCount = 0
                return
            }
            guard scene.retainedGeometryByteCount <=
                    DynamicEntityGPUCachePolicy.maximumGeometryByteCount else {
                firstPersonViewModelIssue =
                    "viewmodel geometry exceeds 128 MiB renderer cap"
                return
            }
            if let active = activeFirstPersonViewModelScene {
                if active.generation == scene.generation {
                    guard scene.revision > active.revision else { return }
                } else if Self.dynamicEntityGeneration(
                    scene.generation,
                    precedes: active.generation
                ) {
                    firstPersonViewModelIssue =
                        "ignored stale first-person viewmodel generation"
                    return
                }
                if active.resource.id != scene.resource.id {
                    // A new authored frame replaces only immutable geometry.
                    // Material bitmaps are appearance-owned and remain valid
                    // across sequence/frame updates for the same Studio
                    // model/body/skin/LOD.
                    cachedFirstPersonViewModelGeometry = nil
                    if !GModMetalStudioGeometryCacheContract.hasSameAppearance(
                        active.resource.id,
                        scene.resource.id
                    ) {
                        cachedFirstPersonViewModelTextures.removeAll(
                            keepingCapacity: true
                        )
                    }
                }
            } else {
                resetFirstPersonViewModelCaches()
            }
            activeFirstPersonViewModelScene = scene
            firstPersonViewModelIssue = nil
            lastFirstPersonViewModelRangeDrawCount = 0
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
                worldVisibilityWorkspace.reset()
                sky3DVisibilityWorkspace.reset()
                cachedWorldTextures.removeAll(keepingCapacity: true)
                cachedWorldLightmap = nil
                worldTextureUploadFailureReason = nil
                lastWorldTexturedRangeCount = 0
                lastWorldMissingMaterialRangeCount = 0
                lastWorldPendingTextureRangeCount = 0
                lastWorldLightmappedRangeCount = 0
                lastWorldVisibilityMetrics = nil
                lastWorldVisibilityWasFailOpen = false
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
                        worldVisibilityWorkspace.reset()
                        sky3DVisibilityWorkspace.reset()
                        cachedWorldMesh = try Self.makeCachedWorldMesh(
                            scene,
                            device: device
                        )
                        cachedWorldTextures.removeAll(keepingCapacity: true)
                        cachedWorldLightmap = nil
                    }
                    pruneCachedWorldTextures(for: scene)

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

        private func resetFirstPersonViewModelCaches() {
            cachedFirstPersonViewModelGeometry = nil
            cachedFirstPersonViewModelTextures.removeAll(
                keepingCapacity: true
            )
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

        private static func makeDynamicEntityPipelineDescriptor(
            vertexFunction: MTLFunction,
            fragmentFunction: MTLFunction,
            blendMode: GModMetalDynamicEntityBlendMode,
            colorPixelFormat: MTLPixelFormat,
            depthPixelFormat: MTLPixelFormat
        ) -> MTLRenderPipelineDescriptor {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
            descriptor.depthAttachmentPixelFormat = depthPixelFormat

            guard blendMode != .opaque else { return descriptor }
            let color = descriptor.colorAttachments[0]!
            color.isBlendingEnabled = true
            color.rgbBlendOperation = .add
            color.alphaBlendOperation = .add
            color.sourceRGBBlendFactor = .sourceAlpha
            color.destinationRGBBlendFactor = blendMode == .additive
                ? .one
                : .oneMinusSourceAlpha
            // The drawable alpha is not a Source render target contract. Keep
            // it conventional for translucent composition and unchanged for
            // additive color accumulation.
            color.sourceAlphaBlendFactor = blendMode == .additive ? .zero : .one
            color.destinationAlphaBlendFactor = blendMode == .additive
                ? .one
                : .oneMinusSourceAlpha
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

        private static func makeWorldSunSpritePipelineDescriptor(
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

            // C_Sun explicitly tints an additive glow material. The sampled
            // texture alpha is folded into fragment RGB, then accumulated over
            // the completed 2D/3D sky before ordinary world geometry occludes
            // it in the following depth-cleared pass.
            let color = descriptor.colorAttachments[0]!
            color.isBlendingEnabled = true
            color.rgbBlendOperation = .add
            color.alphaBlendOperation = .add
            color.sourceRGBBlendFactor = .one
            color.destinationRGBBlendFactor = .one
            color.sourceAlphaBlendFactor = .one
            color.destinationAlphaBlendFactor = .one
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
                    lightmapUV: scene.sourceLightmapTextureCoordinates[index],
                    sourceParameters: SIMD4<Float>(
                        Swift.max(
                            0,
                            Swift.min(
                                1,
                                scene.sourceDisplacementAlphas[index] / 255
                            )
                        ),
                        0,
                        0,
                        0
                    )
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

        private func waterRenderTargets(
            device: MTLDevice,
            width: Int,
            height: Int,
            colorPixelFormat: MTLPixelFormat,
            depthPixelFormat: MTLPixelFormat
        ) throws -> CachedWaterRenderTargets {
            guard width > 0, height > 0 else {
                throw WaterRenderTargetError.invalidDimensions(
                    width: width,
                    height: height
                )
            }
            if let cachedWaterRenderTargets,
               cachedWaterRenderTargets.width == width,
               cachedWaterRenderTargets.height == height,
               cachedWaterRenderTargets.colorPixelFormat == colorPixelFormat,
               cachedWaterRenderTargets.depthPixelFormat == depthPixelFormat {
                return cachedWaterRenderTargets
            }

            func colorTexture(label: String) throws -> MTLTexture {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: colorPixelFormat,
                    width: width,
                    height: height,
                    mipmapped: false
                )
                descriptor.storageMode = .private
                descriptor.usage = [.renderTarget, .shaderRead]
                guard let texture = device.makeTexture(descriptor: descriptor) else {
                    throw WaterRenderTargetError.colorAllocationFailed(label: label)
                }
                texture.label = "GMod \(label) water color"
                return texture
            }

            func depthTexture(label: String) throws -> MTLTexture {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: depthPixelFormat,
                    width: width,
                    height: height,
                    mipmapped: false
                )
                descriptor.storageMode = .private
                descriptor.usage = [.renderTarget, .shaderRead]
                guard let texture = device.makeTexture(descriptor: descriptor) else {
                    throw WaterRenderTargetError.depthAllocationFailed(label: label)
                }
                texture.label = "GMod \(label) water depth"
                return texture
            }

            let targets = CachedWaterRenderTargets(
                width: width,
                height: height,
                colorPixelFormat: colorPixelFormat,
                depthPixelFormat: depthPixelFormat,
                refractionColor: try colorTexture(label: "refraction"),
                refractionDepth: try depthTexture(label: "refraction"),
                reflectionColor: try colorTexture(label: "reflection"),
                reflectionDepth: try depthTexture(label: "reflection")
            )
            cachedWaterRenderTargets = targets
            return targets
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
            guard scene.sourceDisplacementAlphas.count ==
                    scene.sourcePositions.count else {
                throw WorldSceneError.displacementAlphaArrayMismatch
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
                let displacementAlpha = scene.sourceDisplacementAlphas[index]
                guard displacementAlpha.isFinite,
                      displacementAlpha >= 0,
                      displacementAlpha <= 255 else {
                    throw WorldSceneError.invalidDisplacementAlpha(index: index)
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
                if let terrain = range.terrainMaterial {
                    let detail = terrain.detail
                    let transition = terrain.vertexTransition
                    let detailTransform = detail?.textureTransform
                    let blendTransform = transition?.blendMaskTransform
                    guard detail?.blendFactor.isFinite ?? true,
                          detailTransform.map(Self.isFinite) ?? true,
                          blendTransform.map(Self.isFinite) ?? true else {
                        throw WorldSceneError.invalidTerrainMaterialRange(
                            index: index
                        )
                    }
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
            if let lighting = scene.environmentLighting {
                guard isFinite(lighting.sourceDirectionFromLight),
                      isFinite(lighting.metalDirectionToLight),
                      isFinite(lighting.directLinearRGB),
                      isFinite(lighting.ambientLinearRGB),
                      simd_length_squared(lighting.metalDirectionToLight) >
                        Float.ulpOfOne,
                      lighting.directLinearRGB.x >= 0,
                      lighting.directLinearRGB.y >= 0,
                      lighting.directLinearRGB.z >= 0,
                      lighting.ambientLinearRGB.x >= 0,
                      lighting.ambientLinearRGB.y >= 0,
                      lighting.ambientLinearRGB.z >= 0 else {
                    throw WorldSceneError.invalidEnvironmentLighting
                }
            }
            for (index, sun) in scene.sunSprites.enumerated() {
                let layers = [sun.core, sun.overlay]
                guard isFinite(sun.sourceDirectionToSun),
                      isFinite(sun.metalDirectionToSun),
                      simd_length_squared(sun.metalDirectionToSun) >
                        Float.ulpOfOne,
                      sun.hdrColorScale.isFinite,
                      sun.hdrColorScale >= 0,
                      sun.hdrColorScale <= 100,
                      layers.allSatisfy({ layer in
                          !layer.materialName.trimmingCharacters(
                              in: .whitespacesAndNewlines
                          ).isEmpty &&
                            layer.size.isFinite && layer.size > 0 &&
                            layer.displayRGB.x.isFinite &&
                            layer.displayRGB.y.isFinite &&
                            layer.displayRGB.z.isFinite &&
                            layer.displayRGB.x >= 0 && layer.displayRGB.x <= 1 &&
                            layer.displayRGB.y >= 0 && layer.displayRGB.y <= 1 &&
                            layer.displayRGB.z >= 0 && layer.displayRGB.z <= 1
                      }) else {
                    throw WorldSceneError.invalidSunSprite(index: index)
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
                if let bitmap = range.terrainMaterial?.detail?.bitmap {
                    required[Self.worldTextureKey(
                        for: bitmap,
                        isSRGB: range.terrainMaterial?.detail?.samplesAsSRGB == true
                    )] = bitmap
                }
                if let bitmap = range.terrainMaterial?.vertexTransition?
                    .baseTexture2Bitmap {
                    required[Self.worldTextureKey(
                        for: bitmap,
                        isSRGB: true
                    )] = bitmap
                }
                if let bitmap = range.terrainMaterial?.vertexTransition?
                    .blendModulateBitmap {
                    required[Self.worldTextureKey(
                        for: bitmap,
                        isSRGB: false
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
            if GModMetalSkyVisibilityRenderContract.draws2D(
                scene.skyboxVisibility
            ) {
                for sun in scene.sunSprites {
                    for layer in [sun.core, sun.overlay] {
                        guard let bitmap = layer.bitmap else { continue }
                        required[Self.worldTextureKey(
                            for: bitmap,
                            isSRGB: true
                        )] = bitmap
                    }
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
            guard scene.verticalFieldOfViewRadians.isFinite,
                  scene.verticalFieldOfViewRadians > 0,
                  scene.verticalFieldOfViewRadians < .pi else {
                throw WorldSceneError.invalidCameraFieldOfView
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

        private static func isFinite(
            _ value: GModMetalWorldUVTransform
        ) -> Bool {
            isFinite(value.row0) && isFinite(value.row1)
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
            applyPendingFirstPersonViewModelScene(
                pendingScenes.firstPersonViewModel
            )
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
                let dynamicEntityPipelines,
                let firstPersonViewModelTexturedPipeline,
                let worldSkyboxPipeline,
                let worldSunSpritePipeline,
                let worldWaterSolidPipeline,
                let worldWaterNormalPipeline,
                let worldWaterCompositeSolidPipeline,
                let worldWaterCompositeNormalPipeline,
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
                drawable.texture.width,
                drawable.texture.height
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
            let worldPair: (scene: GModMetalWorldScene, mesh: CachedWorldMesh)? = {
                guard let scene = activeWorldScene,
                      let mesh = cachedWorldMesh,
                      mesh.identifier == scene.meshIdentifier,
                      mesh.vertexCount == scene.metalPositions.count,
                      mesh.indexCount == scene.indices.count else { return nil }
                return (scene, mesh)
            }()
            var worldUploadBudget = WorldUploadBudget()
            var waterPlan: GModMetalWaterRenderTargetPlan?
            var waterTargets: CachedWaterRenderTargets?
            if let pair = worldPair,
               let plan = GModMetalWaterRenderTargetContract.plan(
                materialRanges: pair.scene.materialRanges,
                cameraZ: pair.scene.cameraEye.z
               ) {
                do {
                    let targets = try waterRenderTargets(
                        device: device,
                        width: Swift.max(1, drawableViewport.x),
                        height: Swift.max(1, drawableViewport.y),
                        colorPixelFormat: drawable.texture.pixelFormat,
                        depthPixelFormat:
                            descriptor.depthAttachment.texture?.pixelFormat ??
                                .depth32Float
                    )
                    waterPlan = plan
                    waterTargets = targets
                    waterRenderTargetIssue = nil
                } catch {
                    waterRenderTargetIssue = String(describing: error)
                }
            } else {
                waterRenderTargetIssue = nil
            }
            let eyeIsBelowPlannedWater: Bool
            if let pair = worldPair, let plan = waterPlan {
                eyeIsBelowPlannedWater =
                    pair.scene.cameraEye.z < plan.sourceSurfaceZ
            } else {
                eyeIsBelowPlannedWater = false
            }

            // The main camera always renders to the drawable. Source creates
            // reflection/refraction views first, but neither view replaces the
            // ordinary scene that receives the translucent water surface.
            let skyDescriptor = descriptor.copy() as! MTLRenderPassDescriptor
            skyDescriptor.colorAttachments[0].storeAction = .store
            skyDescriptor.depthAttachment.storeAction = .dontCare
            var storedSkyColor = false
            if let pair = worldPair {
                worldTextureUploadFailureReason = nil
                guard let skyEncoder = commandBuffer.makeRenderCommandEncoder(
                    descriptor: skyDescriptor
                ) else {
                    worldFramePresentationSink.fail(
                        meshIdentifier: pair.scene.meshIdentifier,
                        reason: .renderEncoderCreationFailed
                    )
                    return
                }
                skyEncoder.setCullMode(.none)
                drawWorldSky(
                    scene: pair.scene,
                    mesh: pair.mesh,
                    viewport: drawableViewport,
                    metalCameraEye: pair.scene.metalCameraEye,
                    metalCameraForward: pair.scene.metalCameraForward,
                    metalCameraUp: pair.scene.metalCameraUp,
                    draws2DSky: !eyeIsBelowPlannedWater,
                    draws3DSky: !eyeIsBelowPlannedWater,
                    rendersWater: waterTargets == nil,
                    device: device,
                    uploadBudget: &worldUploadBudget,
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
                if !eyeIsBelowPlannedWater {
                    drawWorldSunSprites(
                        scene: pair.scene,
                        viewport: drawableViewport,
                        metalCameraEye: pair.scene.metalCameraEye,
                        metalCameraForward: pair.scene.metalCameraForward,
                        metalCameraUp: pair.scene.metalCameraUp,
                        device: device,
                        uploadBudget: &worldUploadBudget,
                        pipeline: worldSunSpritePipeline,
                        depthState: skyboxDepthState,
                        encoder: skyEncoder
                    )
                }
                skyEncoder.endEncoding()
                storedSkyColor = true
            } else {
                worldTextureUploadFailureReason = nil
            }

            let worldDescriptor = skyDescriptor.copy() as! MTLRenderPassDescriptor
            if storedSkyColor {
                worldDescriptor.colorAttachments[0].loadAction = .load
            }
            worldDescriptor.colorAttachments[0].storeAction = .store
            worldDescriptor.depthAttachment.loadAction = .clear
            worldDescriptor.depthAttachment.storeAction =
                waterTargets == nil ? .dontCare : .store
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
            if let pair = worldPair {
                let mainClipPlane = waterPlan.flatMap { plan in
                    eyeIsBelowPlannedWater
                        ? GModMetalWaterClipPlaneContract.underwaterMain(
                            sourceSurfaceZ: plan.sourceSurfaceZ
                        )
                        : nil
                } ?? GModMetalWaterClipPlaneContract.disabled
                let drawResult = drawWorld(
                    scene: pair.scene,
                    mesh: pair.mesh,
                    viewport: drawableViewport,
                    metalCameraEye: pair.scene.metalCameraEye,
                    metalCameraForward: pair.scene.metalCameraForward,
                    metalCameraUp: pair.scene.metalCameraUp,
                    clipPlane: mainClipPlane,
                    rendersWater: waterTargets == nil,
                    drawsDynamicEntities: true,
                    usesWorldVisibility: true,
                    recordsDiagnostics: true,
                    device: device,
                    uploadBudget: &worldUploadBudget,
                    solidPipeline: worldPipeline,
                    texturedPipeline: worldTexturedPipeline,
                    lightmappedPipeline: worldLightmappedPipeline,
                    texturedLightmappedPipeline: worldTexturedLightmappedPipeline,
                    missingMaterialPipeline: worldMissingMaterialPipeline,
                    dynamicEntityPipelines: dynamicEntityPipelines,
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
                        meshIdentifier: pair.scene.meshIdentifier,
                        uploadedTextureCount: drawResult.uploadedTextureCount,
                        requiredTextureCount: drawResult.requiredTextureCount
                    )
                )
                if let failureReason = drawResult.failureReason {
                    worldFramePresentationSink.fail(
                        meshIdentifier: pair.scene.meshIdentifier,
                        reason: failureReason
                    )
                } else if drawResult.isReadyForPresentation {
                    encodedWorldIdentifier = pair.scene.meshIdentifier
                }
            }

            encoder.endEncoding()

            if let pair = worldPair,
               let waterPlan,
               let waterTargets {
                if waterPlan.requiresRefraction {
                    let refractionSkyDescriptor =
                        descriptor.copy() as! MTLRenderPassDescriptor
                    refractionSkyDescriptor.colorAttachments[0].texture =
                        waterTargets.refractionColor
                    refractionSkyDescriptor.colorAttachments[0].loadAction = .clear
                    refractionSkyDescriptor.colorAttachments[0].storeAction = .store
                    refractionSkyDescriptor.depthAttachment.texture =
                        waterTargets.refractionDepth
                    refractionSkyDescriptor.depthAttachment.loadAction = .clear
                    refractionSkyDescriptor.depthAttachment.storeAction = .dontCare

                    let eyeIsBelowWater =
                        pair.scene.cameraEye.z < waterPlan.sourceSurfaceZ
                    if eyeIsBelowWater {
                        guard let refractionSkyEncoder =
                            commandBuffer.makeRenderCommandEncoder(
                                descriptor: refractionSkyDescriptor
                            ) else {
                            worldFramePresentationSink.fail(
                                meshIdentifier: pair.scene.meshIdentifier,
                                reason: .renderEncoderCreationFailed
                            )
                            return
                        }
                        refractionSkyEncoder.setCullMode(.none)
                        drawWorldSky(
                            scene: pair.scene,
                            mesh: pair.mesh,
                            viewport: drawableViewport,
                            metalCameraEye: pair.scene.metalCameraEye,
                            metalCameraForward: pair.scene.metalCameraForward,
                            metalCameraUp: pair.scene.metalCameraUp,
                            draws2DSky: true,
                            draws3DSky: true,
                            rendersWater: false,
                            device: device,
                            uploadBudget: &worldUploadBudget,
                            solidPipeline: worldPipeline,
                            texturedPipeline: worldTexturedPipeline,
                            lightmappedPipeline: worldLightmappedPipeline,
                            texturedLightmappedPipeline:
                                worldTexturedLightmappedPipeline,
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
                            encoder: refractionSkyEncoder
                        )
                        refractionSkyEncoder.endEncoding()
                    }

                    let refractionWorldDescriptor =
                        refractionSkyDescriptor.copy() as! MTLRenderPassDescriptor
                    refractionWorldDescriptor.colorAttachments[0].loadAction =
                        eyeIsBelowWater ? .load : .clear
                    refractionWorldDescriptor.depthAttachment.loadAction = .clear
                    refractionWorldDescriptor.depthAttachment.storeAction = .dontCare
                    guard let refractionEncoder =
                        commandBuffer.makeRenderCommandEncoder(
                            descriptor: refractionWorldDescriptor
                        ) else {
                        worldFramePresentationSink.fail(
                            meshIdentifier: pair.scene.meshIdentifier,
                            reason: .renderEncoderCreationFailed
                        )
                        return
                    }
                    refractionEncoder.setCullMode(.none)
                    _ = drawWorld(
                        scene: pair.scene,
                        mesh: pair.mesh,
                        viewport: drawableViewport,
                        metalCameraEye: pair.scene.metalCameraEye,
                        metalCameraForward: pair.scene.metalCameraForward,
                        metalCameraUp: pair.scene.metalCameraUp,
                        clipPlane: GModMetalWaterClipPlaneContract.refraction(
                            sourceSurfaceZ: waterPlan.sourceSurfaceZ,
                            sourceCameraZ: pair.scene.cameraEye.z
                        ),
                        waterRefractionFog: waterPlan.refractionFog,
                        rendersWater: false,
                        drawsDynamicEntities: true,
                        usesWorldVisibility: false,
                        recordsDiagnostics: false,
                        device: device,
                        uploadBudget: &worldUploadBudget,
                        solidPipeline: worldPipeline,
                        texturedPipeline: worldTexturedPipeline,
                        lightmappedPipeline: worldLightmappedPipeline,
                        texturedLightmappedPipeline:
                            worldTexturedLightmappedPipeline,
                        missingMaterialPipeline: worldMissingMaterialPipeline,
                        dynamicEntityPipelines: dynamicEntityPipelines,
                        skyboxPipeline: worldSkyboxPipeline,
                        waterSolidPipeline: worldWaterSolidPipeline,
                        waterNormalPipeline: worldWaterNormalPipeline,
                        worldDepthState: depthState,
                        skyboxDepthState: skyboxDepthState,
                        waterDepthState: waterDepthState,
                        worldSampler: worldSamplerState,
                        lightmapSampler: worldLightmapSamplerState,
                        skyboxSampler: skyboxSamplerState,
                        encoder: refractionEncoder
                    )
                    refractionEncoder.endEncoding()
                }

                if waterPlan.requiresReflection {
                    let reflected =
                        GModMetalWaterReflectionContract.reflectedCamera(
                            eye: pair.scene.metalCameraEye,
                            forward: pair.scene.metalCameraForward,
                            up: pair.scene.metalCameraUp,
                            sourceSurfaceZ: waterPlan.sourceSurfaceZ
                        )
                    let reflectionSkyDescriptor =
                        descriptor.copy() as! MTLRenderPassDescriptor
                    reflectionSkyDescriptor.colorAttachments[0].texture =
                        waterTargets.reflectionColor
                    reflectionSkyDescriptor.colorAttachments[0].storeAction = .store
                    reflectionSkyDescriptor.depthAttachment.texture =
                        waterTargets.reflectionDepth
                    reflectionSkyDescriptor.depthAttachment.storeAction = .dontCare
                    guard let reflectionSkyEncoder =
                        commandBuffer.makeRenderCommandEncoder(
                            descriptor: reflectionSkyDescriptor
                        ) else {
                        worldFramePresentationSink.fail(
                            meshIdentifier: pair.scene.meshIdentifier,
                            reason: .renderEncoderCreationFailed
                        )
                        return
                    }
                    reflectionSkyEncoder.setCullMode(.none)
                    drawWorldSky(
                        scene: pair.scene,
                        mesh: pair.mesh,
                        viewport: drawableViewport,
                        metalCameraEye: reflected.eye,
                        metalCameraForward: reflected.forward,
                        metalCameraUp: reflected.up,
                        draws2DSky: true,
                        draws3DSky: false,
                        rendersWater: false,
                        device: device,
                        uploadBudget: &worldUploadBudget,
                        solidPipeline: worldPipeline,
                        texturedPipeline: worldTexturedPipeline,
                        lightmappedPipeline: worldLightmappedPipeline,
                        texturedLightmappedPipeline:
                            worldTexturedLightmappedPipeline,
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
                        encoder: reflectionSkyEncoder
                    )
                    drawWorldSunSprites(
                        scene: pair.scene,
                        viewport: drawableViewport,
                        metalCameraEye: reflected.eye,
                        metalCameraForward: reflected.forward,
                        metalCameraUp: reflected.up,
                        device: device,
                        uploadBudget: &worldUploadBudget,
                        pipeline: worldSunSpritePipeline,
                        depthState: skyboxDepthState,
                        encoder: reflectionSkyEncoder
                    )
                    reflectionSkyEncoder.endEncoding()

                    let reflectionWorldDescriptor =
                        reflectionSkyDescriptor.copy()
                            as! MTLRenderPassDescriptor
                    reflectionWorldDescriptor.colorAttachments[0].loadAction = .load
                    reflectionWorldDescriptor.depthAttachment.loadAction = .clear
                    reflectionWorldDescriptor.depthAttachment.storeAction = .store
                    guard let reflectionEncoder =
                        commandBuffer.makeRenderCommandEncoder(
                            descriptor: reflectionWorldDescriptor
                        ) else {
                        worldFramePresentationSink.fail(
                            meshIdentifier: pair.scene.meshIdentifier,
                            reason: .renderEncoderCreationFailed
                        )
                        return
                    }
                    reflectionEncoder.setCullMode(.none)
                    _ = drawWorld(
                        scene: pair.scene,
                        mesh: pair.mesh,
                        viewport: drawableViewport,
                        metalCameraEye: reflected.eye,
                        metalCameraForward: reflected.forward,
                        metalCameraUp: reflected.up,
                        clipPlane:
                            GModMetalWaterClipPlaneContract.reflection(
                                sourceSurfaceZ: waterPlan.sourceSurfaceZ,
                                sourceCameraZ: pair.scene.cameraEye.z
                        ),
                        rendersWater: false,
                        drawsDynamicEntities:
                            waterPlan.drawsReflectedDynamicEntities,
                        usesWorldVisibility: false,
                        recordsDiagnostics: false,
                        device: device,
                        uploadBudget: &worldUploadBudget,
                        solidPipeline: worldPipeline,
                        texturedPipeline: worldTexturedPipeline,
                        lightmappedPipeline: worldLightmappedPipeline,
                        texturedLightmappedPipeline:
                            worldTexturedLightmappedPipeline,
                        missingMaterialPipeline: worldMissingMaterialPipeline,
                        dynamicEntityPipelines: dynamicEntityPipelines,
                        skyboxPipeline: worldSkyboxPipeline,
                        waterSolidPipeline: worldWaterSolidPipeline,
                        waterNormalPipeline: worldWaterNormalPipeline,
                        worldDepthState: depthState,
                        skyboxDepthState: skyboxDepthState,
                        waterDepthState: waterDepthState,
                        worldSampler: worldSamplerState,
                        lightmapSampler: worldLightmapSamplerState,
                        skyboxSampler: skyboxSamplerState,
                        encoder: reflectionEncoder
                    )
                    reflectionEncoder.endEncoding()
                }

                let compositeDescriptor =
                    descriptor.copy() as! MTLRenderPassDescriptor
                compositeDescriptor.colorAttachments[0].texture = drawable.texture
                compositeDescriptor.colorAttachments[0].loadAction = .load
                compositeDescriptor.colorAttachments[0].storeAction = .store
                compositeDescriptor.depthAttachment.loadAction = .load
                compositeDescriptor.depthAttachment.storeAction = .dontCare
                guard let compositeEncoder =
                    commandBuffer.makeRenderCommandEncoder(
                        descriptor: compositeDescriptor
                    ) else {
                    worldFramePresentationSink.fail(
                        meshIdentifier: pair.scene.meshIdentifier,
                        reason: .renderEncoderCreationFailed
                    )
                    return
                }
                compositeEncoder.setCullMode(.none)
                drawWorldWaterComposite(
                    scene: pair.scene,
                    mesh: pair.mesh,
                    plan: waterPlan,
                    targets: waterTargets,
                    viewport: drawableViewport,
                    device: device,
                    uploadBudget: &worldUploadBudget,
                    solidPipeline: worldWaterCompositeSolidPipeline,
                    normalPipeline: worldWaterCompositeNormalPipeline,
                    waterDepthState: waterDepthState,
                    worldSampler: worldSamplerState,
                    encoder: compositeEncoder
                )
                compositeEncoder.endEncoding()
            }

            // Viewmodels have a camera-space projection and a fresh depth
            // lifetime after the completed world/water image. VGUI remains
            // last and uses its depth-disabled surface contract.
            let foregroundDescriptor =
                descriptor.copy() as! MTLRenderPassDescriptor
            foregroundDescriptor.colorAttachments[0].texture = drawable.texture
            foregroundDescriptor.colorAttachments[0].loadAction = .load
            foregroundDescriptor.colorAttachments[0].storeAction = .store
            foregroundDescriptor.depthAttachment.loadAction = .clear
            foregroundDescriptor.depthAttachment.storeAction = .dontCare
            guard let foregroundEncoder =
                commandBuffer.makeRenderCommandEncoder(
                    descriptor: foregroundDescriptor
                ) else {
                if let meshIdentifier = activeWorldScene?.meshIdentifier {
                    worldFramePresentationSink.fail(
                        meshIdentifier: meshIdentifier,
                        reason: .renderEncoderCreationFailed
                    )
                }
                return
            }
            if let viewModel = activeFirstPersonViewModelScene {
                drawFirstPersonViewModel(
                    scene: viewModel,
                    sourceFixedTime: activeWorldScene?.sourceFixedTime ?? 0,
                    viewport: drawableViewport,
                    device: device,
                    texturedPipeline: firstPersonViewModelTexturedPipeline,
                    depthState: depthState,
                    encoder: foregroundEncoder
                )
            } else {
                lastFirstPersonViewModelRangeDrawCount = 0
            }
            if let surfaceScene = activeSurfaceScene {
                lastSurfaceDrawCount = drawSurface(
                    scene: surfaceScene,
                    device: device,
                    solidPipeline: surfaceSolidPipeline,
                    texturedPipeline: surfaceTexturedPipeline,
                    depthState: surfaceDepthState,
                    samplers: surfaceSamplerStates,
                    encoder: foregroundEncoder
                )
            } else {
                lastSurfaceDrawCount = 0
                lastSurfaceDroppedDrawCount = 0
            }
            foregroundEncoder.endEncoding()

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
            metalCameraEye: SIMD3<Float>,
            metalCameraForward: SIMD3<Float>,
            metalCameraUp: SIMD3<Float>,
            draws2DSky: Bool,
            draws3DSky: Bool,
            rendersWater: Bool,
            device: MTLDevice,
            uploadBudget: inout WorldUploadBudget,
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
                verticalFieldOfViewRadians:
                    scene.verticalFieldOfViewRadians,
                aspect: Float(width) / Float(height),
                near: 1,
                far: 65_536
            )
            encoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)

            func setUniforms(
                eye: SIMD3<Float>,
                projection: simd_float4x4,
                fog: GModMetalSky3DFogUniforms? = nil
            ) {
                let view = Self.makeViewMatrix(
                    eye: eye,
                    forward: metalCameraForward,
                    up: metalCameraUp
                )
                let lighting = scene.environmentLighting
                let lightDirection = lighting?.metalDirectionToLight ?? .zero
                let direct = lighting?.directLinearRGB ?? .zero
                let ambient = lighting?.ambientLinearRGB ?? .zero
                var uniforms = WorldUniforms(
                    viewProjection: simd_mul(projection, view),
                    lightDirection: SIMD4<Float>(
                        lightDirection.x,
                        lightDirection.y,
                        lightDirection.z,
                        lighting == nil ? 0 : 1
                    ),
                    directLinearRGB: SIMD4<Float>(
                        direct.x, direct.y, direct.z, 0
                    ),
                    ambientLinearRGB: SIMD4<Float>(
                        ambient.x, ambient.y, ambient.z, 0
                    ),
                    clipPlane: GModMetalWaterClipPlaneContract.disabled,
                    fog: fog
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

            let includes2DSky = draws2DSky &&
                GModMetalSkyVisibilityRenderContract.draws2D(
                    scene.skyboxVisibility
                )
            let skyboxRanges = includes2DSky
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

            guard draws3DSky,
                  GModMetalSkyVisibilityRenderContract.draws3D(
                scene.skyboxVisibility
            ) else { return }

            let sky3DRanges = scene.materialRanges.enumerated().filter {
                $0.element.renderLayer == .sky3D &&
                    $0.element.waterSurface == nil
            }
            let sky3DWaterRanges = scene.materialRanges.filter {
                $0.renderLayer == .sky3D && $0.waterSurface != nil
            }
            guard !sky3DRanges.isEmpty || !sky3DWaterRanges.isEmpty,
                  let sky3D = scene.sky3D else { return }
            let clipPlanes = GModMetalSky3DProjectionContract.bakedClipPlanes(
                scale: sky3D.scale
            )
            let aspect = Float(width) / Float(height)
            let sky3DProjection = Self.makePerspectiveMatrix(
                verticalFieldOfViewRadians:
                    scene.verticalFieldOfViewRadians,
                aspect: aspect,
                near: clipPlanes.near,
                far: clipPlanes.far
            )
            let appliesSky3DVisibility: Bool
            if let visibility = scene.sky3DVisibility {
                appliesSky3DVisibility = sky3DVisibilityWorkspace.update(
                    scene: scene,
                    visibility: visibility.bspVisibility,
                    renderLayer: .sky3D,
                    sourceCameraEye: visibility.sourceVisibilityOrigin,
                    metalCameraEye: metalCameraEye,
                    metalCameraForward: metalCameraForward,
                    metalCameraUp: metalCameraUp,
                    verticalFieldOfViewRadians:
                        scene.verticalFieldOfViewRadians,
                    aspectRatio: aspect,
                    nearPlane: clipPlanes.near,
                    farPlane: clipPlanes.far
                )
            } else {
                appliesSky3DVisibility = false
            }
            let sky3DFog = sky3D.fog.flatMap {
                GModMetalSky3DFogContract.uniforms(
                    fog: $0,
                    sourceCameraForward: scene.cameraForward,
                    metalCameraEye: metalCameraEye,
                    metalCameraForward: metalCameraForward
                )
            }
            setUniforms(
                eye: metalCameraEye,
                projection: sky3DProjection,
                fog: sky3DFog
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
            var visibleDrawSpanCursor = 0
            for (materialRangeIndex, range) in sky3DRanges {
                var firstVisibleDrawSpan = visibleDrawSpanCursor
                if appliesSky3DVisibility {
                    while visibleDrawSpanCursor <
                            sky3DVisibilityWorkspace.visibleDrawSpans.count,
                          sky3DVisibilityWorkspace.visibleDrawSpans[
                            visibleDrawSpanCursor
                          ].materialRangeIndex < materialRangeIndex {
                        visibleDrawSpanCursor += 1
                    }
                    firstVisibleDrawSpan = visibleDrawSpanCursor
                    while visibleDrawSpanCursor <
                            sky3DVisibilityWorkspace.visibleDrawSpans.count,
                          sky3DVisibilityWorkspace.visibleDrawSpans[
                            visibleDrawSpanCursor
                          ].materialRangeIndex == materialRangeIndex {
                        visibleDrawSpanCursor += 1
                    }
                    guard firstVisibleDrawSpan < visibleDrawSpanCursor else {
                        continue
                    }
                }
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
                    bindWorldTerrainMaterial(
                        range: range,
                        fallbackTexture: texture,
                        device: device,
                        uploadBudget: &uploadBudget,
                        defaultSampler: worldSampler,
                        encoder: encoder
                    )
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
                if appliesSky3DVisibility {
                    for index in firstVisibleDrawSpan..<visibleDrawSpanCursor {
                        let span = sky3DVisibilityWorkspace.visibleDrawSpans[index]
                        encoder.drawIndexedPrimitives(
                            type: .triangle,
                            indexCount: span.indexCount,
                            indexType: .uint32,
                            indexBuffer: mesh.indexBuffer,
                            indexBufferOffset: span.firstIndex *
                                MemoryLayout<UInt32>.stride
                        )
                    }
                } else {
                    draw(range)
                }
            }

            guard rendersWater else { return }
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
                      ), material.reflectionAmount != nil ||
                        material.refractionAmount != nil else { continue }
                let angleRadians = (material.textureScrollAngleDegrees ?? 0) *
                    .pi / 180
                let direction = SIMD2<Float>(
                    cos(angleRadians),
                    sin(angleRadians)
                )
                let targetFlags: Float =
                    (material.reflectionAmount == nil ? 0 : 1) +
                    (material.refractionAmount == nil ? 0 : 2)
                let hasValidWaterFog = material.fogEnabled == true &&
                    material.fogStart != nil && material.fogEnd != nil &&
                    material.fogEnd! > material.fogStart!
                var uniforms = WorldWaterUniforms(
                    fogColorAndAlpha: SIMD4<Float>(
                        material.fogColor,
                        1
                    ),
                    scrollDirectionRateAndTime: SIMD4<Float>(
                        direction.x,
                        direction.y,
                        material.textureScrollRate ?? 0,
                        scene.sourceFixedTime
                    ),
                    sourceAmountsAndViewport: SIMD4<Float>(
                        material.reflectionAmount ?? 0,
                        material.refractionAmount ?? 0,
                        Float(width),
                        Float(height)
                    ),
                    cameraEyeAndTargetFlags: SIMD4<Float>(
                        metalCameraEye,
                        targetFlags
                    ),
                    fogStartEndAboveAndEnabled: SIMD4<Float>(
                        material.fogStart ?? 0,
                        material.fogEnd ?? 0,
                        material.isAboveWater ? 1 : 0,
                        hasValidWaterFog ? 1 : 0
                    ),
                    cameraForwardAndDistortionEncoding: SIMD4<Float>(
                        metalCameraForward,
                        material.distortionEncoding == .duDvRG ? 2 :
                            material.distortionEncoding == .tangentSpaceNormal
                                ? 1 : 0
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

        /// Draws Source's two directional `env_sun` glow layers after the
        /// completed 2D/3D sky. The next ordinary-world pass clears depth and
        /// overwrites these pixels with BSP/Studio geometry, reproducing the
        /// sky-only obstruction boundary without a fabricated screen position.
        private func drawWorldSunSprites(
            scene: GModMetalWorldScene,
            viewport: SIMD2<Int>,
            metalCameraEye: SIMD3<Float>,
            metalCameraForward: SIMD3<Float>,
            metalCameraUp: SIMD3<Float>,
            device: MTLDevice,
            uploadBudget: inout WorldUploadBudget,
            pipeline: MTLRenderPipelineState,
            depthState: MTLDepthStencilState,
            encoder: MTLRenderCommandEncoder
        ) {
            guard GModMetalSkyVisibilityRenderContract.draws2D(
                scene.skyboxVisibility
            ), !scene.sunSprites.isEmpty else { return }
            let width = Swift.max(1, viewport.x)
            let height = Swift.max(1, viewport.y)
            let projection = Self.makePerspectiveMatrix(
                verticalFieldOfViewRadians:
                    scene.verticalFieldOfViewRadians,
                aspect: Float(width) / Float(height),
                near: 1,
                far: 65_536
            )
            let view = Self.makeViewMatrix(
                eye: metalCameraEye,
                forward: metalCameraForward,
                up: metalCameraUp
            )
            let viewProjection = simd_mul(projection, view)
            encoder.setRenderPipelineState(pipeline)
            encoder.setDepthStencilState(depthState)

            for sun in scene.sunSprites {
                for (layer, role) in [
                    (sun.core, GModMetalSunSpriteLayerRole.core),
                    (sun.overlay, GModMetalSunSpriteLayerRole.overlay),
                ] {
                    guard let bitmap = layer.bitmap,
                          let parameters =
                            GModMetalSunSpriteRenderContract.parameters(
                                sun: sun,
                                layer: layer,
                                role: role,
                                cameraEye: metalCameraEye,
                                cameraForward: metalCameraForward
                            ),
                          let texture = worldTexture(
                            for: bitmap,
                            device: device,
                            uploadBudget: &uploadBudget
                          ) else { continue }
                    let configuration = GModMetalWorldSamplerConfiguration(
                        bitmap: bitmap,
                        renderLayer: .sky2D
                    )
                    guard let sampler = samplerStateForWorldTexture(
                        for: configuration,
                        device: device
                    ) else { continue }
                    var uniforms = WorldSunSpriteUniforms(
                        viewProjection: viewProjection,
                        basePosition: SIMD4<Float>(parameters.basePosition, 1),
                        rightExtent: SIMD4<Float>(parameters.rightExtent, 0),
                        upExtent: SIMD4<Float>(parameters.upExtent, 0),
                        displayRGBAndOpacity: SIMD4<Float>(
                            parameters.displayRGB,
                            parameters.opacity
                        ),
                        hdrColorScale: SIMD4<Float>(
                            parameters.hdrColorScale,
                            0,
                            0,
                            0
                        )
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
                    encoder.setFragmentTexture(texture, index: 0)
                    encoder.setFragmentSamplerState(sampler, index: 0)
                    encoder.drawPrimitives(
                        type: .triangleStrip,
                        vertexStart: 0,
                        vertexCount: 4
                    )
                }
            }
        }

        private func drawWorld(
            scene: GModMetalWorldScene,
            mesh: CachedWorldMesh,
            viewport: SIMD2<Int>,
            metalCameraEye: SIMD3<Float>,
            metalCameraForward: SIMD3<Float>,
            metalCameraUp: SIMD3<Float>,
            clipPlane: SIMD4<Float>,
            waterRefractionFog: GModMetalWaterRefractionFog? = nil,
            rendersWater: Bool,
            drawsDynamicEntities: Bool,
            usesWorldVisibility: Bool,
            recordsDiagnostics: Bool,
            device: MTLDevice,
            uploadBudget: inout WorldUploadBudget,
            solidPipeline: MTLRenderPipelineState,
            texturedPipeline: MTLRenderPipelineState,
            lightmappedPipeline: MTLRenderPipelineState,
            texturedLightmappedPipeline: MTLRenderPipelineState,
            missingMaterialPipeline: MTLRenderPipelineState,
            dynamicEntityPipelines: DynamicEntityRenderPipelines,
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
                verticalFieldOfViewRadians:
                    scene.verticalFieldOfViewRadians,
                aspect: aspect,
                near: 1,
                far: 65_536
            )

            encoder.setVertexBuffer(
                mesh.vertexBuffer,
                offset: 0,
                index: 0
            )
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
            let appliesWorldVisibility = usesWorldVisibility &&
                scene.worldVisibility != nil &&
                worldVisibilityWorkspace.update(
                    scene: scene,
                    sourceCameraEye: scene.cameraEye,
                    metalCameraEye: metalCameraEye,
                    metalCameraForward: metalCameraForward,
                    metalCameraUp: metalCameraUp,
                    verticalFieldOfViewRadians:
                        scene.verticalFieldOfViewRadians,
                    aspectRatio: aspect,
                    nearPlane: 1,
                    farPlane: 65_536
                )
            if recordsDiagnostics {
                lastWorldVisibilityMetrics = appliesWorldVisibility
                    ? worldVisibilityWorkspace.metrics
                    : nil
                lastWorldVisibilityWasFailOpen = usesWorldVisibility &&
                    scene.worldVisibility != nil &&
                    !appliesWorldVisibility
            }

            func setUniforms(eye: SIMD3<Float>) {
                let view = Self.makeViewMatrix(
                    eye: eye,
                    forward: metalCameraForward,
                    up: metalCameraUp
                )
                let lighting = scene.environmentLighting
                let lightDirection = lighting?.metalDirectionToLight ?? .zero
                let direct = lighting?.directLinearRGB ?? .zero
                let ambient = lighting?.ambientLinearRGB ?? .zero
                var uniforms = WorldUniforms(
                    viewProjection: simd_mul(projection, view),
                    lightDirection: SIMD4<Float>(
                        lightDirection.x,
                        lightDirection.y,
                        lightDirection.z,
                        lighting == nil ? 0 : 1
                    ),
                    directLinearRGB: SIMD4<Float>(
                        direct.x, direct.y, direct.z, 0
                    ),
                    ambientLinearRGB: SIMD4<Float>(
                        ambient.x, ambient.y, ambient.z, 0
                    ),
                    clipPlane: clipPlane,
                    waterRefractionFog: waterRefractionFog,
                    waterFogCameraEye: eye,
                    waterFogCameraForward: metalCameraForward
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

            func draw(firstIndex: Int, indexCount: Int) {
                encoder.drawIndexedPrimitives(
                    type: .triangle,
                    indexCount: indexCount,
                    indexType: .uint32,
                    indexBuffer: mesh.indexBuffer,
                    indexBufferOffset: firstIndex * MemoryLayout<UInt32>.stride
                )
            }

            func draw(_ range: GModMetalWorldMaterialRange) {
                draw(firstIndex: range.firstIndex, indexCount: range.indexCount)
            }

            setUniforms(eye: metalCameraEye)
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
            var visibleDrawSpanCursor = 0
            for (materialRangeIndex, range) in ranges.enumerated() where
                range.renderLayer == .world && range.waterSurface == nil {
                var firstVisibleDrawSpan = visibleDrawSpanCursor
                if appliesWorldVisibility {
                    while visibleDrawSpanCursor <
                            worldVisibilityWorkspace.visibleDrawSpans.count,
                          worldVisibilityWorkspace.visibleDrawSpans[
                            visibleDrawSpanCursor
                          ].materialRangeIndex < materialRangeIndex {
                        visibleDrawSpanCursor += 1
                    }
                    firstVisibleDrawSpan = visibleDrawSpanCursor
                    while visibleDrawSpanCursor <
                            worldVisibilityWorkspace.visibleDrawSpans.count,
                          worldVisibilityWorkspace.visibleDrawSpans[
                            visibleDrawSpanCursor
                          ].materialRangeIndex == materialRangeIndex {
                        visibleDrawSpanCursor += 1
                    }
                    guard firstVisibleDrawSpan < visibleDrawSpanCursor else {
                        continue
                    }
                }
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
                        bindWorldTerrainMaterial(
                            range: range,
                            fallbackTexture: texture,
                            device: device,
                            uploadBudget: &uploadBudget,
                            defaultSampler: worldSampler,
                            encoder: encoder
                        )
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
                if appliesWorldVisibility {
                    for index in firstVisibleDrawSpan..<visibleDrawSpanCursor {
                        let span = worldVisibilityWorkspace.visibleDrawSpans[index]
                        draw(
                            firstIndex: span.firstIndex,
                            indexCount: span.indexCount
                        )
                    }
                } else {
                    draw(range)
                }
            }

            // Fixed-mode Source entities draw after opaque BSP. Normal models
            // write world depth; supported translucent/additive models only
            // test it. Water remains a later, separately composited pass.
            if drawsDynamicEntities, let dynamicScene = activeDynamicEntityScene {
                drawDynamicEntities(
                    scene: dynamicScene,
                    device: device,
                    pipelines: dynamicEntityPipelines,
                    opaqueDepthState: worldDepthState,
                    translucentDepthState: waterDepthState,
                    encoder: encoder
                )
                // Water ranges are indexed against the BSP-local buffers.
                encoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
            } else if recordsDiagnostics {
                lastDynamicEntityInstanceDrawCount = 0
                lastDynamicEntityRangeDrawCount = 0
                lastDynamicEntityCheckerRangeCount = 0
            }

            var waterRenderedRangeCount = 0
            var waterNormalMappedRangeCount = 0
            var waterMissingMaterialRangeCount = 0
            var waterPendingNormalRangeCount = 0
            if rendersWater {
                encoder.setDepthStencilState(waterDepthState)
                encoder.setFragmentSamplerState(worldSampler, index: 0)
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

                guard material.reflectionAmount != nil ||
                        material.refractionAmount != nil else {
                    waterMissingMaterialRangeCount += 1
                    continue
                }
                let angleRadians = (material.textureScrollAngleDegrees ?? 0) *
                    .pi / 180
                let direction = SIMD2<Float>(
                    cos(angleRadians),
                    sin(angleRadians)
                )
                let targetFlags: Float =
                    (material.reflectionAmount == nil ? 0 : 1) +
                    (material.refractionAmount == nil ? 0 : 2)
                let hasValidWaterFog = material.fogEnabled == true &&
                    material.fogStart != nil && material.fogEnd != nil &&
                    material.fogEnd! > material.fogStart!
                var uniforms = WorldWaterUniforms(
                    fogColorAndAlpha: SIMD4<Float>(
                        material.fogColor,
                        1
                    ),
                    scrollDirectionRateAndTime: SIMD4<Float>(
                        direction.x,
                        direction.y,
                        material.textureScrollRate ?? 0,
                        scene.sourceFixedTime
                    ),
                    sourceAmountsAndViewport: SIMD4<Float>(
                        material.reflectionAmount ?? 0,
                        material.refractionAmount ?? 0,
                        Float(width),
                        Float(height)
                    ),
                    cameraEyeAndTargetFlags: SIMD4<Float>(
                        metalCameraEye,
                        targetFlags
                    ),
                    fogStartEndAboveAndEnabled: SIMD4<Float>(
                        material.fogStart ?? 0,
                        material.fogEnd ?? 0,
                        material.isAboveWater ? 1 : 0,
                        hasValidWaterFog ? 1 : 0
                    ),
                    cameraForwardAndDistortionEncoding: SIMD4<Float>(
                        metalCameraForward,
                        material.distortionEncoding == .duDvRG ? 2 :
                            material.distortionEncoding == .tangentSpaceNormal
                                ? 1 : 0
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
            }
            if recordsDiagnostics {
                lastWorldTexturedRangeCount = texturedRangeCount
                lastWorldMissingMaterialRangeCount = missingRangeCount
                lastWorldPendingTextureRangeCount = pendingRangeCount
                lastWorldLightmappedRangeCount = lightmappedRangeCount
                lastWaterRenderedRangeCount = waterRenderedRangeCount
                lastWaterNormalMappedRangeCount = waterNormalMappedRangeCount
                lastWaterMissingMaterialRangeCount = waterMissingMaterialRangeCount
                lastWaterPendingNormalRangeCount = waterPendingNormalRangeCount
                lastWaterRenderTargetRangeCount = 0
            }

            let requiredTextures = requiredWorldTextures(for: scene)
            // PVS-hidden ranges no longer reach the draw loop, but the
            // established presentation contract still waits for every
            // retained texture in the immutable scene. Use any remaining
            // one-texture frame budget to make those uploads progress.
            for (key, bitmap) in requiredTextures {
                if let cached = cachedWorldTextures[key],
                   cached.bitmap == bitmap {
                    continue
                }
                _ = worldTexture(
                    for: bitmap,
                    device: device,
                    uploadBudget: &uploadBudget,
                    isSRGB: key.hasPrefix("srgb:")
                )
            }
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

        private func drawWorldWaterComposite(
            scene: GModMetalWorldScene,
            mesh: CachedWorldMesh,
            plan: GModMetalWaterRenderTargetPlan,
            targets: CachedWaterRenderTargets,
            viewport: SIMD2<Int>,
            device: MTLDevice,
            uploadBudget: inout WorldUploadBudget,
            solidPipeline: MTLRenderPipelineState,
            normalPipeline: MTLRenderPipelineState,
            waterDepthState: MTLDepthStencilState,
            worldSampler: MTLSamplerState,
            encoder: MTLRenderCommandEncoder
        ) {
            let width = Swift.max(1, viewport.x)
            let height = Swift.max(1, viewport.y)
            let projection = Self.makePerspectiveMatrix(
                verticalFieldOfViewRadians:
                    scene.verticalFieldOfViewRadians,
                aspect: Float(width) / Float(height),
                near: 1,
                far: 65_536
            )
            let view = Self.makeViewMatrix(
                eye: scene.metalCameraEye,
                forward: scene.metalCameraForward,
                up: scene.metalCameraUp
            )
            let lighting = scene.environmentLighting
            let lightDirection = lighting?.metalDirectionToLight ?? .zero
            let direct = lighting?.directLinearRGB ?? .zero
            let ambient = lighting?.ambientLinearRGB ?? .zero
            var worldUniforms = WorldUniforms(
                viewProjection: simd_mul(projection, view),
                lightDirection: SIMD4<Float>(
                    lightDirection.x,
                    lightDirection.y,
                    lightDirection.z,
                    lighting == nil ? 0 : 1
                ),
                directLinearRGB: SIMD4<Float>(direct.x, direct.y, direct.z, 0),
                ambientLinearRGB: SIMD4<Float>(ambient.x, ambient.y, ambient.z, 0),
                clipPlane: GModMetalWaterClipPlaneContract.disabled
            )
            withUnsafeBytes(of: &worldUniforms) { bytes in
                guard let address = bytes.baseAddress else { return }
                encoder.setVertexBytes(address, length: bytes.count, index: 1)
                encoder.setFragmentBytes(address, length: bytes.count, index: 1)
            }
            encoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
            encoder.setDepthStencilState(waterDepthState)
            encoder.setFragmentTexture(
                plan.requiresRefraction
                    ? targets.refractionColor
                    : targets.reflectionColor,
                index: 2
            )
            encoder.setFragmentTexture(
                plan.requiresReflection
                    ? targets.reflectionColor
                    : targets.refractionColor,
                index: 3
            )

            var rendered = 0
            var normalMapped = 0
            var missing = 0
            var pendingNormal = 0
            for range in scene.materialRanges where
                range.renderLayer == .world && range.waterSurface != nil {
                guard let surface = range.waterSurface,
                      surface.surfaceZ.bitPattern == plan.sourceSurfaceZ.bitPattern,
                      let material = range.waterMaterial else {
                    missing += 1
                    continue
                }
                guard GModMetalWaterRenderContract.shouldRender(
                    material,
                    surface: surface,
                    cameraZ: scene.cameraEye.z
                ) else { continue }
                let reflectionAmount = material.reflectionAmount ?? 0
                let refractionAmount = material.refractionAmount ?? 0
                guard material.reflectionAmount != nil ||
                        material.refractionAmount != nil else {
                    missing += 1
                    continue
                }
                let angleRadians = (material.textureScrollAngleDegrees ?? 0) *
                    .pi / 180
                let direction = SIMD2<Float>(
                    cos(angleRadians),
                    sin(angleRadians)
                )
                let targetFlags = Float(plan.targetFlags(for: material))
                let hasAuthoredWaterFog = material.fogEnabled == true &&
                    material.fogStart != nil && material.fogEnd != nil &&
                    material.fogEnd! > material.fogStart!
                let hasRenderableWaterFog = hasAuthoredWaterFog &&
                    (!material.isAboveWater || plan.refractionFog != nil)
                var waterUniforms = WorldWaterUniforms(
                    fogColorAndAlpha: SIMD4<Float>(
                        material.fogColor,
                        1
                    ),
                    scrollDirectionRateAndTime: SIMD4<Float>(
                        direction.x,
                        direction.y,
                        material.textureScrollRate ?? 0,
                        scene.sourceFixedTime
                    ),
                    sourceAmountsAndViewport: SIMD4<Float>(
                        reflectionAmount,
                        refractionAmount,
                        Float(width),
                        Float(height)
                    ),
                    cameraEyeAndTargetFlags: SIMD4<Float>(
                        scene.metalCameraEye,
                        targetFlags
                    ),
                    fogStartEndAboveAndEnabled: SIMD4<Float>(
                        material.fogStart ?? 0,
                        material.fogEnd ?? 0,
                        material.isAboveWater ? 1 : 0,
                        hasRenderableWaterFog ? 1 : 0
                    ),
                    cameraForwardAndDistortionEncoding: SIMD4<Float>(
                        scene.metalCameraForward,
                        material.distortionEncoding == .duDvRG ? 2 :
                            material.distortionEncoding == .tangentSpaceNormal
                                ? 1 : 0
                    )
                )
                withUnsafeBytes(of: &waterUniforms) { bytes in
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
                        encoder.setRenderPipelineState(normalPipeline)
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
                        } else {
                            encoder.setFragmentSamplerState(worldSampler, index: 0)
                        }
                        normalMapped += 1
                    } else {
                        encoder.setRenderPipelineState(solidPipeline)
                        encoder.setFragmentTexture(nil, index: 0)
                        pendingNormal += 1
                    }
                } else {
                    encoder.setRenderPipelineState(solidPipeline)
                    encoder.setFragmentTexture(nil, index: 0)
                }
                encoder.drawIndexedPrimitives(
                    type: .triangle,
                    indexCount: range.indexCount,
                    indexType: .uint32,
                    indexBuffer: mesh.indexBuffer,
                    indexBufferOffset:
                        range.firstIndex * MemoryLayout<UInt32>.stride
                )
                rendered += 1
            }
            lastWaterRenderedRangeCount = rendered
            lastWaterNormalMappedRangeCount = normalMapped
            lastWaterMissingMaterialRangeCount = missing
            lastWaterPendingNormalRangeCount = pendingNormal
            lastWaterRenderTargetRangeCount = rendered
        }

        private func drawFirstPersonViewModel(
            scene: GModMetalFirstPersonViewModelScene,
            sourceFixedTime: Float,
            viewport: SIMD2<Int>,
            device: MTLDevice,
            texturedPipeline: MTLRenderPipelineState,
            depthState: MTLDepthStencilState,
            encoder: MTLRenderCommandEncoder
        ) {
            let resource = scene.resource
            if let cached = cachedFirstPersonViewModelGeometry,
               !GModMetalStudioGeometryCacheContract.canReuseGeometry(
                   cachedID: cached.resourceID,
                   cachedVertexCount: cached.vertexCount,
                   cachedIndexCount: cached.indexCount,
                   publishedID: resource.id,
                   publishedVertexCount: resource.vertices.count,
                   publishedIndexCount: resource.indices.count
               ) {
                cachedFirstPersonViewModelGeometry = nil
            }
            if cachedFirstPersonViewModelGeometry == nil {
                cachedFirstPersonViewModelGeometry =
                    makeFirstPersonViewModelGeometry(
                        resource: resource,
                        device: device
                    )
            }
            uploadNextFirstPersonViewModelTexture(
                resource: resource,
                device: device
            )
            guard let geometry = cachedFirstPersonViewModelGeometry,
                  GModMetalStudioGeometryCacheContract.canReuseGeometry(
                      cachedID: geometry.resourceID,
                      cachedVertexCount: geometry.vertexCount,
                      cachedIndexCount: geometry.indexCount,
                      publishedID: resource.id,
                      publishedVertexCount: resource.vertices.count,
                      publishedIndexCount: resource.indices.count
                  ),
                  let verticalFOV =
                    GModMetalFirstPersonViewModelRenderContract
                        .verticalFieldOfViewRadians(for: scene) else {
                lastFirstPersonViewModelRangeDrawCount = 0
                return
            }

            let width = Swift.max(1, viewport.x)
            let height = Swift.max(1, viewport.y)
            let projection = Self.makePerspectiveMatrix(
                verticalFieldOfViewRadians: verticalFOV,
                aspect: Float(width) / Float(height),
                near: 1,
                far: 65_536
            )
            var uniforms = WorldUniforms(
                viewProjection: projection,
                lightDirection: .zero,
                directLinearRGB: .zero,
                ambientLinearRGB: .zero,
                clipPlane: GModMetalWaterClipPlaneContract.disabled
            )
            withUnsafeBytes(of: &uniforms) { bytes in
                guard let address = bytes.baseAddress else { return }
                encoder.setVertexBytes(address, length: bytes.count, index: 1)
                encoder.setFragmentBytes(address, length: bytes.count, index: 1)
            }
            encoder.setVertexBuffer(geometry.vertexBuffer, offset: 0, index: 0)
            encoder.setDepthStencilState(depthState)
            encoder.setCullMode(.none)

            var drawnRanges = 0
            for range in resource.drawRanges {
                guard case let .resolved(_, bitmap) =
                        range.materialResolution,
                      bitmap.alphaRepresentation == .straight else {
                    // Missing Source materials remain absent. The first-person
                    // path never substitutes the dynamic-prop checker.
                    continue
                }
                let key = Self.dynamicEntityTextureKey(bitmap: bitmap)
                guard let cached = cachedFirstPersonViewModelTextures[key],
                      cached.bitmap == bitmap else { continue }
                encoder.setRenderPipelineState(texturedPipeline)
                encoder.setFragmentTexture(cached.texture, index: 0)
                let multiplier = range.usesPlayerWeaponColor
                    ? GModMetalFirstPersonViewModelRenderContract
                        .playerWeaponColorMultiplier(
                            weaponColor: scene.weaponColor,
                            sourceFixedTime: sourceFixedTime
                        ) ?? SIMD3<Float>(repeating: 1)
                    : SIMD3<Float>(repeating: 1)
                var materialUniforms = FirstPersonViewModelMaterialUniforms(
                    playerWeaponColorMultiplier: SIMD4<Float>(multiplier, 1)
                )
                withUnsafeBytes(of: &materialUniforms) { bytes in
                    guard let address = bytes.baseAddress else { return }
                    encoder.setFragmentBytes(
                        address,
                        length: bytes.count,
                        index: 2
                    )
                }
                let sampler = samplerStateForWorldTexture(
                    for: GModMetalWorldSamplerConfiguration(
                        bitmap: bitmap,
                        renderLayer: .world
                    ),
                    device: device
                )
                encoder.setFragmentSamplerState(sampler, index: 0)
                encoder.drawIndexedPrimitives(
                    type: .triangle,
                    indexCount: range.indexCount,
                    indexType: .uint32,
                    indexBuffer: geometry.indexBuffer,
                    indexBufferOffset:
                        range.firstIndex * MemoryLayout<UInt32>.stride
                )
                drawnRanges += 1
            }
            lastFirstPersonViewModelRangeDrawCount = drawnRanges
        }

        private func makeFirstPersonViewModelGeometry(
            resource: GModMetalDynamicEntityResource,
            device: MTLDevice
        ) -> CachedDynamicEntityGeometry? {
            let vertices = resource.vertices.map { vertex in
                DynamicEntityGPUVertex(
                    position: SIMD4<Float>(vertex.metalLocalPosition, 1),
                    normal: SIMD4<Float>(vertex.metalLocalNormal, 0),
                    uv: vertex.textureCoordinate
                )
            }
            let vertexBytes = vertices.count.multipliedReportingOverflow(
                by: MemoryLayout<DynamicEntityGPUVertex>.stride
            )
            let indexBytes = resource.indices.count.multipliedReportingOverflow(
                by: MemoryLayout<UInt32>.stride
            )
            let total = vertexBytes.partialValue.addingReportingOverflow(
                indexBytes.partialValue
            )
            guard !vertexBytes.overflow, !indexBytes.overflow, !total.overflow,
                  total.partialValue == resource.geometryByteCount,
                  total.partialValue <=
                    DynamicEntityGPUCachePolicy.maximumGeometryByteCount else {
                firstPersonViewModelIssue =
                    "viewmodel geometry violates the 128 MiB GPU cap"
                return nil
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
                firstPersonViewModelIssue =
                    "viewmodel Metal buffer allocation failed"
                return nil
            }
            let label = Self.dynamicEntityResourceLabel(resource.id)
            vertexBuffer.label = "First-person viewmodel vertices \(label)"
            indexBuffer.label = "First-person viewmodel indices \(label)"
            firstPersonViewModelIssue = nil
            return CachedDynamicEntityGeometry(
                resourceID: resource.id,
                vertexCount: vertices.count,
                indexCount: resource.indices.count,
                byteCount: total.partialValue,
                vertexBuffer: vertexBuffer,
                indexBuffer: indexBuffer
            )
        }

        private func uploadNextFirstPersonViewModelTexture(
            resource: GModMetalDynamicEntityResource,
            device: MTLDevice
        ) {
            for range in resource.drawRanges {
                guard case let .resolved(_, bitmap) =
                        range.materialResolution,
                      bitmap.alphaRepresentation == .straight else { continue }
                let key = Self.dynamicEntityTextureKey(bitmap: bitmap)
                if let cached = cachedFirstPersonViewModelTextures[key],
                   cached.bitmap == bitmap { continue }
                guard bitmap.totalByteCount <=
                        DynamicEntityGPUCachePolicy.maximumTextureByteCount else {
                    firstPersonViewModelIssue =
                        "viewmodel texture exceeds 64 MiB GPU cap"
                    continue
                }
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
                    firstPersonViewModelIssue =
                        "viewmodel Metal texture allocation failed"
                    return
                }
                for (level, mip) in bitmap.mipLevels.enumerated() {
                    mip.premultipliedRGBA8.withUnsafeBytes { bytes in
                        guard let base = bytes.baseAddress else { return }
                        texture.replace(
                            region: MTLRegionMake2D(
                                0, 0, mip.width, mip.height
                            ),
                            mipmapLevel: level,
                            withBytes: base,
                            bytesPerRow: mip.width * 4
                        )
                    }
                }
                texture.label = "First-person viewmodel texture " +
                    Self.dynamicEntityResourceLabel(resource.id)
                cachedFirstPersonViewModelTextures[key] =
                    CachedDynamicEntityTexture(
                        bitmap: bitmap,
                        byteCount: bitmap.totalByteCount,
                        texture: texture
                    )
                firstPersonViewModelIssue = nil
                return
            }
        }

        private func drawDynamicEntities(
            scene: GModMetalDynamicEntityScene,
            device: MTLDevice,
            pipelines: DynamicEntityRenderPipelines,
            opaqueDepthState: MTLDepthStencilState,
            translucentDepthState: MTLDepthStencilState,
            encoder: MTLRenderCommandEncoder
        ) {
            let renderableInstances: [(
                instance: GModMetalDynamicEntityInstance,
                blendMode: GModMetalDynamicEntityBlendMode,
                fragmentMode: GModMetalDynamicEntityFragmentMode
            )] = scene.instances.compactMap { instance in
                guard case let .draw(blendMode, fragmentMode) =
                        GModMetalDynamicEntityRenderContract.disposition(
                            for: instance.renderMode
                        ) else {
                    return nil
                }
                return (instance, blendMode, fragmentMode)
            }
            let geometryResourceIDs = Set(
                renderableInstances.map { $0.instance.resourceID }
            )
            let textureResourceIDs = Set(
                renderableInstances.compactMap {
                    $0.fragmentMode == .material
                        ? $0.instance.resourceID
                        : nil
                }
            )
            let geometryUploadLimits =
                GModMetalStudioGeometryUploadContract.limits(
                    for: geometryResourceIDs
                )
            var geometryUploadBudget = DynamicEntityUploadBudget(
                maximumResourceCount:
                    geometryUploadLimits.maximumResourceCount,
                maximumByteCount: geometryUploadLimits.maximumByteCount
            )
            var textureUploadBudget = DynamicEntityUploadBudget()
            uploadNextDynamicEntityGeometry(
                scene: scene,
                referencedResourceIDs: geometryResourceIDs,
                device: device,
                uploadBudget: &geometryUploadBudget
            )
            uploadNextDynamicEntityTexture(
                scene: scene,
                referencedResourceIDs: textureResourceIDs,
                device: device,
                uploadBudget: &textureUploadBudget
            )

            let resources = Dictionary(
                uniqueKeysWithValues: scene.resources.map { ($0.id, $0) }
            )
            var instanceDrawCount = 0
            var rangeDrawCount = 0
            var checkerRangeCount = 0
            encoder.setCullMode(.none)

            // Source places opaque entities before translucent render groups.
            // The supported translucent/additive routes depth-test against the
            // completed opaque world but cannot occlude a later transparent
            // range through a depth write.
            for blendMode in GModMetalDynamicEntityBlendMode.allCases {
                encoder.setDepthStencilState(
                    blendMode == .opaque
                        ? opaqueDepthState
                        : translucentDepthState
                )
                let pipelinePair = pipelines.pair(for: blendMode)
                for item in renderableInstances where
                    item.blendMode == blendMode {
                    let instance = item.instance
                    guard let resource = resources[instance.resourceID],
                          let geometry = cachedDynamicEntityGeometry[
                            instance.resourceID
                          ],
                          GModMetalStudioGeometryCacheContract.canReuseGeometry(
                              cachedID: geometry.resourceID,
                              cachedVertexCount: geometry.vertexCount,
                              cachedIndexCount: geometry.indexCount,
                              publishedID: resource.id,
                              publishedVertexCount: resource.vertices.count,
                              publishedIndexCount: resource.indices.count
                          ) else {
                        continue
                    }

                    // The scene's identity is a complete EHANDLE (entry + serial).
                    // It deliberately remains distinct when an entry is reused.
                    _ = instance.identity.handle.rawValue
                    let transform = instance.metalTransform
                    var transformUniforms = DynamicEntityTransformUniforms(
                        metalXAxis: SIMD4<Float>(transform.metalXAxis, 0),
                        metalYAxis: SIMD4<Float>(transform.metalYAxis, 0),
                        metalZAxis: SIMD4<Float>(transform.metalZAxis, 0),
                        metalTranslation: SIMD4<Float>(
                            transform.metalTranslation,
                            1
                        )
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
                    var appearanceUniforms = DynamicEntityAppearanceUniforms(
                        displayRGBAndAlpha:
                            GModMetalDynamicEntityRenderContract
                                .displayRGBAndAlpha(
                                    color: instance.colorModulation,
                                    blendMode: blendMode
                                )
                    )
                    withUnsafeBytes(of: &appearanceUniforms) { bytes in
                        guard let address = bytes.baseAddress else { return }
                        encoder.setFragmentBytes(
                            address,
                            length: bytes.count,
                            index: 2
                        )
                    }
                    // The value survives into the renderer scene, but
                    // unverified time-varying RenderFX is not synthesized.
                    _ = instance.renderFX

                    if item.fragmentMode == .constantColor {
                        encoder.setRenderPipelineState(
                            pipelines.sourceColorAlpha
                        )
                        encoder.setFragmentTexture(nil, index: 0)
                        encoder.setFragmentSamplerState(nil, index: 0)
                    }
                    var drewInstance = false
                    for range in resource.drawRanges {
                        var drawsChecker = item.fragmentMode == .material
                        if drawsChecker,
                           case let .resolved(_, bitmap) =
                            range.materialResolution,
                           bitmap.alphaRepresentation == .straight {
                            let key = Self.dynamicEntityTextureKey(
                                bitmap: bitmap
                            )
                            if let cached = cachedDynamicEntityTextures[key],
                               cached.bitmap == bitmap {
                                encoder.setRenderPipelineState(
                                    pipelinePair.textured
                                )
                                encoder.setFragmentTexture(
                                    cached.texture,
                                    index: 0
                                )
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
                            // Missing, failed, unsupported-alpha, and
                            // upload-pending materials remain checkered.
                            encoder.setRenderPipelineState(
                                pipelinePair.missingMaterial
                            )
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
            let geometry: String
            switch id.geometryIdentity {
            case .bindPose:
                geometry = "bind"
            case let .animated(sequence, blend, animation, frame):
                geometry =
                    "seq=\(sequence):blend=\(blend):anim=\(animation):" +
                    "frame=\(frame)"
            }
            return "\(id.normalizedModelPath)#\(id.checksum):" +
                "lod=\(id.lodIndex):body=\(id.bodyValue):" +
                "skin=\(id.skinFamilyIndex):\(geometry)"
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

        private func pruneCachedWorldTextures(
            for scene: GModMetalWorldScene
        ) {
            let staleKeys = GModMetalWorldTextureCacheContract.staleKeys(
                cachedKeys: Set(cachedWorldTextures.keys),
                for: scene
            )
            for key in staleKeys {
                cachedWorldTextures.removeValue(forKey: key)
            }
        }

        private static func worldTextureKey(
            for bitmap: GModMetalSurfaceBitmap,
            isSRGB: Bool
        ) -> String {
            GModMetalWorldTextureCacheContract.key(
                for: bitmap,
                isSRGB: isSRGB
            )
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

        /// Binds the optional secondary Source material textures without
        /// inventing pixels when an authored VTF is absent or still waiting
        /// for the bounded upload lane. Declared Metal resources always get a
        /// valid fallback binding; feature bits decide whether they contribute.
        private func bindWorldTerrainMaterial(
            range: GModMetalWorldMaterialRange,
            fallbackTexture: MTLTexture,
            device: MTLDevice,
            uploadBudget: inout WorldUploadBudget,
            defaultSampler: MTLSamplerState,
            encoder: MTLRenderCommandEncoder
        ) {
            var base2Texture = fallbackTexture
            var detailTexture = fallbackTexture
            var blendTexture = fallbackTexture
            var base2Sampler = defaultSampler
            var detailSampler = defaultSampler
            var blendSampler = defaultSampler
            var hasBase2 = false
            var hasDetail = false
            var hasBlendModulate = false

            if let bitmap = range.terrainMaterial?.vertexTransition?
                .baseTexture2Bitmap,
               let texture = worldTexture(
                    for: bitmap,
                    device: device,
                    uploadBudget: &uploadBudget
               ) {
                base2Texture = texture
                hasBase2 = true
                let configuration = GModMetalWorldSamplerConfiguration(
                    bitmap: bitmap,
                    renderLayer: range.renderLayer,
                    usage: range.textureUsage
                )
                base2Sampler = samplerStateForWorldTexture(
                    for: configuration,
                    device: device
                ) ?? defaultSampler
            }
            if let bitmap = range.terrainMaterial?.detail?.bitmap,
               let texture = worldTexture(
                    for: bitmap,
                    device: device,
                    uploadBudget: &uploadBudget,
                    isSRGB: range.terrainMaterial?.detail?.samplesAsSRGB == true
               ) {
                detailTexture = texture
                hasDetail = true
                let configuration = GModMetalWorldSamplerConfiguration(
                    bitmap: bitmap,
                    renderLayer: range.renderLayer,
                    usage: range.textureUsage
                )
                detailSampler = samplerStateForWorldTexture(
                    for: configuration,
                    device: device
                ) ?? defaultSampler
            }
            if hasBase2,
               let bitmap = range.terrainMaterial?.vertexTransition?
                .blendModulateBitmap,
               let texture = worldTexture(
                    for: bitmap,
                    device: device,
                    uploadBudget: &uploadBudget,
                    isSRGB: false
               ) {
                blendTexture = texture
                hasBlendModulate = true
                let configuration = GModMetalWorldSamplerConfiguration(
                    bitmap: bitmap,
                    renderLayer: range.renderLayer,
                    usage: range.textureUsage
                )
                blendSampler = samplerStateForWorldTexture(
                    for: configuration,
                    device: device
                ) ?? defaultSampler
            }

            let detailTransform = range.terrainMaterial?.detail?
                .textureTransform ?? .identity
            let blendTransform = range.terrainMaterial?.vertexTransition?
                .blendMaskTransform ?? .identity
            var uniforms = WorldTerrainUniforms(
                detailRow0: SIMD4<Float>(detailTransform.row0, 0),
                detailRow1: SIMD4<Float>(detailTransform.row1, 0),
                blendMaskRow0: SIMD4<Float>(blendTransform.row0, 0),
                blendMaskRow1: SIMD4<Float>(blendTransform.row1, 0),
                controls: SIMD4<Float>(
                    range.terrainMaterial?.detail?.blendFactor ?? 0,
                    Float(range.terrainMaterial?.detail?.blendMode ?? 0),
                    hasDetail ? 1 : 0,
                    hasBase2 ? 1 : 0
                ),
                flags: SIMD4<Float>(
                    hasBlendModulate ? 1 : 0,
                    range.textureUsage == .displacementTerrain ? 1 : 0,
                    0,
                    0
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
            encoder.setFragmentTexture(base2Texture, index: 2)
            encoder.setFragmentTexture(detailTexture, index: 3)
            encoder.setFragmentTexture(blendTexture, index: 4)
            encoder.setFragmentSamplerState(base2Sampler, index: 2)
            encoder.setFragmentSamplerState(detailSampler, index: 3)
            encoder.setFragmentSamplerState(blendSampler, index: 4)
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
                let visibilitySummary: String
                if let metrics = lastWorldVisibilityMetrics {
                    visibilitySummary =
                        "PVS/frustum \(metrics.visibleIndexCount / 3)/" +
                        "\(metrics.sourceIndexCount / 3) triangles in " +
                        "\(metrics.drawSpanCount) draws"
                } else if lastWorldVisibilityWasFailOpen {
                    visibilitySummary = "PVS/frustum fail-open"
                } else {
                    visibilitySummary = "PVS/frustum unavailable"
                }
                rendererStats =
                    "World: \(scene.meshIdentifier) (\(mesh.indexCount / 3) triangles; " +
                    "\(visibilitySummary); " +
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
                    "\(lastWaterPendingNormalRangeCount), RT " +
                    "\(lastWaterRenderTargetRangeCount), unsupported bump " +
                    "\(diagnostics.unsupportedWaterBumpTextureNames.count))" +
                    (waterRenderTargetIssue.map { "; water RT: \($0)" } ?? "") +
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

            let viewModelStats: String
            if let scene = activeFirstPersonViewModelScene {
                viewModelStats =
                    "ViewModel: \(scene.weaponClassName) " +
                    "\(lastFirstPersonViewModelRangeDrawCount)/" +
                    "\(scene.resource.drawRanges.count) ranges; Source FOV " +
                    "\(scene.sourceFieldOfViewDegrees); textures " +
                    "\(cachedFirstPersonViewModelTextures.count)" +
                    (firstPersonViewModelIssue.map { "; issue: \($0)" } ?? "")
            } else if let firstPersonViewModelIssue {
                viewModelStats =
                    "ViewModel rejected: \(firstPersonViewModelIssue)"
            } else {
                viewModelStats = "ViewModel: none"
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
                \(viewModelStats)
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
            float4 sourceParameters;
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

        struct DynamicEntityAppearance
        {
            float4 displayRGBAndAlpha;
        };

        struct FirstPersonViewModelMaterial
        {
            float4 playerWeaponColorMultiplier;
        };

        struct WorldUniforms
        {
            float4x4 viewProjection;
            float4 lightDirection;
            float4 directLinearRGB;
            float4 ambientLinearRGB;
            float4 clipPlane;
            float4 fogColorAndEnabled;
            float4 fogStartEndDensityRadial;
            float4 fogCameraEye;
            float4 fogCameraForward;
            float4 waterFogSurfaceInverseRangeAndEnabled;
            float4 waterFogCameraEye;
            float4 waterFogCameraForward;
        };

        struct WorldWaterUniforms
        {
            float4 fogColorAndAlpha;
            float4 scrollDirectionRateAndTime;
            float4 sourceAmountsAndViewport;
            float4 cameraEyeAndTargetFlags;
            float4 fogStartEndAboveAndEnabled;
            float4 cameraForwardAndDistortionEncoding;
        };

        struct WorldTerrainUniforms
        {
            float4 detailRow0;
            float4 detailRow1;
            float4 blendMaskRow0;
            float4 blendMaskRow1;
            float4 controls;
            float4 flags;
        };

        struct WorldSunSpriteUniforms
        {
            float4x4 viewProjection;
            float4 basePosition;
            float4 rightExtent;
            float4 upExtent;
            float4 displayRGBAndOpacity;
            float4 hdrColorScale;
        };

        struct WorldVertexOutput
        {
            float4 position [[position]];
            float3 worldPosition;
            float3 normal;
            float2 uv;
            float2 lightmapUV;
            float displacementAlpha;
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
            output.worldPosition = sourceVertex.position.xyz;
            output.normal = sourceVertex.normal.xyz;
            output.uv = sourceVertex.uv;
            output.lightmapUV = sourceVertex.lightmapUV;
            output.displacementAlpha = sourceVertex.sourceParameters.x;
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
            output.worldPosition = worldPosition;
            output.normal = worldNormal;
            output.uv = sourceVertex.uv;
            output.lightmapUV = float2(0.0);
            output.displacementAlpha = 0.0;
            return output;
        }

        vertex WorldVertexOutput firstPersonViewModelVertexMain(
            const device DynamicEntityVertex *vertices
                [[buffer(0)]],

            constant WorldUniforms &uniforms
                [[buffer(1)]],

            uint vertexID
                [[vertex_id]]
        )
        {
            // Studio c_*.mdl coordinates are authored in Source camera space.
            // CPU conversion already maps +X forward/+Y left/+Z up to Metal's
            // -Z forward/+X right/+Y up, so no world camera/entity transform
            // belongs in this pass.
            DynamicEntityVertex sourceVertex = vertices[vertexID];
            WorldVertexOutput output;
            output.position = uniforms.viewProjection * sourceVertex.position;
            output.worldPosition = sourceVertex.position.xyz;
            output.normal = normalize(sourceVertex.normal.xyz);
            output.uv = sourceVertex.uv;
            output.lightmapUV = float2(0.0);
            output.displacementAlpha = 0.0;
            return output;
        }

        float3 gmodWorldEnvironmentLight(
            float3 normal,
            constant WorldUniforms &uniforms
        )
        {
            // No compiled environment is an explicit unlit fallback. This
            // keeps the base material visible without inventing a sun vector.
            if (uniforms.lightDirection.w < 0.5)
            {
                return float3(1.0);
            }
            float3 light = normalize(uniforms.lightDirection.xyz);
            float diffuse = max(dot(normalize(normal), light), 0.0);
            return uniforms.ambientLinearRGB.xyz
                + uniforms.directLinearRGB.xyz * diffuse;
        }

        void gmodApplyWorldClip(
            WorldVertexOutput input,
            constant WorldUniforms &uniforms
        )
        {
            if (dot(float4(input.worldPosition, 1.0), uniforms.clipPlane) < 0.0)
            {
                discard_fragment();
            }
        }

        float3 gmodApplyWorldFog(
            WorldVertexOutput input,
            constant WorldUniforms &uniforms,
            float3 linearRGB
        )
        {
            if (uniforms.fogColorAndEnabled.w < 0.5)
            {
                return linearRGB;
            }
            float3 eyeDelta = input.worldPosition - uniforms.fogCameraEye.xyz;
            float fogDistance = uniforms.fogStartEndDensityRadial.w > 0.5
                ? length(eyeDelta)
                : max(dot(eyeDelta, uniforms.fogCameraForward.xyz), 0.0);
            float start = uniforms.fogStartEndDensityRadial.x;
            float end = uniforms.fogStartEndDensityRadial.y;
            float maximumDensity = uniforms.fogStartEndDensityRadial.z;
            float factor = saturate(min(
                maximumDensity,
                (fogDistance - start) / (end - start)
            ));
            // Source's pixel range-fog path squares the saturated factor to
            // approximate the hardware fog curve.
            factor *= factor;
            return mix(linearRGB, uniforms.fogColorAndEnabled.rgb, factor);
        }

        float4 gmodWorldFogOutput(
            WorldVertexOutput input,
            constant WorldUniforms &uniforms,
            float3 linearRGB,
            float alpha
        )
        {
            float outputAlpha = alpha;
            if (uniforms.waterFogSurfaceInverseRangeAndEnabled.z > 0.5)
            {
                constexpr float nearPlane = 1.0;
                constexpr float farPlane = 65536.0;
                float forwardDistance = dot(
                    input.worldPosition - uniforms.waterFogCameraEye.xyz,
                    uniforms.waterFogCameraForward.xyz
                );
                float projectedDepth = (
                    forwardDistance * farPlane - nearPlane * farPlane
                ) / (farPlane - nearPlane);
                float depthFromEye = uniforms.waterFogCameraEye.y
                    - input.worldPosition.y;
                float fractionBelowWater = 0.0;
                if (abs(depthFromEye) > 1.0e-7)
                {
                    fractionBelowWater = saturate(
                        (uniforms.waterFogSurfaceInverseRangeAndEnabled.x
                            - input.worldPosition.y) / depthFromEye
                    );
                }
                // Source `CalcWaterFogAlpha`: the above-water refraction
                // target carries water depth in alpha for the later Water
                // shader. Source Z is Metal world Y.
                outputAlpha = saturate(
                    fractionBelowWater * projectedDepth *
                        uniforms.waterFogSurfaceInverseRangeAndEnabled.y
                );
            }
            return gmodWorldOutput(
                gmodApplyWorldFog(input, uniforms, linearRGB),
                outputAlpha
            );
        }

        float2 gmodTerrainUV(
            float2 uv,
            float4 row0,
            float4 row1
        )
        {
            float3 homogeneous = float3(uv, 1.0);
            return float2(
                dot(row0.xyz, homogeneous),
                dot(row1.xyz, homogeneous)
            );
        }

        float4 gmodApplyDetailBeforeLighting(
            float4 baseColor,
            float4 detailColor,
            int mode,
            float factor
        )
        {
            switch (mode)
            {
                case 0:
                    baseColor.rgb *= mix(
                        float3(1.0),
                        2.0 * detailColor.rgb,
                        factor
                    );
                    break;
                case 1:
                    baseColor.rgb += factor * detailColor.rgb;
                    break;
                case 2:
                    baseColor.rgb = mix(
                        baseColor.rgb,
                        detailColor.rgb,
                        factor * detailColor.a
                    );
                    break;
                case 3:
                    baseColor = mix(baseColor, detailColor, factor);
                    break;
                case 4:
                    baseColor.rgb = mix(
                        baseColor.rgb,
                        detailColor.rgb,
                        factor * (1.0 - baseColor.a)
                    );
                    baseColor.a = detailColor.a;
                    break;
                case 7:
                {
                    float monochrome = mix(
                        detailColor.r,
                        detailColor.a,
                        baseColor.a
                    );
                    baseColor.rgb *= mix(
                        float3(1.0),
                        float3(2.0 * monochrome),
                        factor
                    );
                    break;
                }
                case 8:
                    baseColor = mix(
                        baseColor,
                        baseColor * detailColor,
                        factor
                    );
                    break;
                case 9:
                    baseColor.a = mix(
                        baseColor.a,
                        baseColor.a * detailColor.a,
                        factor
                    );
                    break;
                case 11:
                    baseColor.rgb *= dot(
                        detailColor.rgb,
                        float3(2.0 / 3.0)
                    );
                    break;
                default:
                    // Modes 5 and 6 are post-lighting. Mode 10 is the
                    // SSBump path and remains inactive until the real bump
                    // basis is available.
                    break;
            }
            return baseColor;
        }

        float4 gmodSampleTerrainTexture(
            texture2d<float> sourceTexture,
            sampler sourceSampler,
            float2 uv,
            bool usesDisplacementLOD
        )
        {
            if (usesDisplacementLOD)
            {
                // Perspective interpolation makes these screen-space UV
                // gradients grow with camera distance and grazing angle. The
                // authored VTF mip chain and sampler then select/filter the
                // footprint without an invented world-distance threshold.
                return sourceTexture.sample(
                    sourceSampler,
                    uv,
                    gradient2d(dfdx(uv), dfdy(uv))
                );
            }
            return sourceTexture.sample(sourceSampler, uv);
        }

        float4 gmodSampleTerrainBase(
            WorldVertexOutput input,
            constant WorldTerrainUniforms &terrain,
            texture2d<float> baseTexture,
            texture2d<float> baseTexture2,
            texture2d<float> detailTexture,
            texture2d<float> blendModulateTexture,
            sampler baseSampler,
            sampler baseSampler2,
            sampler detailSampler,
            sampler blendModulateSampler
        )
        {
            bool usesDisplacementLOD = terrain.flags.y > 0.5;
            float4 baseColor = gmodSampleTerrainTexture(
                baseTexture,
                baseSampler,
                input.uv,
                usesDisplacementLOD
            );
            if (terrain.controls.w > 0.5)
            {
                float blendFactor = saturate(input.displacementAlpha);
                if (terrain.flags.x > 0.5)
                {
                    float2 blendUV = gmodTerrainUV(
                        input.uv,
                        terrain.blendMaskRow0,
                        terrain.blendMaskRow1
                    );
                    float2 modulate = gmodSampleTerrainTexture(
                        blendModulateTexture,
                        blendModulateSampler,
                        blendUV,
                        usesDisplacementLOD
                    ).gr;
                    float minimumBlend = saturate(modulate.x - modulate.y);
                    float maximumBlend = saturate(modulate.x + modulate.y);
                    blendFactor = smoothstep(
                        minimumBlend,
                        maximumBlend,
                        blendFactor
                    );
                }
                float4 secondColor = gmodSampleTerrainTexture(
                    baseTexture2,
                    baseSampler2,
                    input.uv,
                    usesDisplacementLOD
                );
                baseColor.rgb = mix(
                    baseColor.rgb,
                    secondColor.rgb,
                    blendFactor
                );
            }
            if (terrain.controls.z > 0.5)
            {
                float2 detailUV = gmodTerrainUV(
                    input.uv,
                    terrain.detailRow0,
                    terrain.detailRow1
                );
                float4 detailColor = gmodSampleTerrainTexture(
                    detailTexture,
                    detailSampler,
                    detailUV,
                    usesDisplacementLOD
                );
                baseColor = gmodApplyDetailBeforeLighting(
                    baseColor,
                    detailColor,
                    int(terrain.controls.y),
                    terrain.controls.x
                );
            }
            return baseColor;
        }

        float3 gmodApplyDetailAfterLighting(
            WorldVertexOutput input,
            constant WorldTerrainUniforms &terrain,
            texture2d<float> detailTexture,
            sampler detailSampler,
            float3 litColor
        )
        {
            if (terrain.controls.z < 0.5)
            {
                return litColor;
            }
            int mode = int(terrain.controls.y);
            if (mode != 5 && mode != 6)
            {
                return litColor;
            }
            float2 detailUV = gmodTerrainUV(
                input.uv,
                terrain.detailRow0,
                terrain.detailRow1
            );
            float3 detailColor = gmodSampleTerrainTexture(
                detailTexture,
                detailSampler,
                detailUV,
                terrain.flags.y > 0.5
            ).rgb;
            float factor = terrain.controls.x;
            if (mode == 5)
            {
                return litColor + factor * detailColor;
            }
            float multiplier = factor >= 0.5
                ? 1.0 / factor
                : 4.0 * factor;
            float additive = factor >= 0.5
                ? 1.0 - multiplier
                : -0.5 * multiplier;
            return litColor + saturate(
                multiplier * detailColor + additive
            );
        }

        fragment float4 worldFragmentMain(
            WorldVertexOutput input [[stage_in]],

            constant WorldUniforms &uniforms
                [[buffer(1)]]
        )
        {
            gmodApplyWorldClip(input, uniforms);
            float3 baseLinear = gmodDecodeDisplaySRGB(
                float3(0.48, 0.61, 0.72)
            );
            return gmodWorldFogOutput(
                input,
                uniforms,
                baseLinear * gmodWorldEnvironmentLight(input.normal, uniforms),
                1.0
            );
        }

        fragment float4 worldTexturedFragmentMain(
            WorldVertexOutput input [[stage_in]],

            constant WorldUniforms &uniforms
                [[buffer(1)]],

            constant WorldTerrainUniforms &terrain
                [[buffer(2)]],

            texture2d<float> baseTexture [[texture(0)]],

            texture2d<float> baseTexture2 [[texture(2)]],

            texture2d<float> detailTexture [[texture(3)]],

            texture2d<float> blendModulateTexture [[texture(4)]],

            sampler baseSampler [[sampler(0)]],

            sampler baseSampler2 [[sampler(2)]],

            sampler detailSampler [[sampler(3)]],

            sampler blendModulateSampler [[sampler(4)]]
        )
        {
            gmodApplyWorldClip(input, uniforms);
            float4 sample = gmodSampleTerrainBase(
                input,
                terrain,
                baseTexture,
                baseTexture2,
                detailTexture,
                blendModulateTexture,
                baseSampler,
                baseSampler2,
                detailSampler,
                blendModulateSampler
            );
            float3 litColor = sample.rgb
                * gmodWorldEnvironmentLight(input.normal, uniforms);
            litColor = gmodApplyDetailAfterLighting(
                input,
                terrain,
                detailTexture,
                detailSampler,
                litColor
            );
            return gmodWorldFogOutput(
                input,
                uniforms,
                litColor,
                1.0
            );
        }

        fragment float4 worldLightmappedFragmentMain(
            WorldVertexOutput input [[stage_in]],

            constant WorldUniforms &uniforms
                [[buffer(1)]],

            texture2d<float> lightmapTexture [[texture(1)]],

            sampler lightmapSampler [[sampler(1)]]
        )
        {
            gmodApplyWorldClip(input, uniforms);
            float3 baseLinear = gmodDecodeDisplaySRGB(
                float3(0.48, 0.61, 0.72)
            );
            float3 bakedLight = lightmapTexture.sample(
                lightmapSampler,
                input.lightmapUV
            ).rgb;
            return gmodWorldFogOutput(
                input,
                uniforms,
                baseLinear * bakedLight,
                1.0
            );
        }

        fragment float4 worldTexturedLightmappedFragmentMain(
            WorldVertexOutput input [[stage_in]],

            constant WorldUniforms &uniforms
                [[buffer(1)]],

            constant WorldTerrainUniforms &terrain
                [[buffer(2)]],

            texture2d<float> baseTexture [[texture(0)]],

            texture2d<float> lightmapTexture [[texture(1)]],

            texture2d<float> baseTexture2 [[texture(2)]],

            texture2d<float> detailTexture [[texture(3)]],

            texture2d<float> blendModulateTexture [[texture(4)]],

            sampler baseSampler [[sampler(0)]],

            sampler lightmapSampler [[sampler(1)]],

            sampler baseSampler2 [[sampler(2)]],

            sampler detailSampler [[sampler(3)]],

            sampler blendModulateSampler [[sampler(4)]]
        )
        {
            gmodApplyWorldClip(input, uniforms);
            float4 base = gmodSampleTerrainBase(
                input,
                terrain,
                baseTexture,
                baseTexture2,
                detailTexture,
                blendModulateTexture,
                baseSampler,
                baseSampler2,
                detailSampler,
                blendModulateSampler
            );
            float3 bakedLight = lightmapTexture.sample(
                lightmapSampler,
                input.lightmapUV
            ).rgb;
            float3 litColor = base.rgb * bakedLight;
            litColor = gmodApplyDetailAfterLighting(
                input,
                terrain,
                detailTexture,
                detailSampler,
                litColor
            );
            return gmodWorldFogOutput(
                input,
                uniforms,
                litColor,
                1.0
            );
        }

        fragment float4 worldMissingMaterialFragmentMain(
            WorldVertexOutput input [[stage_in]],

            constant WorldUniforms &uniforms
                [[buffer(1)]]
        )
        {
            gmodApplyWorldClip(input, uniforms);
            float2 tile = floor(input.uv * 8.0);
            bool alternate = fmod(tile.x + tile.y, 2.0) != 0.0;
            float3 displayColor = alternate
                ? float3(0.92, 0.05, 0.72)
                : float3(0.06, 0.01, 0.05);
            return gmodWorldFogOutput(
                input,
                uniforms,
                gmodDecodeDisplaySRGB(displayColor),
                1.0
            );
        }

        fragment float4 firstPersonViewModelTexturedFragmentMain(
            WorldVertexOutput input [[stage_in]],

            constant WorldUniforms &uniforms
                [[buffer(1)]],

            constant FirstPersonViewModelMaterial &material
                [[buffer(2)]],

            texture2d<float> baseTexture [[texture(0)]],

            sampler baseSampler [[sampler(0)]]
        )
        {
            gmodApplyWorldClip(input, uniforms);
            float4 sample = baseTexture.sample(baseSampler, input.uv);
            return gmodWorldOutput(
                sample.rgb * material.playerWeaponColorMultiplier.rgb,
                sample.a
            );
        }

        fragment float4 dynamicEntityTexturedFragmentMain(
            WorldVertexOutput input [[stage_in]],

            constant WorldUniforms &uniforms
                [[buffer(1)]],

            constant DynamicEntityAppearance &appearance
                [[buffer(2)]],

            texture2d<float> baseTexture [[texture(0)]],

            sampler baseSampler [[sampler(0)]]
        )
        {
            gmodApplyWorldClip(input, uniforms);
            float4 sample = baseTexture.sample(baseSampler, input.uv);
            float3 modulation = gmodDecodeDisplaySRGB(
                appearance.displayRGBAndAlpha.rgb
            );
            return gmodWorldFogOutput(
                input,
                uniforms,
                sample.rgb * modulation *
                    gmodWorldEnvironmentLight(input.normal, uniforms),
                appearance.displayRGBAndAlpha.a
            );
        }

        fragment float4 dynamicEntityColorFragmentMain(
            WorldVertexOutput input [[stage_in]],

            constant WorldUniforms &uniforms
                [[buffer(1)]],

            constant DynamicEntityAppearance &appearance
                [[buffer(2)]]
        )
        {
            gmodApplyWorldClip(input, uniforms);
            return gmodWorldFogOutput(
                input,
                uniforms,
                gmodDecodeDisplaySRGB(
                    appearance.displayRGBAndAlpha.rgb
                ),
                appearance.displayRGBAndAlpha.a
            );
        }

        fragment float4 dynamicEntityMissingMaterialFragmentMain(
            WorldVertexOutput input [[stage_in]],

            constant WorldUniforms &uniforms
                [[buffer(1)]],

            constant DynamicEntityAppearance &appearance
                [[buffer(2)]]
        )
        {
            gmodApplyWorldClip(input, uniforms);
            float2 tile = floor(input.uv * 8.0);
            bool alternate = fmod(tile.x + tile.y, 2.0) != 0.0;
            float3 displayColor = alternate
                ? float3(0.92, 0.05, 0.72)
                : float3(0.06, 0.01, 0.05);
            float3 modulation = gmodDecodeDisplaySRGB(
                appearance.displayRGBAndAlpha.rgb
            );
            return gmodWorldFogOutput(
                input,
                uniforms,
                gmodDecodeDisplaySRGB(displayColor) * modulation,
                appearance.displayRGBAndAlpha.a
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

        struct WorldSunSpriteVertexOutput
        {
            float4 position [[position]];
            float2 uv;
        };

        vertex WorldSunSpriteVertexOutput worldSunSpriteVertexMain(
            constant WorldSunSpriteUniforms &sun [[buffer(1)]],
            uint vertexID [[vertex_id]]
        )
        {
            const float2 signs[4] = {
                float2(-1.0,  1.0),
                float2( 1.0,  1.0),
                float2(-1.0, -1.0),
                float2( 1.0, -1.0)
            };
            const float2 textureCoordinates[4] = {
                float2(0.0, 1.0),
                float2(1.0, 1.0),
                float2(0.0, 0.0),
                float2(1.0, 0.0)
            };
            float2 sign = signs[vertexID];
            float3 position = sun.basePosition.xyz
                + sun.rightExtent.xyz * sign.x
                + sun.upExtent.xyz * sign.y;
            WorldSunSpriteVertexOutput output;
            output.position = sun.viewProjection * float4(position, 1.0);
            output.uv = textureCoordinates[vertexID];
            return output;
        }

        fragment float4 worldSunSpriteFragmentMain(
            WorldSunSpriteVertexOutput input [[stage_in]],
            constant WorldSunSpriteUniforms &sun [[buffer(1)]],
            texture2d<float> spriteTexture [[texture(0)]],
            sampler spriteSampler [[sampler(0)]]
        )
        {
            float4 sample = spriteTexture.sample(spriteSampler, input.uv);
            float fade = sun.displayRGBAndOpacity.a;
            float opacity = fade * sample.a;
            float3 modulation = gmodDecodeDisplaySRGB(
                sun.displayRGBAndOpacity.rgb
            );
            // World bitmaps retain straight alpha. Source's additive sun
            // material uses the texture alpha as the source contribution.
            float3 linear = sample.rgb * sample.a * modulation * fade
                * sun.hdrColorScale.x;
            return gmodWorldOutput(linear, opacity);
        }

        fragment float4 worldWaterSolidFragmentMain(
            WorldVertexOutput input [[stage_in]],

            constant WorldUniforms &uniforms
                [[buffer(1)]],

            constant WorldWaterUniforms &water
                [[buffer(2)]]
        )
        {
            return gmodWorldFogOutput(
                input,
                uniforms,
                gmodDecodeDisplaySRGB(water.fogColorAndAlpha.rgb) *
                    water.fogColorAndAlpha.a,
                water.fogColorAndAlpha.a
            );
        }

        fragment float4 worldWaterNormalFragmentMain(
            WorldVertexOutput input [[stage_in]],

            constant WorldUniforms &uniforms
                [[buffer(1)]],

            constant WorldWaterUniforms &water
                [[buffer(2)]],

            texture2d<float> normalTexture [[texture(0)]],

            sampler normalSampler [[sampler(0)]]
        )
        {
            // The retained normal is meaningful only once scene-color targets
            // exist. The fallback keeps the authored fog visible and does not
            // invent a separate water light vector.
            return gmodWorldFogOutput(
                input,
                uniforms,
                gmodDecodeDisplaySRGB(water.fogColorAndAlpha.rgb) *
                    water.fogColorAndAlpha.a,
                water.fogColorAndAlpha.a
            );
        }

        struct WorldSceneCopyVertexOutput
        {
            float4 position [[position]];
        };

        vertex WorldSceneCopyVertexOutput worldSceneCopyVertexMain(
            uint vertexID [[vertex_id]]
        )
        {
            const float2 positions[3] = {
                float2(-1.0, -1.0),
                float2( 3.0, -1.0),
                float2(-1.0,  3.0)
            };
            WorldSceneCopyVertexOutput output;
            output.position = float4(positions[vertexID], 0.0, 1.0);
            return output;
        }

        fragment float4 worldSceneCopyFragmentMain(
            WorldSceneCopyVertexOutput input [[stage_in]],
            texture2d<float> sceneColor [[texture(2)]]
        )
        {
            constexpr sampler sceneSampler(
                coord::normalized,
                address::clamp_to_edge,
                filter::linear
            );
            float2 size = float2(
                sceneColor.get_width(),
                sceneColor.get_height()
            );
            return sceneColor.sample(sceneSampler, input.position.xy / size);
        }

        float3 gmodWaterWorldNormal(
            WorldVertexOutput input,
            float3 tangentNormal
        )
        {
            float3 surfaceNormal = normalize(input.normal);
            float3 positionDX = dfdx(input.worldPosition);
            float3 positionDY = dfdy(input.worldPosition);
            float2 uvDX = dfdx(input.uv);
            float2 uvDY = dfdy(input.uv);
            float3 perpendicularDY = cross(positionDY, surfaceNormal);
            float3 perpendicularDX = cross(surfaceNormal, positionDX);
            float3 tangent = perpendicularDY * uvDX.x
                + perpendicularDX * uvDY.x;
            float3 bitangent = perpendicularDY * uvDX.y
                + perpendicularDX * uvDY.y;
            float maximumLengthSquared = max(
                dot(tangent, tangent),
                dot(bitangent, bitangent)
            );
            if (maximumLengthSquared <= 1.0e-12)
            {
                return surfaceNormal;
            }
            float inverseLength = rsqrt(maximumLengthSquared);
            return normalize(
                tangent * (tangentNormal.x * inverseLength)
                + bitangent * (tangentNormal.y * inverseLength)
                + surfaceNormal * tangentNormal.z
            );
        }

        float4 gmodWaterRenderTargetComposite(
            WorldVertexOutput input,
            constant WorldWaterUniforms &water,
            float3 tangentNormal,
            float2 distortionOffset,
            float distortionAlpha,
            texture2d<float> refractionColor,
            texture2d<float> reflectionColor
        )
        {
            constexpr sampler sceneSampler(
                coord::normalized,
                address::clamp_to_edge,
                filter::linear
            );
            float2 viewport = max(
                water.sourceAmountsAndViewport.zw,
                float2(1.0)
            );
            float2 baseUV = input.position.xy / viewport;
            uint targetFlags = uint(
                max(water.cameraEyeAndTargetFlags.w, 0.0) + 0.5
            );
            bool hasReflection = (targetFlags & 1u) != 0u;
            bool hasRefraction = (targetFlags & 2u) != 0u;
            bool isAboveWater = water.fogStartEndAboveAndEnabled.z > 0.5;
            bool hasWaterFog = water.fogStartEndAboveAndEnabled.w > 0.5;
            float waterFogDepthValue = 1.0;
            if (isAboveWater && hasRefraction && hasWaterFog)
            {
                waterFogDepthValue = refractionColor.sample(
                    sceneSampler,
                    baseUV
                ).a;
            }
            float2 amounts = water.sourceAmountsAndViewport.xy;
            // `water_ps2x_helper.h` scales both dependent UV amounts by the
            // unwarped depth target for Water materials without `$basetexture`.
            amounts *= waterFogDepthValue;
            float2 normalOffset = distortionOffset * distortionAlpha;
            float2 reflectionBase = float2(baseUV.x, 1.0 - baseUV.y);
            float2 reflectionUV = reflectionBase + normalOffset * amounts.x;
            float2 refractionUV = baseUV + normalOffset * amounts.y;
            float4 refractedSample = refractionColor.sample(
                sceneSampler,
                refractionUV
            );
            if (isAboveWater && hasRefraction && hasWaterFog)
            {
                waterFogDepthValue = refractedSample.a;
            }
            float3 refracted = gmodDecodeDisplaySRGB(refractedSample.rgb);
            float3 reflected = gmodDecodeDisplaySRGB(
                reflectionColor.sample(sceneSampler, reflectionUV).rgb
            );
            float3 fog = gmodDecodeDisplaySRGB(water.fogColorAndAlpha.rgb);
            if (hasRefraction && hasWaterFog)
            {
                float fogFactor;
                if (isAboveWater)
                {
                    fogFactor = saturate(waterFogDepthValue - 0.05);
                }
                else
                {
                    constexpr float nearPlane = 1.0;
                    constexpr float farPlane = 65536.0;
                    float forwardDistance = dot(
                        input.worldPosition -
                            water.cameraEyeAndTargetFlags.xyz,
                            water.cameraForwardAndDistortionEncoding.xyz
                    );
                    float projectedDepth = (
                        forwardDistance * farPlane - nearPlane * farPlane
                    ) / (farPlane - nearPlane);
                    fogFactor = saturate(
                        (projectedDepth -
                            water.fogStartEndAboveAndEnabled.x) /
                        (water.fogStartEndAboveAndEnabled.y -
                            water.fogStartEndAboveAndEnabled.x)
                    );
                }
                refracted = mix(refracted, fog, fogFactor);
            }
            float3 composed = fog;
            if (hasReflection && hasRefraction)
            {
                float3 worldNormal = gmodWaterWorldNormal(
                    input,
                    tangentNormal
                );
                float3 eyeVector = normalize(
                    water.cameraEyeAndTargetFlags.xyz - input.worldPosition
                );
                float normalDotEye = saturate(dot(worldNormal, eyeVector));
                float fresnel = pow(1.0 - normalDotEye, 5.0);
                if (hasWaterFog)
                {
                    fresnel *= saturate(
                        (waterFogDepthValue - 0.05) * 20.0
                    );
                }
                composed = mix(refracted, reflected, fresnel);
            }
            else if (hasReflection)
            {
                composed = reflected;
            }
            else if (hasRefraction)
            {
                composed = refracted;
            }
            return gmodWorldOutput(composed, 1.0);
        }

        fragment float4 worldWaterCompositeSolidFragmentMain(
            WorldVertexOutput input [[stage_in]],
            constant WorldWaterUniforms &water [[buffer(2)]],
            texture2d<float> refractionColor [[texture(2)]],
            texture2d<float> reflectionColor [[texture(3)]]
        )
        {
            return gmodWaterRenderTargetComposite(
                input,
                water,
                float3(0.0, 0.0, 1.0),
                float2(0.0),
                1.0,
                refractionColor,
                reflectionColor
            );
        }

        fragment float4 worldWaterCompositeNormalFragmentMain(
            WorldVertexOutput input [[stage_in]],
            constant WorldWaterUniforms &water [[buffer(2)]],
            texture2d<float> normalTexture [[texture(0)]],
            sampler normalSampler [[sampler(0)]],
            texture2d<float> refractionColor [[texture(2)]],
            texture2d<float> reflectionColor [[texture(3)]]
        )
        {
            float2 direction = water.scrollDirectionRateAndTime.xy;
            float rate = water.scrollDirectionRateAndTime.z;
            float sourceTime = water.scrollDirectionRateAndTime.w;
            float2 animatedUV = input.uv + direction * rate * sourceTime;
            float4 normalSample = normalTexture.sample(
                normalSampler,
                animatedUV
            );
            uint distortionEncoding = uint(max(
                water.cameraForwardAndDistortionEncoding.w,
                0.0
            ) + 0.5);
            if (distortionEncoding == 2u)
            {
                // UV88/RG is a signed displacement field only. Fresnel keeps
                // the geometric water normal instead of treating DuDv as a
                // fabricated tangent-space normal.
                return gmodWaterRenderTargetComposite(
                    input,
                    water,
                    float3(0.0, 0.0, 1.0),
                    normalSample.rg * 2.0 - 1.0,
                    1.0,
                    refractionColor,
                    reflectionColor
                );
            }
            float3 decodedNormal = normalSample.xyz * 2.0 - 1.0;
            float normalLengthSquared = dot(decodedNormal, decodedNormal);
            float3 tangentNormal = normalLengthSquared > 1.0e-12
                ? decodedNormal * rsqrt(normalLengthSquared)
                : float3(0.0, 0.0, 1.0);
            return gmodWaterRenderTargetComposite(
                input,
                water,
                tangentNormal,
                tangentNormal.xy,
                normalSample.a,
                refractionColor,
                reflectionColor
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
