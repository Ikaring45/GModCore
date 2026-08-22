import Foundation

/// Strict ingestion failures for Source's GAME-path surface database.
///
/// The engine's raw parser permits some override behavior, but this
/// attestation boundary deliberately rejects ambiguous duplicate input. It
/// also does not derive material-pair friction or restitution coefficients;
/// Source SDK 2013 does not publish that combination rule.
public enum SourceSurfacePropertiesError: Error, Equatable, Sendable {
    case invalidUTF8(path: String)
    case invalidManifestRoot
    case unexpectedManifestEntry(String)
    case manifestEntryMustBeString(index: Int)
    case conditionalNotSupported(path: String, key: String)
    case emptyManifest
    case duplicateManifestFile(path: String)
    case duplicateManifestFileName(name: String)
    case manifestReferencesItself(path: String)
    case emptySurfaceFile(path: String)
    case unsupportedFileDirective(path: String, directive: String)
    case surfaceMustBeObject(path: String, name: String)
    case invalidMaterialName(path: String, name: String)
    case duplicateMaterial(
        name: String,
        firstPath: String,
        secondPath: String
    )
    case nestedMaterialProperty(material: String, property: String)
    case duplicateMaterialProperty(material: String, property: String)
    case baseMustBeFirst(material: String)
    case invalidBaseName(material: String, name: String)
    case missingDefaultMaterial
    case defaultMaterialMustBeFirst
    case defaultMaterialCannotHaveBase
    case missingBase(material: String, base: String)
    case baseCycle([String])
    case baseDeclaredAfterMaterial(material: String, base: String)
    case invalidPhysicsNumber(
        material: String,
        property: String,
        value: String
    )
    case invalidPhysicsValue(
        material: String,
        property: String,
        value: Float
    )
    case missingPhysicsProperty(material: String, property: String)
}

/// The five values published by Source SDK's `surfacephysicsparams_t`.
///
/// `thickness == nil` is meaningful: the authored material did not select the
/// thin-sheet mass path. It is not replaced with an invented zero.
public struct SourceSurfacePhysicsProperties: Equatable, Sendable {
    public let density: Float
    public let friction: Float
    public let elasticity: Float
    public let dampening: Float
    public let thickness: Float?

    public init(
        density: Float,
        friction: Float,
        elasticity: Float,
        dampening: Float,
        thickness: Float?
    ) {
        self.density = density
        self.friction = friction
        self.elasticity = elasticity
        self.dampening = dampening
        self.thickness = thickness
    }
}

/// Physics values authored directly in one material block before inheritance.
public struct SourceSurfaceExplicitPhysicsProperties: Equatable, Sendable {
    public let density: Float?
    public let friction: Float?
    public let elasticity: Float?
    public let dampening: Float?
    public let thickness: Float?

    public init(
        density: Float?,
        friction: Float?,
        elasticity: Float?,
        dampening: Float?,
        thickness: Float?
    ) {
        self.density = density
        self.friction = friction
        self.elasticity = elasticity
        self.dampening = dampening
        self.thickness = thickness
    }
}

/// One exact scalar from the material block. Unknown sound/audio/game fields
/// remain ordered and visible without being reinterpreted as physics values.
public struct SourceSurfaceScalarProperty: Equatable, Sendable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public struct SourceSurfaceMaterialAttestation: Equatable, Sendable {
    public let name: String
    public let sourcePath: String
    /// Exact order across manifest files. This is provenance, not a claimed
    /// VPhysics runtime material index.
    public let declarationOrdinal: Int
    public let baseName: String?
    public let explicitProperties: [SourceSurfaceScalarProperty]
    public let explicitPhysics: SourceSurfaceExplicitPhysicsProperties
    public let resolvedPhysics: SourceSurfacePhysicsProperties
}

public struct SourceSurfacePropertiesFileAttestation: Equatable, Sendable {
    public let logicalPath: String
    public let byteCount: Int
    public let materialNames: [String]
}

