import Foundation
import Testing
@testable import GModGameSession
import GModEngine
import GModGameAssets

@Suite("Exact-byte attested prop physics resolution")
struct GModAttestedPropPhysicsAssetResolverTests {
    private let modelPath = "models/props/attested_plate.mdl"
    private let mdlData = Data("exact mdl".utf8)
    private let phyData = Data("exact phy".utf8)
    private let checksum: Int32 = 1_234_567

    @Test("an exact MDL PHY and checksum match resolves once and caches")
    func resolvesExactBytesOnce() throws {
        let asset = try makeAsset()
        let calls = LockedCounter()
        let resolver = try GModAttestedPropPhysicsAssetResolver(
            attestedAssets: [asset]
        ) { model in
            calls.increment()
            return .loaded(GModObservedPropPhysicsAsset(
                normalizedModelPath: model.path,
                mdlData: mdlData,
                phyData: phyData,
                studioChecksum: checksum
            ))
        }

        let first = resolver.resolve(SourceEntityModelReference(
            "Models\\Props\\Attested_Plate.mdl"
        ))
        let second = resolver.resolve(SourceEntityModelReference(modelPath))

        #expect(first == .valid(asset))
        #expect(second == .valid(asset))
        #expect(first.modelValidation == .valid)
        #expect(calls.value == 1)
        #expect(resolver.cachedResolutionCount == 1)
    }

    @Test("unattested and malformed paths never read content")
    func rejectsBeforeReading() throws {
        let calls = LockedCounter()
        let resolver = try GModAttestedPropPhysicsAssetResolver(
            attestedAssets: [try makeAsset()]
        ) { _ in
            calls.increment()
            return .invalid(.missingOpaquePHY("unexpected"))
        }

        #expect(resolver.resolve(SourceEntityModelReference(
            "models/props/not_attested.mdl"
        )) == .invalid(.notAttested("models/props/not_attested.mdl")))
        #expect(resolver.resolve(SourceEntityModelReference(
            "../outside.mdl"
        )) == .invalid(.invalidModelPath("../outside.mdl")))
        #expect(calls.value == 0)
        #expect(resolver.cachedResolutionCount == 0)
    }

    @Test("each exact byte identity and Studio checksum fails closed")
    func rejectsContentDrift() throws {
        let asset = try makeAsset()
        let cases: [(
            GModObservedPropPhysicsAsset,
            (GModAttestedPropPhysicsAssetInvalidReason) -> Bool
        )] = [
            (
                observation(mdlData: Data("changed mdl".utf8)),
                { if case .mdlSHA256 = $0 { return true }; return false }
            ),
            (
                observation(phyData: Data("changed phy".utf8)),
                { if case .phySHA256 = $0 { return true }; return false }
            ),
            (
                observation(studioChecksum: checksum + 1),
                { if case .studioChecksum = $0 { return true }; return false }
            ),
            (
                observation(normalizedModelPath: "models/props/other.mdl"),
                { if case .observedModelPath = $0 { return true }; return false }
            )
        ]

        for (observed, matches) in cases {
            let resolver = try GModAttestedPropPhysicsAssetResolver(
                attestedAssets: [asset]
            ) { _ in .loaded(observed) }
            let result = resolver.resolve(SourceEntityModelReference(modelPath))
            guard case let .invalid(reason) = result else {
                Issue.record("expected exact content mismatch, got \(result)")
                continue
            }
            #expect(matches(reason))
            #expect(result.modelValidation == .invalid)
        }
    }

    @Test("host unavailability stays distinct and is stable for the session")
    func preservesUnavailableOutcome() throws {
        let calls = LockedCounter()
        let reason = SourceStudioModelAssetUnavailable.readFailed(
            kind: .phy,
            path: "models/props/attested_plate.phy",
            reason: "bounded provider unavailable"
        )
        let resolver = try GModAttestedPropPhysicsAssetResolver(
            attestedAssets: [try makeAsset()]
        ) { _ in
            calls.increment()
            return .unavailable(reason)
        }

        let first = resolver.resolve(SourceEntityModelReference(modelPath))
        let second = resolver.resolve(SourceEntityModelReference(modelPath))
        #expect(first == .unavailable(reason))
        #expect(second.modelValidation == .unavailable)
        #expect(calls.value == 1)
    }

    @Test("duplicate attestation paths are rejected at construction")
    func rejectsDuplicateCatalogEntries() throws {
        let asset = try makeAsset()
        do {
            _ = try GModAttestedPropPhysicsAssetResolver(
                attestedAssets: [asset, asset]
            ) { _ in .loaded(observation()) }
            Issue.record("expected duplicate model path rejection")
        } catch let error as GModAttestedPropPhysicsAssetCatalogError {
            #expect(error == .duplicateModelPath(modelPath))
        }
    }
}

private extension GModAttestedPropPhysicsAssetResolverTests {
    func makeAsset() throws -> SourceAttestedPropPhysicsAsset {
        try SourceAttestedPropPhysicsAsset(
            normalizedModelPath: modelPath,
            mdlSHA256: digest(mdlData),
            phySHA256: digest(phyData),
            studioChecksum: checksum,
            collisionProperty: SourceCollisionProperty(
                mins: SourceVector3(-8, -12, -2),
                maxs: SourceVector3(8, 12, 2)
            ),
            shapeEvidence: .independentlyAttested(try shape()),
            massProperties: SourcePhysicsMassProperties(
                massKilograms: 14,
                principalInertia: SourceVector3(2, 3, 4)
            ),
            solidIndex: 0,
            materialIndex: 1,
            bodyBehavior: SourceAttestedPropPhysicsBodyBehavior(
                motionType: .dynamicBody,
                isGravityEnabled: true,
                isCollisionEnabled: true,
                startsAwake: true
            )
        )
    }

    func observation(
        normalizedModelPath: String? = nil,
        mdlData: Data? = nil,
        phyData: Data? = nil,
        studioChecksum: Int32? = nil
    ) -> GModObservedPropPhysicsAsset {
        GModObservedPropPhysicsAsset(
            normalizedModelPath: normalizedModelPath ?? modelPath,
            mdlData: mdlData ?? self.mdlData,
            phyData: phyData ?? self.phyData,
            studioChecksum: studioChecksum ?? checksum
        )
    }

    func shape() throws -> SourcePhysicsShapeSnapshot {
        let vertices = [
            SourceVector3(0, 0, 0),
            SourceVector3(1, 0, 0),
            SourceVector3(0, 1, 0),
            SourceVector3(0, 0, 1)
        ]
        let triangles = try [
            SourcePhysicsIndexedTriangle(
                first: 0, second: 2, third: 1, materialIndex: 1
            ),
            SourcePhysicsIndexedTriangle(
                first: 0, second: 1, third: 3, materialIndex: 1
            ),
            SourcePhysicsIndexedTriangle(
                first: 1, second: 2, third: 3, materialIndex: 1
            ),
            SourcePhysicsIndexedTriangle(
                first: 2, second: 0, third: 3, materialIndex: 1
            )
        ]
        return try SourcePhysicsShapeSnapshot(
            topology: .convexParts,
            parts: [SourcePhysicsMeshPartSnapshot(
                vertices: vertices,
                triangles: triangles
            )]
        )
    }

    func digest(_ data: Data) -> String {
        var hasher = GModContentSHA256()
        hasher.update(data)
        return hasher.hexadecimalDigest()
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
