import Darwin
import Foundation
import Metal

/// Compiles the exact shader extracted from `GModMetalView` and creates the
/// all production render-pipeline shapes. Exit 78 means the CI host exposes
/// no Metal device; all other Metal failures are hard validation failures.
@main
enum MetalPipelineSmoke {
    static func main() {
        do {
            guard CommandLine.arguments.count == 2 else {
                throw SmokeError.invalidArguments
            }
            let shaderSource = try String(
                contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]),
                encoding: .utf8
            )

            guard let device = MTLCreateSystemDefaultDevice() else {
                writeStandardError("GMOD_METAL_DEVICE_UNAVAILABLE\n")
                Darwin.exit(78)
            }
            guard let commandQueue = device.makeCommandQueue() else {
                throw SmokeError.commandQueueCreationFailed
            }
            _ = commandQueue

            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let worldVertex = try function(named: "worldVertexMain", in: library)
            let dynamicEntityVertex = try function(
                named: "dynamicEntityVertexMain",
                in: library
            )
            let worldFragment = try function(named: "worldFragmentMain", in: library)
            let worldTextured = try function(
                named: "worldTexturedFragmentMain",
                in: library
            )
            let dynamicEntityTextured = try function(
                named: "dynamicEntityTexturedFragmentMain",
                in: library
            )
            let dynamicEntityColor = try function(
                named: "dynamicEntityColorFragmentMain",
                in: library
            )
            let worldLightmapped = try function(
                named: "worldLightmappedFragmentMain",
                in: library
            )
            let worldTexturedLightmapped = try function(
                named: "worldTexturedLightmappedFragmentMain",
                in: library
            )
            let worldMissingMaterial = try function(
                named: "worldMissingMaterialFragmentMain",
                in: library
            )
            let dynamicEntityMissingMaterial = try function(
                named: "dynamicEntityMissingMaterialFragmentMain",
                in: library
            )
            let worldSkybox = try function(
                named: "worldSkyboxFragmentMain",
                in: library
            )
            let worldSunSpriteVertex = try function(
                named: "worldSunSpriteVertexMain",
                in: library
            )
            let worldSunSprite = try function(
                named: "worldSunSpriteFragmentMain",
                in: library
            )
            let worldWaterSolid = try function(
                named: "worldWaterSolidFragmentMain",
                in: library
            )
            let worldWaterNormal = try function(
                named: "worldWaterNormalFragmentMain",
                in: library
            )
            let worldWaterCompositeSolid = try function(
                named: "worldWaterCompositeSolidFragmentMain",
                in: library
            )
            let worldWaterCompositeNormal = try function(
                named: "worldWaterCompositeNormalFragmentMain",
                in: library
            )
            let worldSceneCopyVertex = try function(
                named: "worldSceneCopyVertexMain",
                in: library
            )
            let worldSceneCopy = try function(
                named: "worldSceneCopyFragmentMain",
                in: library
            )
            let surfaceVertex = try function(named: "surfaceVertexMain", in: library)
            let surfaceSolid = try function(
                named: "surfaceSolidFragmentMain",
                in: library
            )
            let surfaceTextured = try function(
                named: "surfaceTexturedFragmentMain",
                in: library
            )

