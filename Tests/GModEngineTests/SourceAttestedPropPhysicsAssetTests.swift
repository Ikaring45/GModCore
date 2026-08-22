import Testing
@testable import GModEngine

@Suite("Independently attested Source prop physics asset")
struct SourceAttestedPropPhysicsAssetTests {
    private let mdlDigest = String(repeating: "1a", count: 32)
    private let phyDigest = String(repeating: "b2", count: 32)

    @Test("exact provenance produces collision and canonical body inputs")
    func constructsCanonicalInputsWithoutFallbacks() throws {
        let shape = try makeShape()
        let mass = try SourcePhysicsMassProperties(
            massKilograms: 18.75,
            principalInertia: SourceVector3(3, 4, 5)
        )
        let collision = try SourceCollisionProperty(
            mins: SourceVector3(-2, -3, -4),
            maxs: SourceVector3(5, 6, 7)
        )
        let behavior = SourceAttestedPropPhysicsBodyBehavior(
            motionType: .dynamicBody,
            isGravityEnabled: true,
            isCollisionEnabled: true,
            startsAwake: false
        )

        let first = try makeAsset(
            collision: collision,
            shape: shape,
            mass: mass,
            behavior: behavior
        )
        let second = try makeAsset(
            collision: collision,
            shape: shape,
            mass: mass,
            behavior: behavior
        )

        #expect(first.normalizedModelPath == "models/props/attested_test.mdl")
        #expect(first.mdlSHA256 == mdlDigest)
        #expect(first.phySHA256 == phyDigest)
        #expect(first.studioChecksum == -1_817_891_700)
        #expect(first.collisionProperty == collision)
        #expect(first.bodyDefinition.solidIndex == 2)
        #expect(first.bodyDefinition.shape == shape)
        #expect(first.bodyDefinition.massProperties == mass)
        #expect(first.bodyDefinition.motionType == .dynamicBody)
        #expect(first.bodyDefinition.materialIndex == 11)
        #expect(first.bodyDefinition.isGravityEnabled)
        #expect(first.bodyDefinition.isCollisionEnabled)
        #expect(!first.bodyDefinition.startsAwake)
        #expect(first.identity == second.identity)

        let changedBehavior = SourceAttestedPropPhysicsBodyBehavior(
            motionType: .kinematicBody,
            isGravityEnabled: false,
            isCollisionEnabled: true,
            startsAwake: false
        )
        let changed = try makeAsset(
            collision: collision,
            shape: shape,
            mass: mass,
            behavior: changedBehavior
        )
        #expect(first.identity != changed.identity)
    }

    @Test("model path must already be the canonical Source MDL spelling")
    func rejectsNonCanonicalModelPaths() throws {
        let invalidPaths = [
            "Models/props/attested_test.mdl",
            "models\\props\\attested_test.mdl",
            "models/props/../attested_test.mdl",
            "models//props/attested_test.mdl",
            "/models/props/attested_test.mdl",
            "models/props/attested_test.phy",
            "props/attested_test.mdl"
        ]

        for path in invalidPaths {
            do {
                _ = try makeAsset(normalizedModelPath: path)
                Issue.record("expected canonical model-path rejection for \(path)")
            } catch let error as SourceAttestedPropPhysicsAssetError {
                #expect(error == .nonCanonicalModelPath(path))
            }
        }
    }

    @Test("MDL and PHY identities require exact lowercase SHA-256 syntax")
    func rejectsMalformedDigests() throws {
        let malformed = [
            "",
            String(repeating: "a", count: 63),
            String(repeating: "a", count: 65),
            String(repeating: "A", count: 64),
            "sha256:" + String(repeating: "a", count: 64),
            String(repeating: "g", count: 64),
            String(repeating: "a", count: 63) + " "
        ]

        for digest in malformed {
            do {
                _ = try makeAsset(mdlSHA256: digest)
                Issue.record("expected strict MDL digest rejection")
            } catch let error as SourceAttestedPropPhysicsAssetError {
                #expect(error == .invalidSHA256(file: .mdl, value: digest))
            }

            do {
                _ = try makeAsset(phySHA256: digest)
                Issue.record("expected strict PHY digest rejection")
            } catch let error as SourceAttestedPropPhysicsAssetError {
                #expect(error == .invalidSHA256(file: .phy, value: digest))
            }
        }
    }