/// Immutable result published only after the complete manifest and inheritance
/// graph have passed validation.
public struct SourceSurfacePropertiesAttestation: Equatable, Sendable {
    public let manifestPath: String
    public let manifestByteCount: Int
    public let files: [SourceSurfacePropertiesFileAttestation]
    public let materials: [SourceSurfaceMaterialAttestation]

    private let materialIndicesByFoldedName: [String: Int]

    fileprivate init(
        manifestPath: String,
        manifestByteCount: Int,
        files: [SourceSurfacePropertiesFileAttestation],
        materials: [SourceSurfaceMaterialAttestation]
    ) {
        self.manifestPath = manifestPath
        self.manifestByteCount = manifestByteCount
        self.files = files
        self.materials = materials
        materialIndicesByFoldedName = Dictionary(uniqueKeysWithValues:
            materials.enumerated().map {
                (Self.fold($0.element.name), $0.offset)
            }
        )
    }

    public func material(named name: String)
        -> SourceSurfaceMaterialAttestation?
    {
        guard let index = materialIndicesByFoldedName[Self.fold(name)] else {
            return nil
        }
        return materials[index]
    }

    private static func fold(_ value: String) -> String {
        value.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}

/// Loads Source's fixed manifest route through the canonical GAME VFS.
public enum SourceSurfacePropertiesLoader {
    public static let defaultManifestPath =
        "scripts/surfaceproperties_manifest.txt"

    private struct ParsedMaterial {
        let name: String
        let foldedName: String
        let sourcePath: String
        let declarationOrdinal: Int
        let baseName: String?
        let foldedBaseName: String?
        let explicitProperties: [SourceSurfaceScalarProperty]
        let explicitPhysics: SourceSurfaceExplicitPhysicsProperties
    }

    private struct PhysicsBuilder {
        var density: Float?
        var friction: Float?
        var elasticity: Float?
        var dampening: Float?
        var thickness: Float?

        var value: SourceSurfaceExplicitPhysicsProperties {
            SourceSurfaceExplicitPhysicsProperties(
                density: density,
                friction: friction,
                elasticity: elasticity,
                dampening: dampening,
                thickness: thickness
            )
        }
    }

    public static func load(
        from fileSystem: SourceSearchPathFileSystem,
        manifestPath rawManifestPath: String = defaultManifestPath
    ) throws -> SourceSurfacePropertiesAttestation {
        let manifestPath = try SourceLogicalPath.normalize(
            rawManifestPath,
            allowEmpty: false
        )
        let manifestData = try fileSystem.readFile(
            manifestPath,
            pathID: "GAME"
        )
        let manifestSource = try decodeUTF8(
            manifestData,
            path: manifestPath
        )
        let filePaths = try parseManifest(
            source: manifestSource,
            manifestPath: manifestPath
        )

        var parsedMaterials: [ParsedMaterial] = []
        var firstDeclarationByName: [String: ParsedMaterial] = [:]
        var fileAttestations: [SourceSurfacePropertiesFileAttestation] = []
        fileAttestations.reserveCapacity(filePaths.count)

        for filePath in filePaths {
            let data = try fileSystem.readFile(filePath, pathID: "GAME")
            let source = try decodeUTF8(data, path: filePath)
            let fileMaterials = try parseSurfaceFile(
                source: source,
                path: filePath,
                startingOrdinal: parsedMaterials.count
            )
            for material in fileMaterials {
                if let first = firstDeclarationByName[material.foldedName] {
                    throw SourceSurfacePropertiesError.duplicateMaterial(
                        name: material.name,
                        firstPath: first.sourcePath,
                        secondPath: material.sourcePath
                    )
                }
                firstDeclarationByName[material.foldedName] = material
                parsedMaterials.append(material)
            }
            fileAttestations.append(SourceSurfacePropertiesFileAttestation(
                logicalPath: filePath,
                byteCount: data.count,
                materialNames: fileMaterials.map(\.name)
            ))
        }

        let resolved = try resolveMaterials(parsedMaterials)
        return SourceSurfacePropertiesAttestation(
            manifestPath: manifestPath,
            manifestByteCount: manifestData.count,
            files: fileAttestations,
            materials: resolved
        )
    }

