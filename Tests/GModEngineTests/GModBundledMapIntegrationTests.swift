import Foundation
import XCTest
@testable import GModEngine
import GModGameAssets

final class GModBundledMapIntegrationTests: XCTestCase {
    private struct ExpectedMap {
        let map: GModBundledMap
        let bspBytes: Int
        let navBytes: Int
        let ainBytes: Int
        let revision: Int32
        let planeCount: Int
        let vertexCount: Int
        let faceCount: Int
        let leafCount: Int
        let brushCount: Int
        let playerStartCount: Int
    }

    private let expectedMaps = [
        ExpectedMap(
            map: .construct,
            bspBytes: 36_735_656,
            navBytes: 7_242_376,
            ainBytes: 104_021,
            revision: 1_765,
            planeCount: 4_322,
            vertexCount: 14_079,
            faceCount: 9_460,
            leafCount: 5_002,
            brushCount: 2_203,
            playerStartCount: 33
        ),
        ExpectedMap(
            map: .flatgrass,
            bspBytes: 47_430_424,
            navBytes: 276_845,
            ainBytes: 24_659,
            revision: 146,
            planeCount: 1_286,
            vertexCount: 3_738,
            faceCount: 2_922,
            leafCount: 3_610,
            brushCount: 112,
            playerStartCount: 56
        ),
    ]

    func testManifestCoversExactBaseGameMapNavigationAndNodeGraphFiles() throws {
        let manifest = try GModGameAssets.manifest()
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertTrue(manifest.sourceScope.contains("base-game"))
        XCTAssertTrue(manifest.sourceScope.contains("Workshop and addon content excluded"))
        XCTAssertEqual(manifest.assets.count, 6)
        XCTAssertEqual(Set(manifest.assets.map(\.sha256)).count, 6)

        for expected in expectedMaps {
            for (kind, byteCount) in [
                (GModBundledMapAssetKind.bsp, expected.bspBytes),
                (.nav, expected.navBytes),
                (.ain, expected.ainBytes),
            ] {
                let data = try GModGameAssets.data(for: expected.map, kind: kind)
                XCTAssertEqual(
                    data.count,
                    byteCount,
                    "unexpected \(kind.rawValue) fixture for \(expected.map.rawValue)"
                )
                let suffix = kind == .ain
                    ? "maps/graphs/\(expected.map.rawValue).ain"
                    : "maps/\(expected.map.rawValue).\(kind.rawValue)"
                let entry = try XCTUnwrap(
                    manifest.assets.first { $0.logicalPath == suffix }
                )
                XCTAssertEqual(entry.byteCount, data.count)
                XCTAssertEqual(entry.sha256.count, 64)
            }
        }
    }

    func testConstructAndFlatgrassParseSpawnAndTraceTheirRealWorldBrushes() throws {
        for expected in expectedMaps {
            let data = try GModGameAssets.data(for: expected.map, kind: .bsp)
            let bsp = try SourceBSP(data: data)

            XCTAssertEqual(bsp.header.version, 20)
            XCTAssertEqual(bsp.header.mapRevision, expected.revision)
            XCTAssertEqual(bsp.planes.count, expected.planeCount)
            XCTAssertEqual(bsp.vertices.count, expected.vertexCount)
            XCTAssertEqual(bsp.faces.count, expected.faceCount)
            XCTAssertEqual(bsp.leaves.count, expected.leafCount)
            XCTAssertEqual(bsp.brushes.count, expected.brushCount)
            XCTAssertEqual(
                bsp.prebuiltWorldCollisionPrimitiveCount,
                expected.brushCount
            )

            let entityText = try XCTUnwrap(bsp.entities.text)
            let playerStarts = try parsePlayerStarts(entityText)
            XCTAssertEqual(playerStarts.count, expected.playerStartCount)
            let spawn = try XCTUnwrap(playerStarts.first)

            let start = SourceVector3(spawn.x, spawn.y, spawn.z + 512)
            let end = SourceVector3(spawn.x, spawn.y, spawn.z - 4_096)
            let lineTrace = try bsp.traceWorld(
                SourceRay(start: start, end: end),
                mask: SourceMasks.playerSolidBrushOnly
            )
            XCTAssertTrue(lineTrace.didHit, "\(expected.map.rawValue) line missed its spawn floor")
            XCTAssertTrue(lineTrace.didHitWorld)
            XCTAssertFalse(lineTrace.startSolid)
            XCTAssertGreaterThanOrEqual(lineTrace.fraction, 0)
            XCTAssertLessThan(lineTrace.fraction, 1)
            XCTAssertGreaterThan(lineTrace.plane.normal.z, 0.9)
            XCTAssertEqual(lineTrace.fraction, 0.111_321_345, accuracy: 0.000_000_1)
            XCTAssertEqual(lineTrace.endPosition.z, spawn.z - 0.968_75, accuracy: 0.001)

            let hullTrace = try bsp.traceWorld(
                SourceRay(
                    start: start,
                    end: end,
                    mins: SourceVector3(-16, -16, 0),
                    maxs: SourceVector3(16, 16, 72)
                ),
                mask: SourceMasks.playerSolidBrushOnly
            )
            XCTAssertTrue(hullTrace.didHit, "\(expected.map.rawValue) hull missed its spawn floor")
            XCTAssertTrue(hullTrace.didHitWorld)
            XCTAssertFalse(hullTrace.startSolid)
            XCTAssertGreaterThanOrEqual(hullTrace.fraction, 0)
            XCTAssertLessThan(hullTrace.fraction, 1)
            XCTAssertGreaterThan(hullTrace.plane.normal.z, 0.9)
            XCTAssertEqual(hullTrace.fraction, lineTrace.fraction, accuracy: 0.000_000_1)
            XCTAssertEqual(hullTrace.endPosition.z, lineTrace.endPosition.z, accuracy: 0.001)

            print(
                "Bundled map trace:",
                "map=\(expected.map.rawValue)",
                "spawn=\(spawn.x),\(spawn.y),\(spawn.z)",
                "lineFraction=\(lineTrace.fraction)",
                "lineEndZ=\(lineTrace.endPosition.z)",
                "hullFraction=\(hullTrace.fraction)",
                "hullEndZ=\(hullTrace.endPosition.z)"
            )
        }
    }

    private func parsePlayerStarts(_ text: String) throws -> [SourceVector3] {
        let pairExpression = try NSRegularExpression(
            pattern: #"\"([^\"]+)\"\s+\"([^\"]*)\""#
        )
        var starts: [SourceVector3] = []
        for block in text.split(separator: "}", omittingEmptySubsequences: true) {
            let string = String(block)
            let range = NSRange(string.startIndex..<string.endIndex, in: string)
            var values: [String: String] = [:]
            for match in pairExpression.matches(in: string, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: string),
                      let valueRange = Range(match.range(at: 2), in: string) else { continue }
                values[String(string[keyRange])] = String(string[valueRange])
            }
            guard values["classname"] == "info_player_start",
                  let origin = values["origin"] else { continue }
            let components = origin.split(whereSeparator: \.isWhitespace)
            guard components.count == 3,
                  let x = Float(components[0]),
                  let y = Float(components[1]),
                  let z = Float(components[2]) else {
                XCTFail("invalid info_player_start origin: \(origin)")
                continue
            }
            starts.append(SourceVector3(x, y, z))
        }
        return starts
    }
}
