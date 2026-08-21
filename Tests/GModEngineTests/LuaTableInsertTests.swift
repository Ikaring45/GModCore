import XCTest
import GModLua

final class LuaTableInsertTests: XCTestCase {
    func testGLuaTableInsertReturnsActualOneBasedIndex() throws {
        let state = LuaState(output: { _ in })

        let values = try state.executeReturningValues(
            """
            local entries = { "b", "d" }
            local appended = table.insert(entries, "e")
            local inserted = table.insert(entries, 2, "c")
            local leading = table.insert(entries, 1, "a")

            assert(select("#", table.insert(entries, "f")) == 1)
            assert(table.concat(entries, ",") == "a,b,c,d,e,f")
            return appended, inserted, leading
            """,
            sourceName: "@GLuaTableInsertReturnContract.lua"
        )

        XCTAssertEqual(values.count, 3)
        guard values.count == 3,
              case let .number(appended) = values[0],
              case let .number(inserted) = values[1],
              case let .number(leading) = values[2] else {
            return XCTFail("table.insert did not return three numeric indices")
        }
        XCTAssertEqual(appended, 3)
        XCTAssertEqual(inserted, 2)
        XCTAssertEqual(leading, 1)
    }
}
