import XCTest
@testable import GModEngine

final class SourceAttestedStudioBodyGroupMetadataTests: XCTestCase {
    func testExactIdentityAndSourceSelectionLayoutAreRequired() throws {
        let exact = try metadata(
            mdlSHA256: String(repeating: "a", count: 64),
            checksum: 42,
            bodyParts: [
                .init(modelSelectionBase: 1, modelCount: 2),
                .init(modelSelectionBase: 2, modelCount: 3),
            ]
        )
        let asset = try makeAttestedPropPhysicsTestAsset(
            modelPath: exact.normalizedModelPath,
            mdlSHA256: exact.mdlSHA256,
            studioChecksum: exact.studioChecksum
        )

        XCTAssertTrue(exact.exactlyMatches(asset))
        XCTAssertEqual(
            try exact.bodyValue(applyingBodyGroups: "12", to: 0),
            5
        )

        let wrongHash = try metadata(
            mdlSHA256: String(repeating: "b", count: 64),
            checksum: 42,
            bodyParts: exact.bodyParts
        )
        let wrongChecksum = try metadata(
            mdlSHA256: exact.mdlSHA256,
            checksum: 43,
            bodyParts: exact.bodyParts
        )
        XCTAssertFalse(wrongHash.exactlyMatches(asset))
        XCTAssertFalse(wrongChecksum.exactlyMatches(asset))
    }

    func testRejectsUnboundOrInvalidLayoutMetadata() throws {
        XCTAssertThrowsError(
            try metadata(
                mdlSHA256: "ABC",
                checksum: 42,
                bodyParts: [.init(modelSelectionBase: 1, modelCount: 1)]
            )
        )
        XCTAssertThrowsError(
            try metadata(
                mdlSHA256: String(repeating: "a", count: 64),
                checksum: 42,
                bodyParts: [.init(modelSelectionBase: 0, modelCount: 1)]
            )
        )
        XCTAssertThrowsError(
            try metadata(
                mdlSHA256: String(repeating: "a", count: 64),
                checksum: 42,
                bodyParts: [.init(modelSelectionBase: 1, modelCount: 0)]
            )
        )
    }

    private func metadata(
        mdlSHA256: String,
        checksum: Int32,
        bodyParts: [SourceStudioBodyGroupSelectionDescriptor]
    ) throws -> SourceAttestedStudioBodyGroupMetadata {
        try SourceAttestedStudioBodyGroupMetadata(
            normalizedModelPath: "models/exact/test.mdl",
            mdlSHA256: mdlSHA256,
            studioChecksum: checksum,
            bodyParts: bodyParts,
            attestationReference: "focused-test"
        )
    }
}
