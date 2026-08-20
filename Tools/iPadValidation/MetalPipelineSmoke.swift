import Darwin
import Foundation
import Metal

/// Compiles the exact shader extracted from `GModMetalView` and creates the
/// four production render-pipeline shapes. Exit 78 means the CI host exposes
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
            let triangleVertex = try function(named: "vertexMain", in: library)
            let triangleFragment = try function(named: "fragmentMain", in: library)
            let worldVertex = try function(named: "worldVertexMain", in: library)
            let worldFragment = try function(named: "worldFragmentMain", in: library)
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
                vertex: triangleVertex,
                fragment: triangleFragment,
                blending: false
            )
            try makePipeline(
                device: device,
                vertex: worldVertex,
                fragment: worldFragment,
                blending: false
            )
            try makePipeline(
                device: device,
                vertex: surfaceVertex,
                fragment: surfaceSolid,
                blending: true
            )
            try makePipeline(
                device: device,
                vertex: surfaceVertex,
                fragment: surfaceTextured,
                blending: true
            )

            print(
                "Runtime Metal library and four render pipelines passed on "
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
        blending: Bool
    ) throws {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.depthAttachmentPixelFormat = .depth32Float

        if blending {
            guard let color = descriptor.colorAttachments[0] else {
                throw SmokeError.missingColorAttachment
            }
            color.isBlendingEnabled = true
            color.rgbBlendOperation = .add
            color.alphaBlendOperation = .add
            color.sourceRGBBlendFactor = .one
            color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.sourceAlphaBlendFactor = .one
            color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }

        _ = try device.makeRenderPipelineState(descriptor: descriptor)
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
