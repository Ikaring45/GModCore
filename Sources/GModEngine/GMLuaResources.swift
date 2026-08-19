import Foundation
import GModLua

/// Pixel dimensions reported by a host material-image resolver.
///
/// The Lua engine deliberately does not decode Source assets itself. The
/// desktop conformance host and the eventual iPad asset layer can both provide
/// the same resolver boundary without changing IMaterial/ITexture semantics.
public struct GMLuaImageDimensions: Sendable, Equatable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// One un-premultiplied eight-bit RGBA pixel from a decoded material image.
public struct GMLuaRGBA8: Sendable, Equatable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// Host boundary used by PNG-backed IMaterial:GetColor/ITexture:GetColor.
///
/// Returning `nil` means that this resolver did not resolve the requested
/// material. Implementations are expected to cache decoded images: a Derma
/// skin samples several pixels from the same atlas while it is constructed.
public protocol GMLuaMaterialPixelResolver: Sendable {
    func dimensions(
        materialPath: LuaString,
        encodedParameters: LuaString?
    ) throws -> GMLuaImageDimensions?

    func pixel(
        materialPath: LuaString,
        encodedParameters: LuaString?,
        x: Int,
        y: Int
    ) throws -> GMLuaRGBA8?
}

/// Whether a logical Source resource has been connected to decoded asset data.
/// This milestone only creates identity-preserving descriptors, so every newly
/// registered resource remains unresolved.
public enum GMLuaResourceResolution: String, Sendable, Equatable {
    case unresolved
}

/// Authoritative host-side state for one material lookup. This is separate
/// from decoded pixels so VMTs backed by engine render targets can report
/// their real shader and non-error identity without inventing static pixels.
public enum GMLuaMaterialResolutionStatus: String, Sendable, Equatable {
    case resolved
    case materialMissing
    case materialWithoutBaseTexture
    case baseTextureMissing
}

public struct GMLuaMaterialMetadata: Sendable, Equatable {
    public let materialPath: LuaString
    public let shaderName: LuaString
    public let baseTextureName: LuaString?
    public let dimensions: GMLuaImageDimensions?
    public let isError: Bool
    public let status: GMLuaMaterialResolutionStatus

    public init(
        materialPath: LuaString,
        shaderName: LuaString,
        baseTextureName: LuaString?,
        dimensions: GMLuaImageDimensions?,
        isError: Bool,
        status: GMLuaMaterialResolutionStatus
    ) {
        self.materialPath = materialPath
        self.shaderName = shaderName
        self.baseTextureName = baseTextureName
        self.dimensions = dimensions
        self.isError = isError
        self.status = status
    }
}

/// Optional richer material contract implemented by real Source resolvers.
/// Legacy synthetic pixel resolvers retain the original fallback behavior.
public protocol GMLuaMaterialMetadataResolver: GMLuaMaterialPixelResolver {
    func metadata(
        materialPath: LuaString,
        encodedParameters: LuaString?
    ) throws -> GMLuaMaterialMetadata
}

/// One engine request to load the particle definitions contained in a PCF.
/// The registry retains only the byte-exact logical path until a Source
/// particle decoder/renderer is connected by a later subsystem.
public struct GMLuaParticleManifestRequest: Sendable, Equatable {
    public let path: LuaString
    public let hasAssetBacking: Bool

    fileprivate init(path: LuaString) {
        self.path = path
        hasAssetBacking = false
    }
}

/// The first observed registration for one named decal. Material bytes remain
/// logical metadata until the VMT/VTF and decal-rendering subsystems exist.
public struct GMLuaDecalRegistration: Sendable, Equatable {
    public let name: LuaString
    public let material: LuaString
    public let hasAssetBacking: Bool

    fileprivate init(name: LuaString, material: LuaString) {
        self.name = name
        self.material = material
        hasAssetBacking = false
    }
}

public final class GMLuaMaterialDescriptor: @unchecked Sendable {
    public let path: LuaString
    /// The seven-bit flag string produced by the official util.lua wrapper, or
    /// nil when Material was called without image-import parameters.
    public let encodedParameters: LuaString?
    public let resolution: GMLuaResourceResolution = .unresolved
    public let hasGPUBacking = false

    fileprivate init(path: LuaString, encodedParameters: LuaString?) {
        self.path = path
        self.encodedParameters = encodedParameters
    }
}

public enum GMLuaTextureDescriptorKind: Sendable, Equatable {
    case screenEffect(index: Int)
    case materialBaseTexture(path: LuaString, encodedParameters: LuaString?)
    /// An engine-owned render target exposed by a named render-library getter.
    /// The name is an identity token; this descriptor does not claim pixels or
    /// GPU storage exist in the current host.
    case engineRenderTarget(name: LuaString)
    /// A logical render target requested through GetRenderTargetEx. The first
    /// request for a canonical Source texture name owns its creation settings.
    case renderTarget(GMLuaRenderTargetRequest)
}

/// Creation settings retained for a logical GetRenderTargetEx resource.
///
/// These are metadata only until the renderer connects a GPU-backed target.
public struct GMLuaRenderTargetRequest: Sendable, Equatable {
    public let name: LuaString
    public let width: Int
    public let height: Int
    public let sizeMode: Int
    public let depthMode: Int
    public let textureFlags: Int
    public let renderTargetFlags: Int
    public let imageFormat: Int

    public init(
        name: LuaString,
        width: Int,
        height: Int,
        sizeMode: Int,
        depthMode: Int,
        textureFlags: Int,
        renderTargetFlags: Int,
        imageFormat: Int
    ) {
        self.name = name
        self.width = width
        self.height = height
        self.sizeMode = sizeMode
        self.depthMode = depthMode
        self.textureFlags = textureFlags
        self.renderTargetFlags = renderTargetFlags
        self.imageFormat = imageFormat
    }
}

