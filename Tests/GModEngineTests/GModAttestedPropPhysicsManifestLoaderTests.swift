import Foundation
import GModGameAssets
import Testing
@testable import GModEngine
@testable import GModGameSession

@Suite("Independent content-pack prop physics attestation manifest")
struct GModAttestedPropPhysicsManifestLoaderTests {
    @Test("exact MDL PHY SHA solid mass inertia axes and materials load")
    func exactAssetLoads() throws {
        let fixture = makeFixture(solidIndex: 0)
        let assets = try GModAttestedPropPhysicsManifestLoader.load(
            independentManifestData: fixture.manifest,
            content: fixture.content
        )
        let asset = try #require(assets.first)
        #expect(assets.count == 1)
        #expect(asset.normalizedModelPath == fixture.modelPath)
        #expect(asset.mdlSHA256 == digest(fixture.mdl))
        #expect(asset.phySHA256 == digest(fixture.phy))
        #expect(asset.studioChecksum == fixture.checksum)
        #expect(asset.bodyDefinition.solidIndex == 0)
        #expect(asset.bodyDefinition.massProperties.massKilograms == 12)
        #expect(asset.bodyDefinition.massProperties.principalInertia ==
            SourceVector3(8, 9, 10))
        #expect(asset.bodyDefinition.materialIndex == 7)
        #expect(asset.bodyDefinition.shape.topology == .convexParts)
        #expect(asset.collisionProperty.mins == SourceVector3(-1, -1, -1))
        #expect(asset.collisionProperty.maxs == SourceVector3(1, 1, 1))
    }

    @Test("a manifest cannot bless different MDL bytes")
    func digestMismatchFailsClosed() throws {
        let fixture = makeFixture(
            solidIndex: 0,
            overrideMDLDigest: String(repeating: "0", count: 64)
        )
        do {
            _ = try GModAttestedPropPhysicsManifestLoader.load(
                independentManifestData: fixture.manifest,
                content: fixture.content
            )
            Issue.record("expected exact MDL digest rejection")
        } catch let error as GModAttestedPropPhysicsManifestError {
            guard case let .digestMismatch(path, expected, actual) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(path == fixture.modelPath)
            #expect(expected == String(repeating: "0", count: 64))
            #expect(actual == digest(fixture.mdl))
        }
    }

    @Test("the selected solid must exist in the exact PHY envelope")
    func unavailableSolidFailsClosed() throws {
        let fixture = makeFixture(solidIndex: 1)
        do {
            _ = try GModAttestedPropPhysicsManifestLoader.load(
                independentManifestData: fixture.manifest,
                content: fixture.content
            )
            Issue.record("expected unavailable solid rejection")
        } catch let error as GModAttestedPropPhysicsManifestError {
            #expect(error == .solidIndexUnavailable(
                path: fixture.modelPath,
                index: 1,
                count: 1
            ))
        }
    }

    @Test("axis convention is mandatory and never defaulted")
    func missingAxisConventionFailsClosed() throws {
        let fixture = makeFixture(solidIndex: 0, includeAxisConvention: false)
        do {
            _ = try GModAttestedPropPhysicsManifestLoader.load(
                independentManifestData: fixture.manifest,
                content: fixture.content
            )
            Issue.record("expected missing axis convention rejection")
        } catch let error as GModAttestedPropPhysicsManifestError {
            guard case .malformedManifest = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
        }
    }

    private struct Fixture {
        let modelPath: String
        let checksum: Int32
        let mdl: Data
        let phy: Data
        let manifest: Data
        let content: FixtureContent
    }

    private struct FixtureContent: GModAttestedPropPhysicsContentReading {
        let files: [String: Data]

        func data(
            for logicalPath: String,
            maximumByteCount: UInt64
        ) throws -> Data? {
            guard let value = files[logicalPath],
                  UInt64(value.count) <= maximumByteCount else { return nil }
            return value
        }
    }

    private func makeFixture(
        solidIndex: Int,
        overrideMDLDigest: String? = nil,
        includeAxisConvention: Bool = true
    ) -> Fixture {
        let path = "models/props/attested_manifest_cube.mdl"
        let phyPath = "models/props/attested_manifest_cube.phy"
        let checksum: Int32 = 0x1357_2468
        let mdl = makeMDL(checksum: checksum)
        let phy = makePHY(checksum: checksum)
        let vertices: [[String: Any]] = [
            vector(-1, -1, -1), vector(1, -1, -1),
            vector(1, 1, -1), vector(-1, 1, -1),
            vector(-1, -1, 1), vector(1, -1, 1),
            vector(1, 1, 1), vector(-1, 1, 1),
        ]
        let indices = [
            (0, 2, 1), (0, 3, 2), (4, 5, 6), (4, 6, 7),
            (0, 1, 5), (0, 5, 4), (1, 2, 6), (1, 6, 5),
            (2, 3, 7), (2, 7, 6), (3, 0, 4), (3, 4, 7),
        ]
        let triangles: [[String: Any]] = indices.map {
            [
                "first": $0.0,
                "second": $0.1,
                "third": $0.2,
                "materialIndex": 7,
            ]
        }
        var manifest: [String: Any] = [
            "schemaVersion": 1,
            "format": GModAttestedPropPhysicsManifestLoader.format,
            "attestationAuthority": "test-owned independent oracle",
            "evidenceSHA256": String(repeating: "a", count: 64),
            "assets": [[
                "modelPath": path,
                "mdlSHA256": overrideMDLDigest ?? digest(mdl),
                "phySHA256": digest(phy),
                "studioChecksum": checksum,
                "collisionBounds": [
                    "minimum": vector(-1, -1, -1),
                    "maximum": vector(1, 1, 1),
                ],
                "shape": [
                    "topology": "convexParts",
                    "parts": [[
                        "vertices": vertices,
                        "triangles": triangles,
                    ]],
                ],
                "massKilograms": 12,
                "principalInertia": vector(8, 9, 10),
                "solidIndex": solidIndex,
                "materialIndex": 7,
                "bodyBehavior": [
                    "motionType": "dynamic",
                    "isGravityEnabled": true,
                    "isCollisionEnabled": true,
                    "startsAwake": true,
                ],
            ]],
        ]
        if includeAxisConvention {
            manifest["axisConvention"] =
                GModAttestedPropPhysicsManifestLoader.sourceAxisConvention
        }
        return Fixture(
            modelPath: path,
            checksum: checksum,
            mdl: mdl,
            phy: phy,
            manifest: try! JSONSerialization.data(
                withJSONObject: manifest,
                options: [.sortedKeys]
            ),
            content: FixtureContent(files: [path: mdl, phyPath: phy])
        )
    }

    private func vector(_ x: Float, _ y: Float, _ z: Float) -> [String: Any] {
        ["x": x, "y": y, "z": z]
    }

    private func digest(_ data: Data) -> String {
        var hasher = GModContentSHA256()
        hasher.update(data)
        return hasher.hexadecimalDigest()
    }

    private func makeMDL(checksum: Int32) -> Data {
        var data = Data(repeating: 0, count: SourceStudioModel.studioHeaderSize)
        data.writeManifestFixtureLE(SourceStudioModel.magic, at: 0)
        data.writeManifestFixtureLE(Int32(48), at: 4)
        data.writeManifestFixtureLE(checksum, at: 8)
        data.replaceSubrange(12 ..< 17, with: Data("cube".utf8) + Data([0]))
        data.writeManifestFixtureLE(Int32(data.count), at: 76)
        return data
    }

    private func makePHY(checksum: Int32) -> Data {
        var data = Data(repeating: 0, count: 16)
        data.writeManifestFixtureLE(Int32(16), at: 0)
        data.writeManifestFixtureLE(Int32(0), at: 4)
        data.writeManifestFixtureLE(Int32(1), at: 8)
        data.writeManifestFixtureLE(checksum, at: 12)
        data.appendManifestFixtureLE(Int32(1))
        data.append(0x42)
        data.append(0)
        return data
    }
}

private extension Data {
    mutating func writeManifestFixtureLE<T: FixedWidthInteger>(
        _ value: T,
        at offset: Int
    ) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { bytes in
            replaceSubrange(offset ..< offset + bytes.count, with: bytes)
        }
    }

    mutating func appendManifestFixtureLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
