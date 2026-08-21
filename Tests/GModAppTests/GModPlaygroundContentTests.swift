import Foundation
import CryptoKit
import XCTest
import GModGameAssets
@testable import GModApp

final class GModPlaygroundContentTests: XCTestCase {
    func testContentVerificationFractionUsesOnlyCompletedWork() {
        let byteProgress = GModContentVerificationState(
            stage: .fullPack,
            progress: GarrysPADContentVerificationProgress(
                currentPath: "garrysmod/maps/gm_construct.bsp",
                completedFileCount: 1,
                totalFileCount: 4,
                completedByteCount: 25,
                totalByteCount: 100
            )
        )
        XCTAssertEqual(byteProgress.fractionCompleted, 0.25)

        let emptyFiles = GModContentVerificationState(
            stage: .candidateCore,
            progress: GarrysPADContentVerificationProgress(
                currentPath: nil,
                completedFileCount: 2,
                totalFileCount: 4,
                completedByteCount: 0,
                totalByteCount: 0
            )
        )
        XCTAssertEqual(emptyFiles.fractionCompleted, 0.5)
    }

    @MainActor
    func testResourceFreeLaunchRequestsExternalSelection() {
        let suiteName = "GModPlaygroundContentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = GModPlaygroundContentModel(
            runtimeFactory: GModAppRuntimeFactory(),
            defaults: defaults
        )