public final class GMLuaTextureDescriptor: @unchecked Sendable {
    public let name: LuaString
    public let kind: GMLuaTextureDescriptorKind
    public let resolution: GMLuaResourceResolution = .unresolved
    public let hasGPUBacking = false

    fileprivate init(name: LuaString, kind: GMLuaTextureDescriptorKind) {
        self.name = name
        self.kind = kind
    }
}

private struct GMLuaMaterialKey: Hashable {
    let path: LuaString
    let encodedParameters: LuaString?
}

/// State-local identity and descriptor registry for Source materials/textures.
///
/// It does not parse VMT/VTF files and does not allocate GPU resources. The
/// retained Lua userdata identities are the hand-off boundary for those later
/// asset and renderer layers.
public final class GMLuaResourceRegistry: @unchecked Sendable {
    private let typeSystem: GMLuaTypeSystem
    private let lock = NSLock()
    private var materialValues: [GMLuaMaterialKey: LuaValue] = [:]
    private var textureValues: [Int: LuaValue] = [:]
    private var materialTextureValues: [GMLuaMaterialKey: LuaValue] = [:]
    private var namedTextureValues: [LuaString: LuaValue] = [:]
    private var materialTextureBindings: [GMLuaMaterialKey: [LuaString: LuaValue]] = [:]
    private var materialPixelResolver: (any GMLuaMaterialPixelResolver)?
    private var requestedSounds: Set<LuaString> = []
    private var requestedModels: Set<LuaString> = []
    private var requestedParticleSystems: Set<LuaString> = []
    private var requestedParticleManifestPaths: Set<LuaString> = []
    private var particleManifestStorage: [GMLuaParticleManifestRequest] = []
    private var registeredDecalNames: Set<LuaString> = []
    private var decalRegistrationStorage: [GMLuaDecalRegistration] = []

    fileprivate init(typeSystem: GMLuaTypeSystem) {
        self.typeSystem = typeSystem
    }