    @Test("an unattested structural VPhysics decode cannot cross the asset boundary")
    func rejectsUnattestedVPhysicsEvidence() throws {
        do {
            _ = try makeAsset(
                shapeEvidence: .decodedVPhysics(
                    shape: try makeShape(),
                    verification: .unattested
                )
            )
            Issue.record("expected unattested VPhysics rejection")
        } catch let error as SourceAttestedPropPhysicsAssetError {
            #expect(error == .unattestedVPhysicsCollisionSnapshot)
        }
    }

    @Test("solid and material indexes remain fail-closed physics inputs")
    func rejectsInvalidIndexes() throws {
        do {
            _ = try makeAsset(solidIndex: -1)
            Issue.record("expected negative solid rejection")
        } catch let error as SourceAttestedPropPhysicsAssetError {
            #expect(error == .physicsContract(.negativeSolidIndex(-1)))
        }

        do {
            _ = try makeAsset(materialIndex: -2)
            Issue.record("expected negative material rejection")
        } catch let error as SourceAttestedPropPhysicsAssetError {
            #expect(error == .physicsContract(.negativeMaterialIndex(
                field: "materialIndex",
                value: -2
            )))
        }
    }
}

private extension SourceAttestedPropPhysicsAssetTests {
    func makeAsset(
        normalizedModelPath: String = "models/props/attested_test.mdl",
        mdlSHA256: String? = nil,
        phySHA256: String? = nil,
        collision: SourceCollisionProperty? = nil,
        shape: SourcePhysicsShapeSnapshot? = nil,
        shapeEvidence: SourceAttestedPropPhysicsShapeEvidence? = nil,
        mass: SourcePhysicsMassProperties? = nil,
        solidIndex: Int = 2,
        materialIndex: Int = 11,
        behavior: SourceAttestedPropPhysicsBodyBehavior? = nil
    ) throws -> SourceAttestedPropPhysicsAsset {
        let resolvedShape = try shape ?? makeShape()
        return try SourceAttestedPropPhysicsAsset(
            normalizedModelPath: normalizedModelPath,
            mdlSHA256: mdlSHA256 ?? self.mdlDigest,
            phySHA256: phySHA256 ?? self.phyDigest,
            studioChecksum: -1_817_891_700,
            collisionProperty: try collision ?? SourceCollisionProperty(
                mins: SourceVector3(-2, -3, -4),
                maxs: SourceVector3(5, 6, 7)
            ),
            shapeEvidence: shapeEvidence ?? .independentlyAttested(resolvedShape),
            massProperties: try mass ?? SourcePhysicsMassProperties(
                massKilograms: 18.75,
                principalInertia: SourceVector3(3, 4, 5)
            ),
            solidIndex: solidIndex,
            materialIndex: materialIndex,
            bodyBehavior: behavior ?? SourceAttestedPropPhysicsBodyBehavior(
                motionType: .dynamicBody,
                isGravityEnabled: true,
                isCollisionEnabled: true,
                startsAwake: false
            )
        )
    }

    func makeShape() throws -> SourcePhysicsShapeSnapshot {
        let vertices = [
            SourceVector3(0, 0, 0),
            SourceVector3(1, 0, 0),
            SourceVector3(0, 1, 0),
            SourceVector3(0, 0, 1)
        ]
        let triangles = try [
            SourcePhysicsIndexedTriangle(first: 0, second: 2, third: 1, materialIndex: 1),
            SourcePhysicsIndexedTriangle(first: 0, second: 1, third: 3, materialIndex: 1),
            SourcePhysicsIndexedTriangle(first: 1, second: 2, third: 3, materialIndex: 1),
            SourcePhysicsIndexedTriangle(first: 2, second: 0, third: 3, materialIndex: 1)
        ]
        return try SourcePhysicsShapeSnapshot(
            topology: .convexParts,
            parts: [
                SourcePhysicsMeshPartSnapshot(
                    vertices: vertices,
                    triangles: triangles
                )
            ]
        )
    }
}
