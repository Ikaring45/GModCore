import Foundation
import Testing
@testable import GModEngine

@Suite("Source surfaceproperties GAME-VFS attestation")
struct SourceSurfacePropertiesTests {
    @Test("manifest order, default inheritance, bases, and shipped extremes survive")
    func loadsOrderedAttestedPhysics() throws {
        let manifest = #"""
        surfaceproperties_manifest
        {
            "file" "scripts/surfaceproperties.txt"
            "file" "scripts/surfaceproperties_hl2.txt"
        }
        """#
        let base = #"""
        "default"
        {
            "density" "2000"
            "elasticity" "0.25"
            "friction" "0.8"
            "dampening" "0.0"
            "impacthard" "Default.ImpactHard"
        }
        "Metal_Box"
        {
            "base" "default"
            "thickness" "0.1"
            "friction" "1.337"
        }
        "unbased"
        {
            "elasticity" "2.0"
        }
        """#
        let hl2 = #"""
        "metalvehicle"
        {
            "base" "metal_box"
            "elasticity" "1000"
            "dampening" "200.0"
        }
        """#
        let fileSystem = try makeFileSystem(utf8Files: [
            "scripts/surfaceproperties_manifest.txt": manifest,
            "scripts/surfaceproperties.txt": base,
            "scripts/surfaceproperties_hl2.txt": hl2,
        ])

        let result = try SourceSurfacePropertiesLoader.load(from: fileSystem)

        #expect(result.files.map(\.logicalPath) == [
            "scripts/surfaceproperties.txt",
            "scripts/surfaceproperties_hl2.txt",
        ])
        #expect(result.files.map(\.materialNames) == [
            ["default", "Metal_Box", "unbased"],
            ["metalvehicle"],
        ])
        #expect(result.materials.map(\.declarationOrdinal) == [0, 1, 2, 3])
        #expect(result.materials.map(\.name) == [
            "default", "Metal_Box", "unbased", "metalvehicle"
        ])

        let metalVehicle = try #require(result.material(named: "METALVEHICLE"))
        #expect(metalVehicle.sourcePath == "scripts/surfaceproperties_hl2.txt")
        #expect(metalVehicle.baseName == "metal_box")
        #expect(metalVehicle.explicitPhysics.density == nil)
        #expect(metalVehicle.explicitPhysics.elasticity == 1_000)
        #expect(metalVehicle.explicitPhysics.dampening == 200)
        #expect(metalVehicle.resolvedPhysics == SourceSurfacePhysicsProperties(
            density: 2_000,
            friction: 1.337,
            elasticity: 1_000,
            dampening: 200,
            thickness: 0.1
        ))
        let unbased = try #require(result.material(named: "UnBaSeD"))
        #expect(unbased.resolvedPhysics.density == 2_000)
        #expect(unbased.resolvedPhysics.friction == 0.8)
        #expect(unbased.resolvedPhysics.elasticity == 2)
        #expect(unbased.resolvedPhysics.thickness == nil)
        let defaultMaterial = try #require(result.material(named: "default"))
        #expect(defaultMaterial.explicitProperties.last ==
            SourceSurfaceScalarProperty(
                key: "impacthard",
                value: "Default.ImpactHard"
            ))
    }

    @Test("loader uses GAME priority and Source case-insensitive logical paths")
    func usesCanonicalGameVFS() throws {
        let lower = try SourceMemoryFileProvider(utf8Files: [
            "scripts/surfaceproperties_manifest.txt": manifest(
                files: ["scripts/lower.txt"]
            ),
            "scripts/lower.txt": defaultFile(density: "1000"),
        ])
        let upper = try SourceMemoryFileProvider(utf8Files: [
            "SCRIPTS/SURFACEPROPERTIES_MANIFEST.TXT": manifest(
                files: [#"SCRIPTS\UPPER.TXT"#]
            ),
            "scripts/upper.txt": defaultFile(density: "2700"),
        ])
        let ignored = try SourceMemoryFileProvider(utf8Files: [
            "scripts/surfaceproperties_manifest.txt": manifest(
                files: ["scripts/mod-only.txt"]
            ),
            "scripts/mod-only.txt": defaultFile(density: "9000"),
        ])
        let fileSystem = SourceSearchPathFileSystem()
        _ = try fileSystem.addSearchPath(
            provider: lower,
            name: "lower-game",
            pathIDs: ["GAME"],
            add: .tail
        )
        _ = try fileSystem.addSearchPath(
            provider: upper,
            name: "upper-game",
            pathIDs: ["GAME"],
            add: .head
        )
        _ = try fileSystem.addSearchPath(
            provider: ignored,
            name: "mod-only",
            pathIDs: ["MOD"],
            add: .head
        )

        let result = try SourceSurfacePropertiesLoader.load(
            from: fileSystem,
            manifestPath: "Scripts\\SurfaceProperties_Manifest.txt"
        )
        #expect(result.manifestPath ==
            "Scripts/SurfaceProperties_Manifest.txt")
        #expect(result.files.map(\.logicalPath) == ["SCRIPTS/UPPER.TXT"])
        #expect(result.material(named: "default")?.resolvedPhysics.density ==
            2_700)
    }

    @Test("manifest aliases, duplicate names, self-reference, and bad shape fail")
    func rejectsInvalidManifest() throws {
        let duplicateAlias = try makeFileSystem(utf8Files: [
            "scripts/surfaceproperties_manifest.txt": manifest(files: [
                "scripts/a.txt", #"SCRIPTS\folder\..\A.TXT"#
            ])
        ])
        #expect(throws: SourceSurfacePropertiesError.duplicateManifestFile(
            path: "SCRIPTS/A.TXT"
        )) {
            _ = try SourceSurfacePropertiesLoader.load(from: duplicateAlias)
        }

        let duplicateName = try makeFileSystem(utf8Files: [
            "scripts/surfaceproperties_manifest.txt": manifest(files: [
                "scripts/a.txt", "custom/A.TXT"
            ])
        ])
        #expect(throws: SourceSurfacePropertiesError
            .duplicateManifestFileName(name: "A.TXT")) {
            _ = try SourceSurfacePropertiesLoader.load(from: duplicateName)
        }

        let selfReference = try makeFileSystem(utf8Files: [
            "scripts/surfaceproperties_manifest.txt": manifest(files: [
                "SCRIPTS/surfaceproperties_manifest.txt"
            ])
        ])
        #expect(throws: SourceSurfacePropertiesError.manifestReferencesItself(
            path: "SCRIPTS/surfaceproperties_manifest.txt"
        )) {
            _ = try SourceSurfacePropertiesLoader.load(from: selfReference)
        }

        let bogusEntry = try makeFileSystem(utf8Files: [
            "scripts/surfaceproperties_manifest.txt": #"""
            surfaceproperties_manifest { "include" "scripts/a.txt" }
            """#
        ])
        #expect(throws: SourceSurfacePropertiesError
            .unexpectedManifestEntry("include")) {
            _ = try SourceSurfacePropertiesLoader.load(from: bogusEntry)
        }

        let empty = try makeFileSystem(utf8Files: [
            "scripts/surfaceproperties_manifest.txt":
                "surfaceproperties_manifest {}"
        ])
        #expect(throws: SourceSurfacePropertiesError.emptyManifest) {
            _ = try SourceSurfacePropertiesLoader.load(from: empty)
        }
    }

    @Test("missing files and invalid UTF-8 never publish a partial database")
    func missingAndMalformedFilesFailClosed() throws {
        let missing = try makeFileSystem(utf8Files: [
            "scripts/surfaceproperties_manifest.txt": manifest(files: [
                "scripts/good.txt", "scripts/missing.txt"
            ]),
            "scripts/good.txt": defaultFile(),
        ])
        #expect(throws: SourceFileSystemError.fileNotFound(
            "scripts/missing.txt"
        )) {
            _ = try SourceSurfacePropertiesLoader.load(from: missing)
        }

        let invalidUTF8 = try makeFileSystem(files: [
            "scripts/surfaceproperties_manifest.txt": Data([0xFF])
        ])
        #expect(throws: SourceSurfacePropertiesError.invalidUTF8(
            path: "scripts/surfaceproperties_manifest.txt"
        )) {
            _ = try SourceSurfacePropertiesLoader.load(from: invalidUTF8)
        }
    }

    @Test("duplicates, nested values, directives, and misplaced bases fail")
    func rejectsAmbiguousMaterialStructure() throws {
        let duplicateMaterial = try makeFileSystem(utf8Files: [
            "scripts/surfaceproperties_manifest.txt": manifest(files: [
                "scripts/a.txt", "scripts/b.txt"
            ]),
            "scripts/a.txt": defaultFile() + #"""
            "metal" { "base" "default" }
            """#,
            "scripts/b.txt": #"""
            "METAL" { "base" "default" }
            """#,
        ])
        #expect(throws: SourceSurfacePropertiesError.duplicateMaterial(
            name: "METAL",
            firstPath: "scripts/a.txt",
            secondPath: "scripts/b.txt"
        )) {
            _ = try SourceSurfacePropertiesLoader.load(from: duplicateMaterial)
        }

        let duplicateProperty = try loaderForSingleSurfaceFile(#"""
        "default"
        {
            "density" "2000"
            "Density" "1000"
            "elasticity" "0.25"
            "friction" "0.8"
            "dampening" "0"
        }
        """#)
        #expect(throws: SourceSurfacePropertiesError
            .duplicateMaterialProperty(
                material: "default",
                property: "Density"
            )) {
            _ = try SourceSurfacePropertiesLoader.load(from: duplicateProperty)
        }

        let nested = try loaderForSingleSurfaceFile(defaultFile() + #"""
        "metal" { "sound" { "name" "Metal.Impact" } }
        """#)
        #expect(throws: SourceSurfacePropertiesError.nestedMaterialProperty(
            material: "metal",
            property: "sound"
        )) {
            _ = try SourceSurfacePropertiesLoader.load(from: nested)
        }

        let directive = try loaderForSingleSurfaceFile(
            #"#include "scripts/other.txt""#
        )
        #expect(throws: SourceSurfacePropertiesError.unsupportedFileDirective(
            path: "scripts/one.txt",
            directive: "#include"
        )) {
            _ = try SourceSurfacePropertiesLoader.load(from: directive)
        }

        let lateBase = try loaderForSingleSurfaceFile(defaultFile() + #"""
        "metal" { "friction" "0.4" "base" "default" }
        """#)
        #expect(throws: SourceSurfacePropertiesError.baseMustBeFirst(
            material: "metal"
        )) {
            _ = try SourceSurfacePropertiesLoader.load(from: lateBase)
        }
    }

    @Test("missing, cyclic, and unattested forward bases fail closed")
    func rejectsInvalidInheritanceGraph() throws {
        let missingBase = try loaderForSingleSurfaceFile(defaultFile() + #"""
        "metal" { "base" "unknown" }
        """#)
        #expect(throws: SourceSurfacePropertiesError.missingBase(
            material: "metal",
            base: "unknown"
        )) {
            _ = try SourceSurfacePropertiesLoader.load(from: missingBase)
        }

        let cycle = try loaderForSingleSurfaceFile(defaultFile() + #"""
        "a" { "base" "b" }
        "b" { "base" "a" }
        """#)
        #expect(throws: SourceSurfacePropertiesError.baseCycle(["a", "b", "a"])) {
            _ = try SourceSurfacePropertiesLoader.load(from: cycle)
        }

        let forward = try loaderForSingleSurfaceFile(defaultFile() + #"""
        "a" { "base" "b" }
        "b" { "base" "default" }
        """#)
        #expect(throws: SourceSurfacePropertiesError
            .baseDeclaredAfterMaterial(material: "a", base: "b")) {
            _ = try SourceSurfacePropertiesLoader.load(from: forward)
        }

        let noDefault = try loaderForSingleSurfaceFile(#"""
        "metal"
        {
            "density" "2700"
            "elasticity" "0.2"
            "friction" "0.8"
            "dampening" "0"
        }
        """#)
        #expect(throws: SourceSurfacePropertiesError.missingDefaultMaterial) {
            _ = try SourceSurfacePropertiesLoader.load(from: noDefault)
        }
    }

    @Test("missing, malformed, non-finite, and negative physics values fail")
    func rejectsInvalidPhysicsValues() throws {
        let missing = try loaderForSingleSurfaceFile(#"""
        "default"
        {
            "density" "2000"
            "elasticity" "0.25"
            "friction" "0.8"
        }
        """#)
        #expect(throws: SourceSurfacePropertiesError.missingPhysicsProperty(
            material: "default",
            property: "dampening"
        )) {
            _ = try SourceSurfacePropertiesLoader.load(from: missing)
        }

        for invalid in ["NaN", "+inf", "not-a-number"] {
            let loader = try loaderForSingleSurfaceFile(defaultFile(
                friction: invalid
            ))
            #expect(throws: SourceSurfacePropertiesError.invalidPhysicsNumber(
                material: "default",
                property: "friction",
                value: invalid
            )) {
                _ = try SourceSurfacePropertiesLoader.load(from: loader)
            }
        }

        let negative = try loaderForSingleSurfaceFile(defaultFile(
            friction: "-0.1"
        ))
        #expect(throws: SourceSurfacePropertiesError.invalidPhysicsValue(
            material: "default",
            property: "friction",
            value: -0.1
        )) {
            _ = try SourceSurfacePropertiesLoader.load(from: negative)
        }

        let zeroDensity = try loaderForSingleSurfaceFile(defaultFile(
            density: "0"
        ))
        #expect(throws: SourceSurfacePropertiesError.invalidPhysicsValue(
            material: "default",
            property: "density",
            value: 0
        )) {
            _ = try SourceSurfacePropertiesLoader.load(from: zeroDensity)
        }
    }

    private func manifest(files: [String]) -> String {
        let entries = files.map { "\"file\" \"\($0)\"" }
            .joined(separator: "\n")
        return "surfaceproperties_manifest\n{\n\(entries)\n}"
    }

    private func defaultFile(
        density: String = "2000",
        friction: String = "0.8"
    ) -> String {
        #"""
        "default"
        {
            "density" "\#(density)"
            "elasticity" "0.25"
            "friction" "\#(friction)"
            "dampening" "0.0"
        }
        """#
    }

    private func loaderForSingleSurfaceFile(_ source: String) throws
        -> SourceSearchPathFileSystem
    {
        try makeFileSystem(utf8Files: [
            "scripts/surfaceproperties_manifest.txt": manifest(
                files: ["scripts/one.txt"]
            ),
            "scripts/one.txt": source,
        ])
    }

    private func makeFileSystem(utf8Files: [String: String]) throws
        -> SourceSearchPathFileSystem
    {
        try makeFileSystem(files: utf8Files.mapValues { Data($0.utf8) })
    }

    private func makeFileSystem(files: [String: Data]) throws
        -> SourceSearchPathFileSystem
    {
        let provider = try SourceMemoryFileProvider(files: files)
        let fileSystem = SourceSearchPathFileSystem()
        _ = try fileSystem.addSearchPath(
            provider: provider,
            name: "surface-fixture",
            pathIDs: ["GAME"]
        )
        return fileSystem
    }
}