    public var materialCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return materialValues.count
    }

    public var textureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return textureValues.count + materialTextureValues.count + namedTextureValues.count
    }

    /// True only after the embedding host has connected a real decoded-image
    /// source. An absent resolver is not silently replaced with a fake palette.
    public var hasMaterialPixelResolver: Bool {
        lock.lock()
        defer { lock.unlock() }
        return materialPixelResolver != nil
    }

    /// Connects or removes the decoded-image source used by material pixels.
    /// Existing Lua userdata identities remain valid across resolver changes.
    public func setMaterialPixelResolver(
        _ resolver: (any GMLuaMaterialPixelResolver)?
    ) {
        lock.lock()
        materialPixelResolver = resolver
        lock.unlock()
    }

    /// Logical requests retained for the future Source asset resolver. A name
    /// appearing here does not claim that its WAV/MP3, MDL, or PCF data has
    /// already been found or decoded.
    public var precachedSoundNames: [LuaString] {
        lock.lock()
        defer { lock.unlock() }
        return requestedSounds.sorted()
    }

    public var precachedModelNames: [LuaString] {
        lock.lock()
        defer { lock.unlock() }
        return requestedModels.sorted()
    }

    public var precachedParticleSystemNames: [LuaString] {
        lock.lock()
        defer { lock.unlock() }
        return requestedParticleSystems.sorted()
    }

    /// PCF load requests in first-observed order. Repeated calls preserve the
    /// first request and never imply that the corresponding bytes were loaded.
    public var particleManifestRequests: [GMLuaParticleManifestRequest] {
        lock.lock()
        defer { lock.unlock() }
        return particleManifestStorage
    }

    /// First registration for each byte-exact name, in observation order.
    /// Re-registering a name does not manufacture replacement asset backing.
    public var decalRegistrations: [GMLuaDecalRegistration] {
        lock.lock()
        defer { lock.unlock() }
        return decalRegistrationStorage
    }

    public func materialDescriptor(
        path: LuaString,
        encodedParameters: LuaString? = nil
    ) -> GMLuaMaterialDescriptor? {
        lock.lock()
        let value = materialValues[
            GMLuaMaterialKey(path: path, encodedParameters: encodedParameters)
        ]
        lock.unlock()
        return Self.materialDescriptor(from: value)
    }

    public func screenEffectTextureDescriptor(index: Int) -> GMLuaTextureDescriptor? {
        lock.lock()
        let value = textureValues[index]
        lock.unlock()
        return Self.textureDescriptor(from: value)
    }

    public func namedTextureDescriptor(name: LuaString) -> GMLuaTextureDescriptor? {
        let key = Self.canonicalResourceName(name)
        lock.lock()
        let value = namedTextureValues[key]
        lock.unlock()
        return Self.textureDescriptor(from: value)
    }

    fileprivate var references: [LuaValue] {
        lock.lock()
        defer { lock.unlock() }
        return Array(materialValues.values)
            + Array(textureValues.values)
            + Array(materialTextureValues.values)
            + Array(namedTextureValues.values)
            + materialTextureBindings.values.flatMap { $0.values }
    }

    fileprivate func material(path: LuaString, parameters: LuaString?) throws -> LuaValue {
        let key = GMLuaMaterialKey(path: path, encodedParameters: parameters)
        lock.lock()
        defer { lock.unlock() }
        if let existing = materialValues[key] {
            return existing
        }
        let descriptor = GMLuaMaterialDescriptor(path: path, encodedParameters: parameters)
        let value = try typeSystem.makeObject(metaName: "IMaterial", payload: descriptor)
        materialValues[key] = value
        return value
    }

    fileprivate func screenEffectTexture(index: Int) throws -> LuaValue {
        lock.lock()
        defer { lock.unlock() }
        if let existing = textureValues[index] {
            return existing
        }
        let suffix = index == 0 ? "" : String(index)
        let descriptor = GMLuaTextureDescriptor(
            name: LuaString("_rt_fullframefb\(suffix)"),
            kind: .screenEffect(index: index)
        )
        let value = try typeSystem.makeObject(metaName: "ITexture", payload: descriptor)
        textureValues[index] = value
        return value
    }

    fileprivate func baseTexture(for material: GMLuaMaterialDescriptor) throws -> LuaValue? {
        let key = GMLuaMaterialKey(
            path: material.path,
            encodedParameters: material.encodedParameters
        )
        let resolvedMetadata = try metadata(
            path: material.path,
            encodedParameters: material.encodedParameters
        )
        let textureName: LuaString
        if let resolvedMetadata {
            guard resolvedMetadata.status == .resolved,
                  let resolvedName = resolvedMetadata.baseTextureName else {
                return nil
            }
            textureName = resolvedName
        } else {
            // Legacy PNG pixel resolvers predate material metadata. A decoded
            // image is still authoritative backing; an unresolved lookup is
            // not an ITexture and must surface to Lua as no return value.
            guard try dimensions(
                path: material.path,
                encodedParameters: material.encodedParameters
            ) != nil else { return nil }
            textureName = material.path
        }
        lock.lock()
        defer { lock.unlock() }
        if let existing = materialTextureValues[key] {
            return existing
        }
        let descriptor = GMLuaTextureDescriptor(
            name: textureName,
            kind: .materialBaseTexture(
                path: material.path,
                encodedParameters: material.encodedParameters
            )
        )
        let value = try typeSystem.makeObject(metaName: "ITexture", payload: descriptor)
        materialTextureValues[key] = value
        return value
    }

    fileprivate func setTexture(
        _ texture: LuaValue,
        parameter: LuaString,
        for material: GMLuaMaterialDescriptor
    ) throws {
        guard Self.textureDescriptor(from: texture) != nil else {
            throw LuaError.runtime(
                "bad argument #2 to 'IMaterial:SetTexture' (ITexture expected, got \(texture.typeName))"
            )
        }
        let materialKey = GMLuaMaterialKey(
            path: material.path,
            encodedParameters: material.encodedParameters
        )
        let parameterKey = Self.canonicalResourceName(parameter)
        lock.lock()
        materialTextureBindings[materialKey, default: [:]][parameterKey] = texture
        lock.unlock()
    }

    fileprivate func boundTexture(
        parameter: LuaString,
        for material: GMLuaMaterialDescriptor
    ) -> LuaValue? {
        let materialKey = GMLuaMaterialKey(
            path: material.path,
            encodedParameters: material.encodedParameters
        )
        let parameterKey = Self.canonicalResourceName(parameter)
        lock.lock()
        let value = materialTextureBindings[materialKey]?[parameterKey]
        lock.unlock()
        return value
    }

    fileprivate func engineRenderTarget(
        name: LuaString
    ) throws -> LuaValue {
        let key = Self.canonicalResourceName(name)
        lock.lock()
        defer { lock.unlock() }
        if let existing = namedTextureValues[key] {
            return existing
        }
        let descriptor = GMLuaTextureDescriptor(
            name: name,
            kind: .engineRenderTarget(name: name)
        )
        let value = try typeSystem.makeObject(metaName: "ITexture", payload: descriptor)
        namedTextureValues[key] = value
        return value
    }

    fileprivate func renderTarget(
        request: GMLuaRenderTargetRequest
    ) throws -> LuaValue {
        let canonicalName = Self.renderTargetNameWithoutExtension(request.name)
        let key = Self.canonicalResourceName(canonicalName)
        lock.lock()
        defer { lock.unlock() }
        if let existing = namedTextureValues[key] {
            return existing
        }
        let canonicalRequest = GMLuaRenderTargetRequest(
            name: canonicalName,
            width: request.width,
            height: request.height,
            sizeMode: request.sizeMode,
            depthMode: request.depthMode,
            textureFlags: request.textureFlags,
            renderTargetFlags: request.renderTargetFlags,
            imageFormat: request.imageFormat
        )
        let descriptor = GMLuaTextureDescriptor(
            name: canonicalName,
            kind: .renderTarget(canonicalRequest)
        )
        let value = try typeSystem.makeObject(metaName: "ITexture", payload: descriptor)
        namedTextureValues[key] = value
        return value
    }

    fileprivate func dimensions(
        path: LuaString,
        encodedParameters: LuaString?
    ) throws -> GMLuaImageDimensions? {
        lock.lock()
        let resolver = materialPixelResolver
        lock.unlock()
        return try resolver?.dimensions(
            materialPath: path,
            encodedParameters: encodedParameters
        )
    }

    fileprivate func pixel(
        path: LuaString,
        encodedParameters: LuaString?,
        x: Int,
        y: Int
    ) throws -> GMLuaRGBA8? {
        lock.lock()
        let resolver = materialPixelResolver
        lock.unlock()
        return try resolver?.pixel(
            materialPath: path,
            encodedParameters: encodedParameters,
            x: x,
            y: y
        )
    }

    fileprivate func shaderName(for material: GMLuaMaterialDescriptor) throws -> LuaString {
        if let metadata = try metadata(
            path: material.path,
            encodedParameters: material.encodedParameters
        ) {
            return metadata.shaderName
        }
        // Imported PNG/JPG materials have a deterministic generated shader.
        // Other unresolved paths require VMT parsing and truthfully expose
        // Source's no-loaded-shader sentinel instead of guessing a shader.
        let path = material.path.utf8String.lowercased()
        let isImportedImage = path.hasSuffix(".png") || path.hasSuffix(".jpg")
        guard isImportedImage,
              try dimensions(
                  path: material.path,
                  encodedParameters: material.encodedParameters
              ) != nil else {
            return "shader_error"
        }
        let parameters = material.encodedParameters?.utf8String.lowercased() ?? ""
        let tokens = parameters.split(whereSeparator: { $0.isWhitespace })
        return tokens.contains("vertexlitgeneric")
            ? "VertexLitGeneric"
            : "UnlitGeneric"
    }

    fileprivate func materialIsError(
        _ material: GMLuaMaterialDescriptor
    ) throws -> Bool? {
        if let metadata = try metadata(
            path: material.path,
            encodedParameters: material.encodedParameters
        ) {
            return metadata.isError
        }
        return try dimensions(
            path: material.path,
            encodedParameters: material.encodedParameters
        ).map { _ in false }
    }

    private func metadata(
        path: LuaString,
        encodedParameters: LuaString?
    ) throws -> GMLuaMaterialMetadata? {
        lock.lock()
        let resolver = materialPixelResolver as? any GMLuaMaterialMetadataResolver
        lock.unlock()
        return try resolver?.metadata(
            materialPath: path,
            encodedParameters: encodedParameters
        )
    }

    fileprivate func noteSound(_ name: LuaString) {
        lock.lock()
        requestedSounds.insert(name)
        lock.unlock()
    }

    fileprivate func noteModel(_ name: LuaString) {
        lock.lock()
        requestedModels.insert(name)
        lock.unlock()
    }

    fileprivate func noteParticleSystem(_ name: LuaString) {
        lock.lock()
        requestedParticleSystems.insert(name)
        lock.unlock()
    }

    fileprivate func noteParticleManifest(_ path: LuaString) {
        lock.lock()
        defer { lock.unlock() }
        guard requestedParticleManifestPaths.insert(path).inserted else { return }
        particleManifestStorage.append(GMLuaParticleManifestRequest(path: path))
    }

    fileprivate func noteDecal(name: LuaString, material: LuaString) {
        lock.lock()
        defer { lock.unlock() }
        guard registeredDecalNames.insert(name).inserted else { return }
        decalRegistrationStorage.append(GMLuaDecalRegistration(
            name: name,
            material: material
        ))
    }

    fileprivate static func materialDescriptor(from value: LuaValue?) -> GMLuaMaterialDescriptor? {
        guard let value,
              let object = GMLuaTypeSystem.typedObject(from: value),
              object.metaName == "IMaterial" else { return nil }
        return object.payload as? GMLuaMaterialDescriptor
    }

    fileprivate static func textureDescriptor(from value: LuaValue?) -> GMLuaTextureDescriptor? {
        guard let value,
              let object = GMLuaTypeSystem.typedObject(from: value),
              object.metaName == "ITexture" else { return nil }
        return object.payload as? GMLuaTextureDescriptor
    }

    private static func canonicalResourceName(_ value: LuaString) -> LuaString {
        LuaString(bytes: value.bytes.map { byte in
            (65...90).contains(byte) ? byte + 32 : byte
        })
    }

    /// Source treats render-target names as paths and discards the extension.
    private static func renderTargetNameWithoutExtension(_ value: LuaString) -> LuaString {
        let bytes = value.bytes
        let lastSeparator = bytes.lastIndex(where: { $0 == 47 || $0 == 92 })
        guard let dot = bytes.lastIndex(of: 46),
              lastSeparator.map({ dot > $0 }) ?? true else { return value }
        return LuaString(bytes: Array(bytes[..<dot]))
    }
}

