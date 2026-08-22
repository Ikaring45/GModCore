import XCTest
import GModLua

final class LuaSourceChunkCacheTests: XCTestCase {
    func testParsedSyntaxIsSharedButRealmStateAndClosuresRemainIsolated() throws {
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let source = """
        -- cache-test-\(nonce)
        realm_value = (realm_value or 0) + 1
        local captured = realm_value
        return function() return captured end, realm_value
        """

        let server = LuaState(output: { _ in })
        let serverValues = try server.executeReturningValues(
            source,
            sourceName: "@server/cache_test.lua"
        )
        XCTAssertEqual(server.sourceChunkCacheMissCount, 1)
        XCTAssertEqual(server.sourceChunkCacheHitCount, 0)

        let client = LuaState(output: { _ in })
        let clientValues = try client.executeReturningValues(
            source,
            sourceName: "@client/cache_test.lua"
        )
        XCTAssertEqual(client.sourceChunkCacheMissCount, 0)
        XCTAssertEqual(client.sourceChunkCacheHitCount, 1)

        assertNumber(serverValues.dropFirst().first, equals: 1)
        assertNumber(clientValues.dropFirst().first, equals: 1)
        assertNumber(server.getGlobal("realm_value"), equals: 1)
        assertNumber(client.getGlobal("realm_value"), equals: 1)
        assertNumber(try server.call(serverValues[0]).first, equals: 1)
        assertNumber(try client.call(clientValues[0]).first, equals: 1)

        server.setGlobal("realm_value", value: .number(99))
        assertNumber(client.getGlobal("realm_value"), equals: 1)
    }

    func testSyntaxFailuresAreNeverCachedAcrossStates() {
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let source = "-- cache-failure-\(nonce)\nlocal ="

        let first = LuaState(output: { _ in })
        XCTAssertThrowsError(try first.execute(source, sourceName: "@first.lua"))
        XCTAssertEqual(first.sourceChunkCacheMissCount, 1)
        XCTAssertEqual(first.sourceChunkCacheHitCount, 0)

        let second = LuaState(output: { _ in })
        XCTAssertThrowsError(try second.execute(source, sourceName: "@second.lua"))
        XCTAssertEqual(second.sourceChunkCacheMissCount, 1)
        XCTAssertEqual(second.sourceChunkCacheHitCount, 0)
    }

    private func assertNumber(
        _ value: LuaValue?,
        equals expected: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .number(actual)? = value else {
            return XCTFail("expected Lua number", file: file, line: line)
        }
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
}