        guard case .missing = model.state else {
            return XCTFail("resource-free launch did not enter the ZIP selection state")
        }
        XCTAssertNil(model.assetSource)
        XCTAssertNil(model.persistenceWarning)
    }

    @MainActor
    func testInvalidSavedBookmarkFailsClosedAndIsCleared() {
        let suiteName = "GModPlaygroundContentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "GarrysPAD.ContentPack.SecurityScopedBookmark.v1"
        defaults.set(Data([0x00, 0x01, 0x02]), forKey: key)

        let model = GModPlaygroundContentModel(
            runtimeFactory: GModAppRuntimeFactory(),
            defaults: defaults
        )

        guard case let .failed(message) = model.state else {
            return XCTFail("invalid bookmark did not fail closed")
        }
        XCTAssertTrue(message.contains("Choose the content ZIP again"))
        XCTAssertNil(defaults.data(forKey: key))
    }

    @MainActor
    func testCandidateFailurePreservesReadyMountAndBookmarkWhileInitialFailureUnmounts()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GModPlaygroundContentTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let validURL = root.appendingPathComponent("GarrysPAD_Content_Test.zip")
        var payloads = [
            "garrysmod/maps/gm_construct.bsp": Data("VBSPconstruct".utf8),
            "garrysmod/maps/gm_flatgrass.bsp": Data("VBSPflatgrass".utf8),
            "garrysmod/html/img/bg.jpg": Data([0xFF, 0xD8, 0xFF, 0xD9]),
            "garrysmod/html/menu.html": Data("<html></html>".utf8),
        ]
        let manifestFiles: [[String: Any]] = payloads.keys.sorted().map { path in
            [
                "path": path,
                "byteCount": payloads[path]!.count,
                "sha256": Self.sha256Hex(payloads[path]!),
            ]
        }
        payloads["GarrysPADContentManifest.json"] = try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 1,
                "format": "GarrysPADContentPack",
                "profile": "Playground",
                "createdAtUTC": "2026-08-21T00:00:00Z",
                "source": "test-owned fixture",
                "mountRoots": ["garrysmod"],
                "excludedRoots": ["garrysmod/addons"],
                "optionalCompleteBaseFamilies": [],
                "fileCount": manifestFiles.count,
                "byteCount": payloads.values.reduce(0) { $0 + $1.count },
                "files": manifestFiles,
            ],
            options: [.sortedKeys]
        )
        try Self.writeStoredZIP(to: validURL, entries: payloads)
        let replacementURL = root.appendingPathComponent(
            "GarrysPAD_Content_Replacement.zip"
        )
        var replacementPayloads = payloads
        replacementPayloads["garrysmod/html/menu.html"] = Data(
            "<html>replacement</html>".utf8
        )
        let replacementManifestFiles: [[String: Any]] = replacementPayloads
            .filter { $0.key != "GarrysPADContentManifest.json" }
            .keys
            .sorted()
            .map { path in
                [
                    "path": path,
                    "byteCount": replacementPayloads[path]!.count,
                    "sha256": Self.sha256Hex(replacementPayloads[path]!),
                ]
            }
        replacementPayloads["GarrysPADContentManifest.json"] =
            try JSONSerialization.data(
                withJSONObject: [
                    "schemaVersion": 1,
                    "format": "GarrysPADContentPack",
                    "profile": "Playground",
                    "createdAtUTC": "2026-08-21T00:00:00Z",
                    "source": "test-owned replacement fixture",
                    "mountRoots": ["garrysmod"],
                    "excludedRoots": ["garrysmod/addons"],
                    "optionalCompleteBaseFamilies": [],
                    "fileCount": replacementManifestFiles.count,
                    "byteCount": replacementPayloads
                        .filter { $0.key != "GarrysPADContentManifest.json" }
                        .values
                        .reduce(0) { $0 + $1.count },
                    "files": replacementManifestFiles,
                ],
                options: [.sortedKeys]
            )
        try Self.writeStoredZIP(to: replacementURL, entries: replacementPayloads)
        let tamperedURL = root.appendingPathComponent(
            "GarrysPAD_Content_SameSizeTampered.zip"
        )
        var tamperedPayloads = payloads
        let originalMenuCount = tamperedPayloads["garrysmod/html/menu.html"]!.count
        tamperedPayloads["garrysmod/html/menu.html"] = Data("<evil></evil>".utf8)
        XCTAssertEqual(
            tamperedPayloads["garrysmod/html/menu.html"]!.count,
            originalMenuCount
        )
        // Keep A's manifest while writing a new, CRC-correct same-size body.
        // Index-only validation passes; the candidate core SHA must reject B.
        try Self.writeStoredZIP(to: tamperedURL, entries: tamperedPayloads)
        let invalidURL = root.appendingPathComponent("invalid.zip")
        try Data([0, 1, 2, 3]).write(to: invalidURL)

        let readySuite = "GModPlaygroundContentTests.ready.\(UUID().uuidString)"
        let readyDefaults = UserDefaults(suiteName: readySuite)!
        defer { readyDefaults.removePersistentDomain(forName: readySuite) }
        let readyFactory = GModAppRuntimeFactory()
        let readyModel = GModPlaygroundContentModel(
            runtimeFactory: readyFactory,
            defaults: readyDefaults
        )
        XCTAssertNil(readyFactory.mountedContentPackURLForTesting())

        readyModel.selectContentPack(url: validURL)
        try await waitForContentOperation(readyModel)
        guard case let .ready(originalPack, _, _) = readyModel.state else {
            return XCTFail("valid candidate did not activate")
        }
        XCTAssertEqual(
            readyModel.metadata?.manifestStatus,
            .coreIntegrityVerified
        )
        let originalSource = try XCTUnwrap(readyModel.assetSource)
        let originalMountGeneration = readyModel.activeMountGeneration
        XCTAssertGreaterThan(originalMountGeneration, 0)
        let bookmarkKey = "GarrysPAD.ContentPack.SecurityScopedBookmark.v1"
        let originalBookmark = try XCTUnwrap(
            readyDefaults.data(forKey: bookmarkKey)
        )
        XCTAssertEqual(
            readyFactory.mountedContentPackURLForTesting(),
            validURL.standardizedFileURL
        )

        readyModel.selectContentPack(url: invalidURL)
        try await waitForContentOperation(readyModel)
        guard case let .ready(preservedPack, _, _) = readyModel.state else {
            return XCTFail("failed replacement discarded ready content")
        }
        XCTAssertEqual(preservedPack.archiveURL, originalPack.archiveURL)
        XCTAssertTrue(readyModel.assetSource === originalSource)
        XCTAssertEqual(
            readyModel.activeMountGeneration,
            originalMountGeneration,
            "a rejected candidate must preserve Home's active mount identity"
        )
        XCTAssertEqual(readyDefaults.data(forKey: bookmarkKey), originalBookmark)
        XCTAssertEqual(
            readyFactory.mountedContentPackURLForTesting(),
            validURL.standardizedFileURL
        )

        readyModel.selectContentPack(url: tamperedURL)
        try await waitForContentOperation(readyModel)
        guard case let .ready(hashPreservedPack, _, _) = readyModel.state else {
            return XCTFail("same-size tampered B discarded ready A")
        }
        XCTAssertEqual(hashPreservedPack.archiveURL, originalPack.archiveURL)
        XCTAssertTrue(readyModel.assetSource === originalSource)
        XCTAssertEqual(readyModel.activeMountGeneration, originalMountGeneration)
        XCTAssertEqual(readyDefaults.data(forKey: bookmarkKey), originalBookmark)
        XCTAssertTrue(readyModel.lastError?.contains("SHA-256 mismatch") == true)
        XCTAssertEqual(
            readyFactory.mountedContentPackURLForTesting(),
            validURL.standardizedFileURL
        )

        readyModel.selectContentPack(url: replacementURL)
        try await waitForContentOperation(readyModel)
        guard case let .ready(replacementPack, _, _) = readyModel.state else {
            return XCTFail("valid replacement candidate did not activate")
        }
        XCTAssertEqual(
            replacementPack.archiveURL,
            replacementURL.standardizedFileURL
        )
        XCTAssertFalse(readyModel.assetSource === originalSource)
        XCTAssertEqual(
            readyModel.activeMountGeneration,
            originalMountGeneration &+ 1,
            "a committed A-to-B replacement must recreate pack-bound Home state"
        )
        XCTAssertEqual(
            readyFactory.mountedContentPackURLForTesting(),
            replacementURL.standardizedFileURL
        )

        let replacementMountGeneration = readyModel.activeMountGeneration
        readyModel.revalidateActiveSelection()
        try await waitForContentOperation(readyModel)
        guard case let .ready(revalidatedPack, _, _) = readyModel.state else {
            return XCTFail("same-URL revalidation did not preserve ready content")
        }
        XCTAssertEqual(
            revalidatedPack.archiveURL,
            replacementURL.standardizedFileURL
        )
        XCTAssertEqual(
            readyModel.activeMountGeneration,
            replacementMountGeneration &+ 1,
            "successful same-URL revalidation must recreate pack-bound Home state"
        )
        XCTAssertEqual(
            readyModel.metadata?.manifestStatus,
            .fullIntegrityVerified
        )

        let fullyVerifiedSource = try XCTUnwrap(readyModel.assetSource)
        let fullyVerifiedMetadata = readyModel.metadata
        let fullyVerifiedDate = readyModel.lastValidationDate
        let fullyVerifiedGeneration = readyModel.activeMountGeneration
        readyModel.revalidateActiveSelection()
        XCTAssertTrue(readyModel.isValidatingCandidate)
        readyModel.cancelValidation()
        XCTAssertFalse(readyModel.isValidatingCandidate)
        XCTAssertNil(readyModel.verificationState)
        XCTAssertTrue(readyModel.assetSource === fullyVerifiedSource)
        XCTAssertEqual(readyModel.metadata, fullyVerifiedMetadata)
        XCTAssertEqual(readyModel.lastValidationDate, fullyVerifiedDate)
        XCTAssertEqual(
            readyModel.activeMountGeneration,
            fullyVerifiedGeneration,
            "cancelling full verification must not relabel or remount the prior pack"
        )
        XCTAssertEqual(
            readyFactory.mountedContentPackURLForTesting(),
            replacementURL.standardizedFileURL
        )

        readyModel.forgetSelection()
        XCTAssertNil(readyFactory.mountedContentPackURLForTesting())
        XCTAssertTrue(FileManager.default.fileExists(atPath: validURL.path))

        let failedSuite = "GModPlaygroundContentTests.failed.\(UUID().uuidString)"
        let failedDefaults = UserDefaults(suiteName: failedSuite)!
        defer { failedDefaults.removePersistentDomain(forName: failedSuite) }
        let failedFactory = GModAppRuntimeFactory()
        try failedFactory.mountContentPack(originalPack)
        XCTAssertEqual(
            failedFactory.mountedContentPackURLForTesting(),
            validURL.standardizedFileURL
        )
        let failedModel = GModPlaygroundContentModel(
            runtimeFactory: failedFactory,
            defaults: failedDefaults
        )
        XCTAssertNil(
            failedFactory.mountedContentPackURLForTesting(),
            "an initial missing state must clear a stale process-static mount"
        )
        failedModel.selectContentPack(url: invalidURL)
        try await waitForContentOperation(failedModel)
        guard case .failed = failedModel.state else {
            return XCTFail("invalid initial candidate did not fail")
        }
        XCTAssertNil(failedFactory.mountedContentPackURLForTesting())
        XCTAssertNil(failedDefaults.data(forKey: bookmarkKey))
    }

    @MainActor
    private func waitForContentOperation(
        _ model: GModPlaygroundContentModel
    ) async throws {
        for _ in 0..<300 {
            if !model.isValidatingCandidate { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("content operation did not complete")
    }

    private static func writeStoredZIP(
        to url: URL,
        entries: [String: Data]
    ) throws {
        struct CentralEntry {
            let name: Data
            let data: Data
            let crc: UInt32
            let localOffset: UInt32
        }

        var archive = Data()
        var centralEntries: [CentralEntry] = []
        for (path, payload) in entries.sorted(by: { $0.key < $1.key }) {
            let name = Data(path.utf8)
            let crc = crc32(payload)
            let offset = UInt32(archive.count)
            archive.appendUInt32(0x0403_4B50)
            archive.appendUInt16(20)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt32(crc)
            archive.appendUInt32(UInt32(payload.count))
            archive.appendUInt32(UInt32(payload.count))
            archive.appendUInt16(UInt16(name.count))
            archive.appendUInt16(0)
            archive.append(name)
            archive.append(payload)
            centralEntries.append(CentralEntry(
                name: name,
                data: payload,
                crc: crc,
                localOffset: offset
            ))
        }

        let centralOffset = UInt32(archive.count)
        for entry in centralEntries {
            archive.appendUInt32(0x0201_4B50)
            archive.appendUInt16(20)
            archive.appendUInt16(20)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt32(entry.crc)
            archive.appendUInt32(UInt32(entry.data.count))
            archive.appendUInt32(UInt32(entry.data.count))
            archive.appendUInt16(UInt16(entry.name.count))
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt32(0)
            archive.appendUInt32(entry.localOffset)
            archive.append(entry.name)
        }
        let centralSize = UInt32(archive.count) - centralOffset
        archive.appendUInt32(0x0605_4B50)
        archive.appendUInt16(0)
        archive.appendUInt16(0)
        archive.appendUInt16(UInt16(centralEntries.count))
        archive.appendUInt16(UInt16(centralEntries.count))
        archive.appendUInt32(centralSize)
        archive.appendUInt32(centralOffset)
        archive.appendUInt16(0)
        try archive.write(to: url, options: .atomic)
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xEDB8_8320)
            }
        }
        return ~crc
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