/// Installs the native resource-handle boundary captured by official util.lua.
public enum GMLuaResources {
    @discardableResult
    public static func install(
        into state: LuaState,
        typeSystem: GMLuaTypeSystem,
        realm: GMLuaRealm
    ) throws -> GMLuaResourceRegistry {
        let registry = GMLuaResourceRegistry(typeSystem: typeSystem)

        guard let materialMetatable = typeSystem.metatable(named: "IMaterial"),
              let textureMetatable = typeSystem.metatable(named: "ITexture") else {
            throw LuaError.runtime("GLua material/texture metatables are unavailable")
        }

        let materialGetName = LuaNativeFunctionBox(
            { arguments in
                guard let descriptor = GMLuaResourceRegistry.materialDescriptor(
                    from: arguments.first
                ) else {
                    throw LuaError.runtime("bad self to 'IMaterial:GetName'")
                }
                return [.string(descriptor.path)]
            },
            debugName: "IMaterial:GetName"
        )
        try state.setRawTableValue(
            .nativeFunction(materialGetName),
            for: .string("GetName"),
            in: materialMetatable
        )

        let materialGetShader = LuaNativeFunctionBox(
            { [registry] arguments in
                guard let descriptor = GMLuaResourceRegistry.materialDescriptor(
                    from: arguments.first
                ) else {
                    throw LuaError.runtime("bad self to 'IMaterial:GetShader'")
                }
                return [.string(try registry.shaderName(for: descriptor))]
            },
            debugName: "IMaterial:GetShader"
        )
        try state.setRawTableValue(
            .nativeFunction(materialGetShader),
            for: .string("GetShader"),
            in: materialMetatable
        )

        let materialGetColor = LuaNativeFunctionBox(
            { [unowned state, registry] arguments in
                guard let descriptor = GMLuaResourceRegistry.materialDescriptor(
                    from: arguments.first
                ) else {
                    throw LuaError.runtime("bad self to 'IMaterial:GetColor'")
                }
                let (x, y) = try pixelCoordinates(arguments, functionName: "IMaterial:GetColor")
                let pixel = try resolvedPixel(
                    registry: registry,
                    path: descriptor.path,
                    encodedParameters: descriptor.encodedParameters,
                    x: x,
                    y: y,
                    functionName: "IMaterial:GetColor"
                )
                return [try colorValue(pixel, state: state)]
            },
            debugName: "IMaterial:GetColor",
            gcReferences: { [weak registry] in registry?.references ?? [] }
        )
        try state.setRawTableValue(
            .nativeFunction(materialGetColor),
            for: .string("GetColor"),
            in: materialMetatable
        )

        let materialGetTexture = LuaNativeFunctionBox(
            { [registry] arguments in
                guard let descriptor = GMLuaResourceRegistry.materialDescriptor(
                    from: arguments.first
                ) else {
                    throw LuaError.runtime("bad self to 'IMaterial:GetTexture'")
                }
                let parameter = try requiredString(
                    arguments,
                    index: 1,
                    functionName: "IMaterial:GetTexture"
                )
                if let bound = registry.boundTexture(
                    parameter: parameter,
                    for: descriptor
                ) {
                    return [bound]
                }
                guard asciiCaseInsensitiveEqual(parameter, "$basetexture") else {
                    return []
                }
                guard let texture = try registry.baseTexture(for: descriptor) else {
                    return []
                }
                return [texture]
            },
            debugName: "IMaterial:GetTexture",
            gcReferences: { [weak registry] in registry?.references ?? [] }
        )
        try state.setRawTableValue(
            .nativeFunction(materialGetTexture),
            for: .string("GetTexture"),
            in: materialMetatable
        )

        let materialSetTexture = LuaNativeFunctionBox(
            { [registry] arguments in
                guard let descriptor = GMLuaResourceRegistry.materialDescriptor(
                    from: arguments.first
                ) else {
                    throw LuaError.runtime("bad self to 'IMaterial:SetTexture'")
                }
                let parameter = try requiredString(
                    arguments,
                    index: 1,
                    functionName: "IMaterial:SetTexture"
                )
                guard arguments.indices.contains(2) else {
                    throw LuaError.runtime(
                        "bad argument #2 to 'IMaterial:SetTexture' (ITexture expected, got no value)"
                    )
                }
                try registry.setTexture(
                    arguments[2],
                    parameter: parameter,
                    for: descriptor
                )
                return []
            },
            debugName: "IMaterial:SetTexture",
            gcReferences: { [weak registry] in registry?.references ?? [] }
        )
        try state.setRawTableValue(
            .nativeFunction(materialSetTexture),
            for: .string("SetTexture"),
            in: materialMetatable
        )

        for (name, component) in [("Width", true), ("Height", false)] {
            let method = LuaNativeFunctionBox(
                { [registry] arguments in
                    guard let descriptor = GMLuaResourceRegistry.materialDescriptor(
                        from: arguments.first
                    ) else {
                        throw LuaError.runtime("bad self to 'IMaterial:\(name)'")
                    }
                    let dimensions = try requiredDimensions(
                        registry: registry,
                        path: descriptor.path,
                        encodedParameters: descriptor.encodedParameters,
                        functionName: "IMaterial:\(name)"
                    )
                    return [.number(Double(component ? dimensions.width : dimensions.height))]
                },
                debugName: "IMaterial:\(name)",
                gcReferences: { [weak registry] in registry?.references ?? [] }
            )
            try state.setRawTableValue(
                .nativeFunction(method),
                for: .string(LuaString(name)),
                in: materialMetatable
            )
        }

        let materialIsError = LuaNativeFunctionBox(
            { [registry] arguments in
                guard let descriptor = GMLuaResourceRegistry.materialDescriptor(
                    from: arguments.first
                ) else {
                    throw LuaError.runtime("bad self to 'IMaterial:IsError'")
                }
                guard let isError = try registry.materialIsError(descriptor) else {
                    throw LuaError.runtime(
                        "IMaterial:IsError cannot determine material error state " +
                        "without authoritative asset resolution for '\(descriptor.path.utf8String)'"
                    )
                }
                return [.boolean(isError)]
            },
            debugName: "IMaterial:IsError",
            gcReferences: { [weak registry] in registry?.references ?? [] }
        )
        try state.setRawTableValue(
            .nativeFunction(materialIsError),
            for: .string("IsError"),
            in: materialMetatable
        )

        let textureGetName = LuaNativeFunctionBox(
            { arguments in
                guard let descriptor = GMLuaResourceRegistry.textureDescriptor(
                    from: arguments.first
                ) else {
                    throw LuaError.runtime("bad self to 'ITexture:GetName'")
                }
                return [.string(descriptor.name)]
            },
            debugName: "ITexture:GetName"
        )
        try state.setRawTableValue(
            .nativeFunction(textureGetName),
            for: .string("GetName"),
            in: textureMetatable
        )

        let textureGetColor = LuaNativeFunctionBox(
            { [unowned state, registry] arguments in
                guard let descriptor = GMLuaResourceRegistry.textureDescriptor(
                    from: arguments.first
                ) else {
                    throw LuaError.runtime("bad self to 'ITexture:GetColor'")
                }
                let source = try materialSource(
                    descriptor,
                    functionName: "ITexture:GetColor"
                )
                let (x, y) = try pixelCoordinates(arguments, functionName: "ITexture:GetColor")
                let pixel = try resolvedPixel(
                    registry: registry,
                    path: source.path,
                    encodedParameters: source.encodedParameters,
                    x: x,
                    y: y,
                    functionName: "ITexture:GetColor"
                )
                return [try colorValue(pixel, state: state)]
            },
            debugName: "ITexture:GetColor",
            gcReferences: { [weak registry] in registry?.references ?? [] }
        )
        try state.setRawTableValue(
            .nativeFunction(textureGetColor),
            for: .string("GetColor"),
            in: textureMetatable
        )

        for (name, component) in [("Width", true), ("Height", false)] {
            let method = LuaNativeFunctionBox(
                { [registry] arguments in
                    guard let descriptor = GMLuaResourceRegistry.textureDescriptor(
                        from: arguments.first
                    ) else {
                        throw LuaError.runtime("bad self to 'ITexture:\(name)'")
                    }
                    let source = try materialSource(
                        descriptor,
                        functionName: "ITexture:\(name)"
                    )
                    let dimensions = try requiredDimensions(
                        registry: registry,
                        path: source.path,
                        encodedParameters: source.encodedParameters,
                        functionName: "ITexture:\(name)"
                    )
                    return [.number(Double(component ? dimensions.width : dimensions.height))]
                },
                debugName: "ITexture:\(name)",
                gcReferences: { [weak registry] in registry?.references ?? [] }
            )
            try state.setRawTableValue(
                .nativeFunction(method),
                for: .string(LuaString(name)),
                in: textureMetatable
            )
        }

        let materialFunction = LuaNativeFunctionBox(
            { [registry] arguments in
                let started = ProcessInfo.processInfo.systemUptime
                let path = try requiredString(
                    arguments,
                    index: 0,
                    functionName: "Material"
                )
                let parameters = try optionalString(
                    arguments,
                    index: 1,
                    functionName: "Material"
                )
                let value = try registry.material(path: path, parameters: parameters)
                let elapsed = max(0, ProcessInfo.processInfo.systemUptime - started)
                return [value, .number(elapsed)]
            },
            debugName: "Material",
            gcReferences: { [weak registry] in registry?.references ?? [] }
        )
        state.setGlobal("Material", value: .nativeFunction(materialFunction))

        let utilTable: LuaTable
        if case let .table(existing) = state.getGlobal("util") {
            utilTable = existing
        } else {
            utilTable = LuaTable()
        }
        let precacheSound = LuaNativeFunctionBox(
            { [registry] arguments in
                let name = try requiredString(
                    arguments,
                    index: 0,
                    functionName: "PrecacheSound"
                )
                // Desktop GMod currently documents this call as a no-op. The
                // logical request is retained only for future asset tracing.
                registry.noteSound(name)
                return []
            },
            debugName: "util.PrecacheSound"
        )
        let precacheModel = LuaNativeFunctionBox(
            { [registry] arguments in
                let name = try requiredString(
                    arguments,
                    index: 0,
                    functionName: "PrecacheModel"
                )
                // The engine call does nothing clientside.
                if realm == .server { registry.noteModel(name) }
                return []
            },
            debugName: "util.PrecacheModel"
        )
        try state.setRawTableValue(
            .nativeFunction(precacheSound),
            for: .string("PrecacheSound"),
            in: utilTable
        )
        try state.setRawTableValue(
            .nativeFunction(precacheModel),
            for: .string("PrecacheModel"),
            in: utilTable
        )
        state.setGlobal("util", value: .table(utilTable))

        if realm == .server || realm == .client {
            let precacheParticleSystem = LuaNativeFunctionBox(
                { [registry] arguments in
                    let name = try requiredString(
                        arguments,
                        index: 0,
                        functionName: "PrecacheParticleSystem"
                    )
                    registry.noteParticleSystem(name)
                    return []
                },
                debugName: "PrecacheParticleSystem"
            )
            state.setGlobal(
                "PrecacheParticleSystem",
                value: .nativeFunction(precacheParticleSystem)
            )
        }

        let gameTable: LuaTable
        if case let .table(existing) = state.getGlobal("game") {
            gameTable = existing
        } else {
            gameTable = LuaTable()
        }
        if realm == .server || realm == .client {
            let addParticles = LuaNativeFunctionBox(
                { [registry] arguments in
                    let path = try requiredString(
                        arguments,
                        index: 0,
                        functionName: "AddParticles"
                    )
                    registry.noteParticleManifest(path)
                    return []
                },
                debugName: "game.AddParticles"
            )
            try state.setRawTableValue(
                .nativeFunction(addParticles),
                for: .string("AddParticles"),
                in: gameTable
            )
            let addDecal = LuaNativeFunctionBox(
                { [registry] arguments in
                    let name = try requiredString(
                        arguments,
                        index: 0,
                        functionName: "AddDecal"
                    )
                    let material = try requiredString(
                        arguments,
                        index: 1,
                        functionName: "AddDecal"
                    )
                    registry.noteDecal(name: name, material: material)
                    return []
                },
                debugName: "game.AddDecal"
            )
            try state.setRawTableValue(
                .nativeFunction(addDecal),
                for: .string("AddDecal"),
                in: gameTable
            )
        }
        state.setGlobal("game", value: .table(gameTable))

        if realm != .server {
            let renderTable: LuaTable
            if case let .table(existing) = state.getGlobal("render") {
                renderTable = existing
            } else {
                renderTable = LuaTable()
            }
            let getScreenEffectTexture = LuaNativeFunctionBox(
                { [registry] arguments in
                    let index = try screenEffectIndex(arguments)
                    return [try registry.screenEffectTexture(index: index)]
                },
                debugName: "render.GetScreenEffectTexture",
                gcReferences: { [weak registry] in registry?.references ?? [] }
            )
            try state.setRawTableValue(
                .nativeFunction(getScreenEffectTexture),
                for: .string("GetScreenEffectTexture"),
                in: renderTable
            )

            // These getters expose stable engine render-target identities. They
            // intentionally remain unresolved until a renderer supplies actual
            // pixel/GPU backing.
            for (functionName, textureName) in [
                ("GetBloomTex0", "_rt_SmallFB0"),
                ("GetBloomTex1", "_rt_SmallFB1"),
                ("GetMoBlurTex0", "s_pMoBlurTex0"),
                ("GetMoBlurTex1", "s_pMoBlurTex1"),
                ("GetSuperFPTex", "_rt_SuperTexture1"),
                ("GetSuperFPTex2", "_rt_SuperTexture2")
            ] {
                let getter = LuaNativeFunctionBox(
                    { [registry] _ in
                        [try registry.engineRenderTarget(name: LuaString(textureName))]
                    },
                    debugName: "render.\(functionName)",
                    gcReferences: { [weak registry] in registry?.references ?? [] }
                )
                try state.setRawTableValue(
                    .nativeFunction(getter),
                    for: .string(LuaString(functionName)),
                    in: renderTable
                )
            }
            state.setGlobal("render", value: .table(renderTable))

            let getRenderTargetEx = LuaNativeFunctionBox(
                { [registry] arguments in
                    let request = try renderTargetRequest(arguments)
                    return [try registry.renderTarget(request: request)]
                },
                debugName: "GetRenderTargetEx",
                gcReferences: { [weak registry] in registry?.references ?? [] }
            )
            state.setGlobal(
                "GetRenderTargetEx",
                value: .nativeFunction(getRenderTargetEx)
            )
            let getRenderTarget = LuaNativeFunctionBox(
                { [registry] arguments in
                    let request = try simpleRenderTargetRequest(arguments)
                    return [try registry.renderTarget(request: request)]
                },
                debugName: "GetRenderTarget",
                gcReferences: { [weak registry] in registry?.references ?? [] }
            )
            state.setGlobal(
                "GetRenderTarget",
                value: .nativeFunction(getRenderTarget)
            )

            // Exact values from the public STUDIO enum used at halo.lua load.
            state.setGlobal("STUDIO_RENDER", value: .number(1))
            state.setGlobal("STUDIO_SKIP_DECALS", value: .number(268_435_456))

            // Public render-target enum values used by the stock
            // postprocess/frame_blend.lua top-level resource declaration.
            state.setGlobal("RT_SIZE_FULL_FRAME_BUFFER", value: .number(4))
            state.setGlobal("RT_SIZE_NO_CHANGE", value: .number(0))
            state.setGlobal("MATERIAL_RT_DEPTH_SEPARATE", value: .number(1))
            state.setGlobal("MATERIAL_RT_DEPTH_NONE", value: .number(2))
            state.setGlobal("IMAGE_FORMAT_DEFAULT", value: .number(-1))
            state.setGlobal("IMAGE_FORMAT_BGRA8888", value: .number(12))
        }

        return registry
    }