            try makePipeline(
                device: device,
                vertex: worldVertex,
                fragment: worldFragment,
                blendMode: .none
            )
            try makePipeline(
                device: device,
                vertex: worldVertex,
                fragment: worldTextured,
                blendMode: .none
            )
            try makePipeline(
                device: device,
                vertex: worldVertex,
                fragment: worldLightmapped,
                blendMode: .none
            )
            try makePipeline(
                device: device,
                vertex: worldVertex,
                fragment: worldTexturedLightmapped,
                blendMode: .none
            )
            try makePipeline(
                device: device,
                vertex: worldVertex,
                fragment: worldMissingMaterial,
                blendMode: .none
            )
            try makePipeline(
                device: device,
                vertex: dynamicEntityVertex,
                fragment: dynamicEntityTextured,
                blendMode: .none
            )
            try makePipeline(
                device: device,
                vertex: dynamicEntityVertex,
                fragment: dynamicEntityMissingMaterial,
                blendMode: .none
            )
            for blendMode in [BlendMode.straightAlpha, .straightAdditive] {
                try makePipeline(
                    device: device,
                    vertex: dynamicEntityVertex,
                    fragment: dynamicEntityTextured,
                    blendMode: blendMode
                )
                try makePipeline(
                    device: device,
                    vertex: dynamicEntityVertex,
                    fragment: dynamicEntityMissingMaterial,
                    blendMode: blendMode
                )
            }
            try makePipeline(
                device: device,
                vertex: dynamicEntityVertex,
                fragment: dynamicEntityColor,
                blendMode: .straightAlpha
            )
            try makePipeline(
                device: device,
                vertex: worldVertex,
                fragment: worldSkybox,
                blendMode: .none
            )
            try makePipeline(
                device: device,
                vertex: worldSunSpriteVertex,
                fragment: worldSunSprite,
                blendMode: .additive
            )
            try makePipeline(
                device: device,
                vertex: worldVertex,
                fragment: worldWaterSolid,
                blendMode: .premultiplied
            )
            try makePipeline(
                device: device,
                vertex: worldVertex,
                fragment: worldWaterNormal,
                blendMode: .premultiplied
            )
            try makePipeline(
                device: device,
                vertex: worldVertex,
                fragment: worldWaterCompositeSolid,
                blendMode: .premultiplied
            )
            try makePipeline(
                device: device,
                vertex: worldVertex,
                fragment: worldWaterCompositeNormal,
                blendMode: .premultiplied
            )
            try makePipeline(
                device: device,
                vertex: worldSceneCopyVertex,
                fragment: worldSceneCopy,
                blendMode: .none
            )
            try makePipeline(
                device: device,
                vertex: surfaceVertex,
                fragment: surfaceSolid,
                blendMode: .premultiplied
            )
            try makePipeline(
                device: device,
                vertex: surfaceVertex,
                fragment: surfaceTextured,
                blendMode: .premultiplied
            )

            print(
                "Runtime Metal library and twenty-one render pipelines passed on "
                    + device.name
            )
        } catch {
            writeStandardError("Metal runtime pipeline smoke failed: \(error)\n")
            Darwin.exit(1)
        }
    }

    private static func function(
        named name: String,
        in library: MTLLibrary
    ) throws -> MTLFunction {
        guard let function = library.makeFunction(name: name) else {
            throw SmokeError.missingFunction(name)
        }
        return function
    }

    private static func makePipeline(
        device: MTLDevice,
        vertex: MTLFunction,
        fragment: MTLFunction,
        blendMode: BlendMode
    ) throws {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.depthAttachmentPixelFormat = .depth32Float

        if blendMode != .none {
            guard let color = descriptor.colorAttachments[0] else {
                throw SmokeError.missingColorAttachment
            }
            color.isBlendingEnabled = true
            color.rgbBlendOperation = .add
            color.alphaBlendOperation = .add
            switch blendMode {
            case .none:
                preconditionFailure("handled above")
            case .premultiplied:
                color.sourceRGBBlendFactor = .one
                color.destinationRGBBlendFactor = .oneMinusSourceAlpha
                color.sourceAlphaBlendFactor = .one
                color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            case .additive:
                color.sourceRGBBlendFactor = .one
                color.destinationRGBBlendFactor = .one
                color.sourceAlphaBlendFactor = .one
                color.destinationAlphaBlendFactor = .one
            case .straightAlpha:
                color.sourceRGBBlendFactor = .sourceAlpha
                color.destinationRGBBlendFactor = .oneMinusSourceAlpha
                color.sourceAlphaBlendFactor = .one
                color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            case .straightAdditive:
                color.sourceRGBBlendFactor = .sourceAlpha
                color.destinationRGBBlendFactor = .one
                color.sourceAlphaBlendFactor = .zero
                color.destinationAlphaBlendFactor = .one
            }
        }

        _ = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private enum BlendMode {
        case none
        case premultiplied
        case additive
        case straightAlpha
        case straightAdditive
    }

    private static func writeStandardError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }

    private enum SmokeError: Error, CustomStringConvertible {
        case invalidArguments
        case commandQueueCreationFailed
        case missingFunction(String)
        case missingColorAttachment

        var description: String {
            switch self {
            case .invalidArguments:
                return "expected the extracted Metal source path"
            case .commandQueueCreationFailed:
                return "MTLDevice could not create a command queue"
            case let .missingFunction(name):
                return "Metal function is missing: \(name)"
            case .missingColorAttachment:
                return "render pipeline color attachment 0 is missing"
            }
        }
    }
}
