import XCTest
@testable import GModEngine
@testable import GModGameSession

final class GModAttestedStudioBodyGroupCatalogTests: XCTestCase {
    func testCheckedInButtonDescriptorMatchesExactOwnedIdentity() throws {
        let metadata = try GModOwnedAttestedStudioBodyGroupMetadata.button06()
        XCTAssertEqual(
            metadata.normalizedModelPath,
            "models/maxofs2d/button_06.mdl"
        )
        XCTAssertEqual(
            metadata.mdlSHA256,
            "85dca39870932c39dd1bcd51afbb0fc09aaf8d90fadfeb222e7b49cd784e0f07"
        )
        XCTAssertEqual(metadata.studioChecksum, -1_817_891_700)
        XCTAssertEqual(
            metadata.bodyParts,
            [.init(modelSelectionBase: 1, modelCount: 1)]
        )
        XCTAssertEqual(
            try metadata.bodyValue(
                applyingBodyGroups: "000000000",
                to: 0
            ),
            0
        )

        let exactAsset = try makeAttestedPropPhysicsTestAsset(
            modelPath: metadata.normalizedModelPath,
            mdlSHA256: metadata.mdlSHA256,
            studioChecksum: metadata.studioChecksum
        )
        let catalog = try GModOwnedAttestedStudioBodyGroupMetadata
            .initialCatalog()
        XCTAssertEqual(
            catalog.metadata(exactlyMatching: exactAsset),
            metadata
        )
    }

    func testHashOrChecksumMismatchStaysAbsent() throws {
        let metadata = try GModOwnedAttestedStudioBodyGroupMetadata.button06()
        let catalog = try GModOwnedAttestedStudioBodyGroupMetadata
            .initialCatalog()
        let wrongHash = try makeAttestedPropPhysicsTestAsset(
            modelPath: metadata.normalizedModelPath,
            mdlSHA256: String(repeating: "f", count: 64),
            studioChecksum: metadata.studioChecksum
        )
        let wrongChecksum = try makeAttestedPropPhysicsTestAsset(
            modelPath: metadata.normalizedModelPath,
            mdlSHA256: metadata.mdlSHA256,
            studioChecksum: metadata.studioChecksum &+ 1
        )

        XCTAssertNil(catalog.metadata(exactlyMatching: wrongHash))
        XCTAssertNil(catalog.metadata(exactlyMatching: wrongChecksum))
    }
}