    private static func requiredString(
        _ arguments: [LuaValue],
        index: Int,
        functionName: String
    ) throws -> LuaString {
        guard arguments.indices.contains(index) else {
            throw LuaError.runtime(
                "bad argument #\(index + 1) to '\(functionName)' (string expected, got no value)"
            )
        }
        switch arguments[index] {
        case let .string(value): return value
        case let .number(value): return LuaString(LuaValue.number(value).printable)
        default:
            throw LuaError.runtime(
                "bad argument #\(index + 1) to '\(functionName)' " +
                "(string expected, got \(arguments[index].typeName))"
            )
        }
    }

    private static func optionalString(
        _ arguments: [LuaValue],
        index: Int,
        functionName: String
    ) throws -> LuaString? {
        guard arguments.indices.contains(index) else { return nil }
        if case .nilValue = arguments[index] { return nil }
        return try requiredString(arguments, index: index, functionName: functionName)
    }

    private static func screenEffectIndex(_ arguments: [LuaValue]) throws -> Int {
        guard let first = arguments.first else { return 0 }
        if case .nilValue = first { return 0 }
        guard case let .number(rawIndex) = first else {
            throw LuaError.runtime(
                "bad argument #1 to 'GetScreenEffectTexture' (number expected)"
            )
        }
        let truncated = rawIndex.rounded(.towardZero)
        guard truncated.isFinite, truncated >= 0, truncated <= 3 else {
            throw LuaError.runtime(
                "bad argument #1 to 'GetScreenEffectTexture' (index must be between 0 and 3)"
            )
        }
        return Int(truncated)
    }

