import Foundation
import XCTest
import GModEngine

final class SourceStudioFileIdentityTests: XCTestCase {
    private func fixture(version: UInt32, length: UInt32 = 80) -> Data {
        var data = Data(repeating: 0, count: 80)
        for (offset, value) in [(0, SourceStudioModel.magic), (4, version), (8, UInt32(123)), (76, length)] {
            for byte in 0..<4 { data[offset + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8)) }
        }
        data.replaceSubrange(12..<16, with: Data("test".utf8))
        return data
    }
    func testIdentitySupportsOnlyEvidencedPrefixesAndValidatesLengthChecksum() throws {
        for version: UInt32 in [44, 48] {
            let identity = try SourceStudioFileIdentity(data: fixture(version: version), expectedChecksum: 123)
            XCTAssertEqual(identity.version, Int32(version))
            XCTAssertEqual(identity.name, "test")
            XCTAssertEqual(identity.byteCount, 80)
        }
        XCTAssertThrowsError(try SourceStudioFileIdentity(data: fixture(version: 45)))
        XCTAssertThrowsError(try SourceStudioFileIdentity(data: fixture(version: 44, length: 81)))
        XCTAssertThrowsError(try SourceStudioFileIdentity(data: fixture(version: 44), expectedChecksum: 124))
        XCTAssertThrowsError(try SourceStudioFileIdentity(data: Data(repeating: 0, count: 79)))
        XCTAssertEqual(SourceStudioModel.supportedVersions, [48], "identity support must not claim v44 rendering")
    }
}