    private static func parseManifest(
        source: String,
        manifestPath: String
    ) throws -> [String] {
        var parser = SourceKeyValuesParser(
            source: source,
            options: .init(
                usesEscapeSequences: false,
                preserveKeyCase: true,
                preserveConditionals: true
            )
        )
        let roots = try parser.parse()
        guard roots.count == 1,
              roots[0].key.caseInsensitiveCompare(
                  "surfaceproperties_manifest"
              ) == .orderedSame,
              roots[0].conditional == nil,
              case let .object(entries) = roots[0].value else {
            throw SourceSurfacePropertiesError.invalidManifestRoot
        }

        var paths: [String] = []
        var seenPaths: Set<String> = []
        var seenFileNames: Set<String> = []
        let foldedManifestPath = fold(manifestPath)
        for (index, entry) in entries.enumerated() {
            guard entry.conditional == nil else {
                throw SourceSurfacePropertiesError.conditionalNotSupported(
                    path: manifestPath,
                    key: entry.key
                )
            }
            guard entry.key.caseInsensitiveCompare("file") == .orderedSame else {
                throw SourceSurfacePropertiesError.unexpectedManifestEntry(
                    entry.key
                )
            }
            guard case let .string(rawPath) = entry.value else {
                throw SourceSurfacePropertiesError.manifestEntryMustBeString(
                    index: index
                )
            }
            let path = try SourceLogicalPath.normalize(
                rawPath,
                allowEmpty: false
            )
            let foldedPath = fold(path)
            guard foldedPath != foldedManifestPath else {
                throw SourceSurfacePropertiesError.manifestReferencesItself(
                    path: path
                )
            }
            guard seenPaths.insert(foldedPath).inserted else {
                throw SourceSurfacePropertiesError.duplicateManifestFile(
                    path: path
                )
            }
            let fileName = String(path.split(separator: "/").last!)
            let foldedFileName = fold(fileName)
            guard seenFileNames.insert(foldedFileName).inserted else {
                throw SourceSurfacePropertiesError.duplicateManifestFileName(
                    name: fileName
                )
            }
            paths.append(path)
        }
        guard !paths.isEmpty else {
            throw SourceSurfacePropertiesError.emptyManifest
        }
        return paths
    }