    private static func renderTargetRequest(
        _ arguments: [LuaValue]
    ) throws -> GMLuaRenderTargetRequest {
        GMLuaRenderTargetRequest(
            name: try requiredString(
                arguments,
                index: 0,
                functionName: "GetRenderTargetEx"
            ),
            width: try requiredInteger(
                arguments,
                index: 1,
                functionName: "GetRenderTargetEx"
            ),
            height: try requiredInteger(
                arguments,
                index: 2,
                functionName: "GetRenderTargetEx"
            ),
            sizeMode: try requiredInteger(
                arguments,
                index: 3,
                functionName: "GetRenderTargetEx"
            ),
            depthMode: try requiredInteger(
                arguments,
                index: 4,
                functionName: "GetRenderTargetEx"
            ),
            textureFlags: try requiredInteger(
                arguments,
                index: 5,
                functionName: "GetRenderTargetEx"
            ),
            renderTargetFlags: try requiredInteger(
                arguments,
                index: 6,
                functionName: "GetRenderTargetEx"
            ),
            imageFormat: try requiredInteger(
                arguments,
                index: 7,
                functionName: "GetRenderTargetEx"
            )
        )
    }

    /// Public GetRenderTarget is the fixed-policy Source shorthand for
    /// GetRenderTargetEx documented by Facepunch.
    private static func simpleRenderTargetRequest(
        _ arguments: [LuaValue]
    ) throws -> GMLuaRenderTargetRequest {
        GMLuaRenderTargetRequest(
            name: try requiredString(
                arguments,
                index: 0,
                functionName: "GetRenderTarget"
            ),
            width: try requiredInteger(
                arguments,
                index: 1,
                functionName: "GetRenderTarget"
            ),
            height: try requiredInteger(
                arguments,
                index: 2,
                functionName: "GetRenderTarget"
            ),
            sizeMode: 0,
            depthMode: 1,
            textureFlags: 2 | 256,
            renderTargetFlags: 0,
            imageFormat: 12
        )
    }

