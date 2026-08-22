import XCTest
import GModEngine
@testable import GModGameSession

final class GModPlayableSessionPakFileIntegrationTests: XCTestCase {
    func testConstructPakIsSharedByBothRealmsAndClientMaterialResolver() throws {
        let session = try GModPlayableSession(configuration: .init(map: .construct))
        defer { _ = try? session.close() }

        XCTAssertEqual(session.mapPakFileSystem.entries.count, 599)
        XCTAssertNil(
            session.surfacePropertiesAttestation,
            "bundled fixtures do not ship an authored surface manifest"
        )

        let materialName =
            "maps/gm_construct/gm_construct/grass_13_wvt_patch"
        let materialPath = "materials/\(materialName).vmt"
        let textureName = "maps/gm_construct/c1436_-571_-71"
        let texturePath = "materials/\(textureName).vtf"

        let expectedVMT = try XCTUnwrap(
            session.mapPakFileSystem.data(for: materialPath)
        )
        let expectedVTF = try XCTUnwrap(
            session.mapPakFileSystem.data(for: texturePath)
        )
        for (realm, fileSystem) in [
            ("SERVER", session.serverFileSystem),
            ("CLIENT", session.clientFileSystem),
        ] {
            XCTAssertEqual(
                try fileSystem.readFile(at: materialPath),
                expectedVMT,
                "\(realm) did not expose the shared pak VMT"
            )
            XCTAssertEqual(
                try fileSystem.readFile(at: texturePath),
                expectedVTF,
                "\(realm) did not expose the shared pak VTF"
            )
        }

        let material = try session.clientMaterialResolver.resolve(
            named: materialName
        )
        XCTAssertEqual(material.metadata.materialPath.utf8String, materialPath)
        XCTAssertEqual(material.metadata.shaderName.utf8String, "LightmappedGeneric")
        XCTAssertEqual(
            material.metadata.baseTextureName?.utf8String,
            "materials/gm_construct/grass1.vtf"
        )
        XCTAssertEqual(material.metadata.status, .baseTextureMissing)
        XCTAssertFalse(material.metadata.isError)

        let texture = try XCTUnwrap(
            session.clientMaterialResolver.resolveTexture(named: textureName)
        )
        XCTAssertEqual(texture.logicalPath, texturePath)
        XCTAssertEqual(texture.status, .decoded)
        XCTAssertTrue(texture.flags?.contains(.environmentMap) == true)
        XCTAssertGreaterThan(try XCTUnwrap(texture.width), 0)
        XCTAssertGreaterThan(try XCTUnwrap(texture.height), 0)
        XCTAssertFalse(texture.mipImages.isEmpty)
    }
}