    private static func parseSurfaceFile(
        source: String,
        path: String,
        startingOrdinal: Int
    ) throws -> [ParsedMaterial] {
        var parser = SourceKeyValuesParser(
            source: source,
            options: .init(
                usesEscapeSequences: false,
                preserveKeyCase: true,
                preserveConditionals: true
            )
        )
        let entries = try parser.parse()
        guard !entries.isEmpty else {
            throw SourceSurfacePropertiesError.emptySurfaceFile(path: path)
        }

        var materials: [ParsedMaterial] = []
        materials.reserveCapacity(entries.count)
        var seenNames: Set<String> = []
        for entry in entries {
            if entry.key.caseInsensitiveCompare("#include") == .orderedSame ||
                entry.key.caseInsensitiveCompare("#base") == .orderedSame {
                throw SourceSurfacePropertiesError.unsupportedFileDirective(
                    path: path,
                    directive: entry.key
                )
            }
            guard entry.conditional == nil else {
                throw SourceSurfacePropertiesError.conditionalNotSupported(
                    path: path,
                    key: entry.key
                )
            }
            guard case let .object(properties) = entry.value else {
                throw SourceSurfacePropertiesError.surfaceMustBeObject(
                    path: path,
                    name: entry.key
                )
            }
            let name = entry.key
            let trimmedName = name.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !name.isEmpty, name == trimmedName else {
                throw SourceSurfacePropertiesError.invalidMaterialName(
                    path: path,
                    name: name
                )
            }
            let foldedName = fold(name)
            guard seenNames.insert(foldedName).inserted else {
                throw SourceSurfacePropertiesError.duplicateMaterial(
                    name: name,
                    firstPath: path,
                    secondPath: path
                )
            }

            var scalarProperties: [SourceSurfaceScalarProperty] = []
            scalarProperties.reserveCapacity(properties.count)
            var seenProperties: Set<String> = []
            var baseName: String?
            var physics = PhysicsBuilder()
            for (propertyIndex, property) in properties.enumerated() {
                guard property.conditional == nil else {
                    throw SourceSurfacePropertiesError
                        .conditionalNotSupported(
                            path: path,
                            key: "\(name).\(property.key)"
                        )
                }
                guard case let .string(value) = property.value else {
                    throw SourceSurfacePropertiesError.nestedMaterialProperty(
                        material: name,
                        property: property.key
                    )
                }
                let foldedProperty = fold(property.key)
                guard seenProperties.insert(foldedProperty).inserted else {
                    throw SourceSurfacePropertiesError
                        .duplicateMaterialProperty(
                            material: name,
                            property: property.key
                        )
                }
                scalarProperties.append(SourceSurfaceScalarProperty(
                    key: property.key,
                    value: value
                ))

                if foldedProperty == "base" {
                    guard propertyIndex == 0 else {
                        throw SourceSurfacePropertiesError.baseMustBeFirst(
                            material: name
                        )
                    }
                    let trimmedBase = value.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    guard !trimmedBase.isEmpty, value == trimmedBase else {
                        throw SourceSurfacePropertiesError.invalidBaseName(
                            material: name,
                            name: value
                        )
                    }
                    baseName = value
                    continue
                }
                try parsePhysicsProperty(
                    foldedProperty,
                    rawValue: value,
                    material: name,
                    into: &physics
                )
            }

            materials.append(ParsedMaterial(
                name: name,
                foldedName: foldedName,
                sourcePath: path,
                declarationOrdinal: startingOrdinal + materials.count,
                baseName: baseName,
                foldedBaseName: baseName.map(fold),
                explicitProperties: scalarProperties,
                explicitPhysics: physics.value
            ))
        }
        return materials
    }

    private static func parsePhysicsProperty(
        _ property: String,
        rawValue: String,
        material: String,
        into physics: inout PhysicsBuilder
    ) throws {
        guard [
            "density", "friction", "elasticity", "dampening", "thickness"
        ].contains(property) else { return }
        let trimmed = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty,
              let value = Float(trimmed),
              value.isFinite else {
            throw SourceSurfacePropertiesError.invalidPhysicsNumber(
                material: material,
                property: property,
                value: rawValue
            )
        }
        let isValid = property == "density" || property == "thickness"
            ? value > 0
            : value >= 0
        guard isValid else {
            throw SourceSurfacePropertiesError.invalidPhysicsValue(
                material: material,
                property: property,
                value: value
            )
        }
        switch property {
        case "density": physics.density = value
        case "friction": physics.friction = value
        case "elasticity": physics.elasticity = value
        case "dampening": physics.dampening = value
        case "thickness": physics.thickness = value
        default: break
        }
    }