    private static func requiredInteger(
        _ arguments: [LuaValue],
        index: Int,
        functionName: String
    ) throws -> Int {
        guard arguments.indices.contains(index), case let .number(value) = arguments[index] else {
            let actual = arguments.indices.contains(index) ? arguments[index].typeName : "no value"
            throw LuaError.runtime(
                "bad argument #\(index + 1) to '\(functionName)' (number expected, got \(actual))"
            )
        }
        let truncated = value.rounded(.towardZero)
        guard truncated.isFinite,
              truncated >= Double(Int32.min),
              truncated <= Double(Int32.max) else {
            throw LuaError.runtime(
                "bad argument #\(index + 1) to '\(functionName)' (32-bit integer expected)"
            )
        }
        return Int(truncated)
    }

    private static func pixelCoordinates(
        _ arguments: [LuaValue],
        functionName: String
    ) throws -> (Int, Int) {
        (
            try pixelCoordinate(arguments, index: 1, functionName: functionName),
            try pixelCoordinate(arguments, index: 2, functionName: functionName)
        )
    }

    private static func pixelCoordinate(
        _ arguments: [LuaValue],
        index: Int,
        functionName: String
    ) throws -> Int {
        guard arguments.indices.contains(index), case let .number(value) = arguments[index] else {
            let actual = arguments.indices.contains(index) ? arguments[index].typeName : "no value"
            throw LuaError.runtime(
                "bad argument #\(index) to '\(functionName)' (number expected, got \(actual))"
            )
        }
        let truncated = value.rounded(.towardZero)
        guard truncated.isFinite,
              truncated >= Double(Int32.min),
              truncated <= Double(Int32.max) else {
            throw LuaError.runtime(
                "bad argument #\(index) to '\(functionName)' (finite pixel coordinate expected)"
            )
        }
        return Int(truncated)
    }

