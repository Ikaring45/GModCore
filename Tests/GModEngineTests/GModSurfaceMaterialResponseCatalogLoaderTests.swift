import Foundation
import XCTest
@testable import GModEngine
@testable import GModGameSession
import GModGameAssets

final class GModSurfaceMaterialResponseCatalogLoaderTests: XCTestCase {
    func testBuildsRuntimeCatalogFromOracleIndicesNotDeclarationOrdinals()
        throws
    {
        let fixture = try makeFixture()
        let catalog = try GModSurfaceMaterialResponseCatalogLoader.load(
            independentAttestationData: try makeAttestation(
                files: fixture.files,
                lookups: [
                    lookup(name: "plastic", index: 9, density: "1000"),
                    lookup(name: "rubber", index: 2, density: "1200"),
                ]
            ),
            mountedSurfaceProperties: fixture.attestation,
            fileSystem: fixture.fileSystem
        )

        XCTAssertEqual(
            fixture.attestation.material(named: "plastic")?
                .declarationOrdinal,
            1
        )
        XCTAssertEqual(catalog.nameTable.materialIndex(named: "PLASTIC"), 9)
        XCTAssertEqual(catalog.nameTable.name(for: 2), "rubber")
        XCTAssertNil(catalog.nameTable.name(for: 1))
        XCTAssertEqual(
            catalog.entries.map(\.runtimeMaterialIndex),
            [2, 9],
            "catalog order is deterministic but does not manufacture indices"
        )
        XCTAssertEqual(catalog.entry(named: "rubber")?.surfacePhysics.density, 1_200)
    }

    func testRejectsMountedInputDigestAndParsedPhysicsDisagreement() throws {
        let fixture = try makeFixture()
        var wrongFiles = fixture.files
        wrongFiles["scripts/surfaceproperties.txt"] = Data("tampered".utf8)
        XCTAssertThrowsError(try GModSurfaceMaterialResponseCatalogLoader.load(
            independentAttestationData: try makeAttestation(
                files: wrongFiles,
                lookups: [lookup(name: "plastic", index: 9, density: "1000")]
            ),
            mountedSurfaceProperties: fixture.attestation,
            fileSystem: fixture.fileSystem
        )) { error in
            guard let error = error as?
                    GModSurfaceMaterialResponseCatalogError,
                  case .mountedSurfaceInputDigestMismatch(
                    path: "scripts/surfaceproperties.txt",
                    expected: _,
                    actual: _
                ) = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(try GModSurfaceMaterialResponseCatalogLoader.load(
            independentAttestationData: try makeAttestation(
                files: fixture.files,
                lookups: [lookup(name: "plastic", index: 9, density: "999")]
            ),
            mountedSurfaceProperties: fixture.attestation,
            fileSystem: fixture.fileSystem
        )) { error in
            XCTAssertEqual(
                error as? GModSurfaceMaterialResponseCatalogError,
                .surfacePhysicsMismatch(
                    material: "plastic",
                    field: "density",
                    mounted: 1_000,
                    attested: 999
                )
            )
        }
    }

    func testRejectsPartialResultsAndConflictingReverseMapping() throws {
        let fixture = try makeFixture()
        XCTAssertThrowsError(try GModSurfaceMaterialResponseCatalogLoader.load(
            independentAttestationData: try makeAttestation(
                files: fixture.files,
                lookups: [lookup(name: "plastic", index: 9, density: "1000")],
                status: "partial"
            ),
            mountedSurfaceProperties: fixture.attestation,
            fileSystem: fixture.fileSystem
        )) { error in
            XCTAssertEqual(
                error as? GModSurfaceMaterialResponseCatalogError,
                .incompleteAttestation(status: "partial")
            )
        }

        var conflict = lookup(name: "plastic", index: 9, density: "1000")
        conflict["reverse_name"] = "rubber"
        XCTAssertThrowsError(try GModSurfaceMaterialResponseCatalogLoader.load(
            independentAttestationData: try makeAttestation(
                files: fixture.files,
                lookups: [conflict]
            ),
            mountedSurfaceProperties: fixture.attestation,
            fileSystem: fixture.fileSystem
        )) { error in
            XCTAssertEqual(
                error as? GModSurfaceMaterialResponseCatalogError,
                .lookupNameMismatch(
                    requested: "plastic",
                    reverse: "rubber",
                    data: "plastic"
                )
            )
        }
    }
}

private extension GModSurfaceMaterialResponseCatalogLoaderTests {
    struct Fixture {
        let files: [String: Data]
        let fileSystem: SourceSearchPathFileSystem
        let attestation: SourceSurfacePropertiesAttestation
    }

    func makeFixture() throws -> Fixture {
        let files = [
            "scripts/surfaceproperties_manifest.txt": Data(#"""
            surfaceproperties_manifest
            {
                "file" "scripts/surfaceproperties.txt"
            }
            """#.utf8),
            "scripts/surfaceproperties.txt": Data(#"""
            "default"
            {
                "density" "2000"
                "friction" "0.5"
                "elasticity" "0.25"
                "dampening" "0"
            }
            "plastic"
            {
                "base" "default"
                "density" "1000"
            }
            "rubber"
            {
                "base" "default"
                "density" "1200"
            }
            """#.utf8),
        ]
        let provider = try SourceMemoryFileProvider(files: files)
        let fileSystem = SourceSearchPathFileSystem()
        _ = try fileSystem.addSearchPath(
            provider: provider,
            name: "owned-source",
            pathIDs: ["GAME"],
            add: .tail
        )
        return Fixture(
            files: files,
            fileSystem: fileSystem,
            attestation: try SourceSurfacePropertiesLoader.load(
                from: fileSystem
            )
        )
    }

    func lookup(name: String, index: Int, density: String)
        -> [String: Any]
    {
        [
            "requested_name": name,
            "surface_index": index,
            "reverse_name": name,
            "data": [
                "name": name,
                "friction_coefficient": "0.5",
                "elasticity": "0.25",
                "density": density,
                "thickness": "0",
                "dampening": "0",
                "material": 0,
            ],
        ]
    }

    func makeAttestation(
        files: [String: Data],
        lookups: [[String: Any]],
        status: String = "complete"
    ) throws -> Data {
        let inputs: [[String: Any]] = files.keys.sorted().map { path in
            [
                "path": "sourceengine/\(path)",
                "sha256": digest(files[path]!),
            ]
        }
        return try JSONSerialization.data(
            withJSONObject: [
                "schema": 1,
                "kind": GModSurfaceMaterialResponseCatalogLoader.format,
                "status": status,
                "provenance": [
                    "app_id": 4020,
                    "branch": "x86-64",
                    "build_id": "24721267",
                    "request_id": String(repeating: "a", count: 32),
                    "vphysics": [
                        "path": "bin/win64/vphysics.dll",
                        "sha256": String(repeating: "b", count: 64),
                    ],
                    "surface_inputs": inputs,
                ],
                "surface_lookups": lookups,
                "issues": status == "complete" ? [] : ["incomplete_fixture"],
            ],
            options: [.sortedKeys]
        )
    }

    func digest(_ data: Data) -> String {
        var hasher = GModContentSHA256()
        hasher.update(data)
        return hasher.hexadecimalDigest()
    }
}
