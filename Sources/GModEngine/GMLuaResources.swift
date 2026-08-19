import Foundation
import GModLua

/// Whether a logical Source resource has been connected to decoded asset data.
/// This milestone only creates identity-preserving descriptors, so every newly
/// registered resource remains unresolved.
public enum GMLuaResourceResolution: String, Sendable, Equatable {
    case unresolved
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
    private var requestedSounds: Set<LuaString> = []
    private var requestedModels: Set<LuaString> = []
    private var requestedParticleSystems: Set<LuaString> = []

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
        return textureValues.count
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

    fileprivate var references: [LuaValue] {
        lock.lock()
        defer { lock.unlock() }
        return Array(materialValues.values) + Array(textureValues.values)
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
            state.setGlobal("render", value: .table(renderTable))

            // Exact values from the public STUDIO enum used at halo.lua load.
            state.setGlobal("STUDIO_RENDER", value: .number(1))
            state.setGlobal("STUDIO_SKIP_DECALS", value: .number(268_435_456))
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
}