    private static func requiredDimensions(
        registry: GMLuaResourceRegistry,
        path: LuaString,
        encodedParameters: LuaString?,
        functionName: String
    ) throws -> GMLuaImageDimensions {
        guard let dimensions = try registry.dimensions(
            path: path,
            encodedParameters: encodedParameters
        ) else {
            throw LuaError.runtime(
                "\(functionName) requires decoded image backing for material '\(path.utf8String)'"
            )
        }
        guard dimensions.width > 0, dimensions.height > 0 else {
            throw LuaError.runtime(
                "\(functionName) received invalid image dimensions for material '\(path.utf8String)'"
            )
        }
        return dimensions
    }

    private static func resolvedPixel(
        registry: GMLuaResourceRegistry,
        path: LuaString,
        encodedParameters: LuaString?,
        x: Int,
        y: Int,
        functionName: String
    ) throws -> GMLuaRGBA8 {
        let dimensions = try requiredDimensions(
            registry: registry,
            path: path,
            encodedParameters: encodedParameters,
            functionName: functionName
        )
        guard x >= 0, y >= 0, x < dimensions.width, y < dimensions.height else {
            throw LuaError.runtime(
                "\(functionName) pixel (\(x), \(y)) is outside " +
                "\(dimensions.width)x\(dimensions.height) material '\(path.utf8String)'"
            )
        }
        guard let pixel = try registry.pixel(
            path: path,
            encodedParameters: encodedParameters,
            x: x,
            y: y
        ) else {
            throw LuaError.runtime(
                "\(functionName) could not resolve pixel (\(x), \(y)) " +
                "for material '\(path.utf8String)'"
            )
        }
        return pixel
    }

    private static func colorValue(
        _ pixel: GMLuaRGBA8,
        state: LuaState
    ) throws -> LuaValue {
        let constructor = state.getGlobal("Color")
        switch constructor {
        case .luaFunction, .nativeFunction:
            return try state.call(
                constructor,
                arguments: [
                    .number(Double(pixel.red)),
                    .number(Double(pixel.green)),
                    .number(Double(pixel.blue)),
                    .number(Double(pixel.alpha))
                ]
            ).first ?? .nilValue
        default:
            throw LuaError.runtime("Color constructor is unavailable")
        }
    }

    private static func materialSource(
        _ texture: GMLuaTextureDescriptor,
        functionName: String
    ) throws -> (path: LuaString, encodedParameters: LuaString?) {
        switch texture.kind {
        case let .materialBaseTexture(path, encodedParameters):
            return (path, encodedParameters)
        case .screenEffect:
            throw LuaError.runtime(
                "\(functionName) requires decoded image backing; screen-effect textures are logical"
            )
        case .engineRenderTarget, .renderTarget:
            throw LuaError.runtime(
                "\(functionName) requires decoded image backing; render targets are logical"
            )
        }
    }

    private static func asciiCaseInsensitiveEqual(
        _ value: LuaString,
        _ expected: String
    ) -> Bool {
        let expectedBytes = Array(expected.utf8)
        guard value.bytes.count == expectedBytes.count else { return false }
        return zip(value.bytes, expectedBytes).allSatisfy { lhs, rhs in
            let foldedLHS = (65...90).contains(lhs) ? lhs + 32 : lhs
            let foldedRHS = (65...90).contains(rhs) ? rhs + 32 : rhs
            return foldedLHS == foldedRHS
        }
    }
}