    private static func resolveMaterials(
        _ parsed: [ParsedMaterial]
    ) throws -> [SourceSurfaceMaterialAttestation] {
        let indices = Dictionary(uniqueKeysWithValues: parsed.enumerated().map {
            ($0.element.foldedName, $0.offset)
        })
        guard let defaultIndex = indices["default"] else {
            throw SourceSurfacePropertiesError.missingDefaultMaterial
        }
        guard defaultIndex == 0 else {
            throw SourceSurfacePropertiesError.defaultMaterialMustBeFirst
        }
        guard parsed[defaultIndex].baseName == nil else {
            throw SourceSurfacePropertiesError.defaultMaterialCannotHaveBase
        }

        var baseIndices: [Int?] = Array(repeating: nil, count: parsed.count)
        for (index, material) in parsed.enumerated() {
            guard let foldedBase = material.foldedBaseName,
                  let baseName = material.baseName else { continue }
            guard let baseIndex = indices[foldedBase] else {
                throw SourceSurfacePropertiesError.missingBase(
                    material: material.name,
                    base: baseName
                )
            }
            baseIndices[index] = baseIndex
        }

        var visitState = Array(repeating: UInt8(0), count: parsed.count)
        var stack: [Int] = []
        func visit(_ index: Int) throws {
            if visitState[index] == 2 { return }
            if visitState[index] == 1 {
                let start = stack.firstIndex(of: index) ?? 0
                let cycle = stack[start...].map { parsed[$0].name } +
                    [parsed[index].name]
                throw SourceSurfacePropertiesError.baseCycle(cycle)
            }
            visitState[index] = 1
            stack.append(index)
            if let baseIndex = baseIndices[index] {
                try visit(baseIndex)
            }
            _ = stack.popLast()
            visitState[index] = 2
        }
        for index in parsed.indices { try visit(index) }

        for (index, baseIndex) in baseIndices.enumerated() {
            guard let baseIndex, baseIndex > index else { continue }
            throw SourceSurfacePropertiesError.baseDeclaredAfterMaterial(
                material: parsed[index].name,
                base: parsed[baseIndex].name
            )
        }

        var resolved = Array<SourceSurfacePhysicsProperties?>(
            repeating: nil,
            count: parsed.count
        )
        func resolve(_ index: Int) throws -> SourceSurfacePhysicsProperties {
            if let value = resolved[index] { return value }
            let material = parsed[index]
            let inherited: SourceSurfacePhysicsProperties?
            if index == defaultIndex {
                inherited = nil
            } else if let baseIndex = baseIndices[index] {
                inherited = try resolve(baseIndex)
            } else {
                inherited = try resolve(defaultIndex)
            }
            let explicit = material.explicitPhysics
            let density = try required(
                explicit.density ?? inherited?.density,
                material: material.name,
                property: "density"
            )
            let friction = try required(
                explicit.friction ?? inherited?.friction,
                material: material.name,
                property: "friction"
            )
            let elasticity = try required(
                explicit.elasticity ?? inherited?.elasticity,
                material: material.name,
                property: "elasticity"
            )
            let dampening = try required(
                explicit.dampening ?? inherited?.dampening,
                material: material.name,
                property: "dampening"
            )
            let value = SourceSurfacePhysicsProperties(
                density: density,
                friction: friction,
                elasticity: elasticity,
                dampening: dampening,
                thickness: explicit.thickness ?? inherited?.thickness
            )
            resolved[index] = value
            return value
        }

        return try parsed.indices.map { index in
            let material = parsed[index]
            return SourceSurfaceMaterialAttestation(
                name: material.name,
                sourcePath: material.sourcePath,
                declarationOrdinal: material.declarationOrdinal,
                baseName: material.baseName,
                explicitProperties: material.explicitProperties,
                explicitPhysics: material.explicitPhysics,
                resolvedPhysics: try resolve(index)
            )
        }
    }

    private static func required(
        _ value: Float?,
        material: String,
        property: String
    ) throws -> Float {
        guard let value else {
            throw SourceSurfacePropertiesError.missingPhysicsProperty(
                material: material,
                property: property
            )
        }
        return value
    }

    private static func decodeUTF8(_ data: Data, path: String) throws -> String {
        guard let source = String(data: data, encoding: .utf8) else {
            throw SourceSurfacePropertiesError.invalidUTF8(path: path)
        }
        return source
    }

    private static func fold(_ value: String) -> String {
        value.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}
