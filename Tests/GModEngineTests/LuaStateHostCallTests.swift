import XCTest
import GModLua

final class LuaStateHostCallTests: XCTestCase {
    func testHostCallPreservesMultipleResultsAndCallableMetamethods() throws {
        let state = LuaState(output: { _ in })
        let values = try state.executeReturningValues(
            """
            local function arithmetic(a, b)
                return a + b, a * b, nil, "done"
            end
            local callable = setmetatable({ offset = 5 }, {
                __call = function(self, value) return self.offset + value end
            })
            return arithmetic, callable
            """,
            sourceName: "@LuaStateHostCallRegression.lua"
        )
        XCTAssertEqual(values.count, 2)

        let arithmetic = try state.call(
            values[0],
            arguments: [.number(3), .number(4)]
        )
        XCTAssertEqual(arithmetic.count, 4)
        guard case .number(7) = arithmetic[0],
              case .number(12) = arithmetic[1],
              case .nilValue = arithmetic[2],
              case let .string(done) = arithmetic[3] else {
            return XCTFail("host call did not preserve all Lua results")
        }
        XCTAssertEqual(done.utf8String, "done")

        let callable = try state.call(values[1], arguments: [.number(9)])
        guard case .number(14) = callable.first else {
            return XCTFail("host call did not honor __call")
        }
    }

    func testHostCallPropagatesLuaErrorsAndRejectsClosedState() throws {
        let state = LuaState(output: { _ in })
        let function = try XCTUnwrap(
            try state.executeReturningValues(
                "return function() error('host-call-failure') end",
                sourceName: "@LuaStateHostCallError.lua"
            ).first
        )

        XCTAssertThrowsError(try state.call(function)) { error in
            guard let raised = error as? LuaRaisedError else {
                return XCTFail("Lua error object was not propagated")
            }
            XCTAssertTrue(raised.value.printable.contains("host-call-failure"))
        }
        _ = state.close()
        XCTAssertThrowsError(try state.call(function)) { error in
            XCTAssertTrue(String(describing: error).contains("closed"))
        }
    }
}
