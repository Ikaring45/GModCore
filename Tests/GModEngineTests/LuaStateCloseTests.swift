import GModLua
import XCTest

final class LuaStateCloseTests: XCTestCase {
    func testCloseFinalizesReachableUserdataInReverseOrderAndIsIdempotent() throws {
        let state = LuaState(output: { _ in })
        var events: [String] = []
        state.register("record") { arguments in
            events.append(arguments.first?.printable ?? "nil")
            return []
        }

        try state.execute(
            """
            labels = {}
            local prototype = newproxy(true)
            labels[prototype] = "1"
            getmetatable(prototype).__gc = function(object)
              record(labels[object])
            end
            held1 = prototype
            held2 = newproxy(prototype); labels[held2] = "2"
            held3 = newproxy(prototype); labels[held3] = "3"
            """,
            sourceName: "=(close reverse-order test)"
        )

        let first = state.close()
        XCTAssertEqual(events, ["3", "2", "1"])
        XCTAssertTrue(first.errorMessages.isEmpty)
        XCTAssertGreaterThanOrEqual(first.finalizedUserdataCount, 3)
        XCTAssertTrue(state.isClosed)

        let second = state.close()
        XCTAssertEqual(second, first)
        XCTAssertEqual(events, ["3", "2", "1"])
        XCTAssertThrowsError(try state.execute("return 1"))
    }

    func testCloseContinuesAfterMultipleFinalizerErrors() throws {
        let state = LuaState(output: { _ in })
        var events: [String] = []
        state.register("record") { arguments in
            events.append(arguments.first?.printable ?? "nil")
            return []
        }

        try state.execute(
            """
            local function install(label)
              local object = newproxy(true)
              getmetatable(object).__gc = function()
                record(label)
                error(label)
              end
              _G[label] = object
            end
            install("first")
            install("second")
            """,
            sourceName: "=(close error-continuation test)"
        )

        let report = state.close()
        XCTAssertEqual(events, ["second", "first"])
        XCTAssertEqual(report.errorMessages.count, 2)
        XCTAssertTrue(report.errorMessages[0].contains("second"))
        XCTAssertTrue(report.errorMessages[1].contains("first"))
    }

    func testCloseHandlesResurrectionAndDefersFinalizerCreatedUserdata() throws {
        let state = LuaState(output: { _ in })
        var events: [String] = []
        state.register("record") { _ in
            events.append("gc")
            return []
        }

        try state.execute(
            """
            local prototype = newproxy(true)
            getmetatable(prototype).__gc = function(object)
              record()
              resurrected = object
              newproxy(object)
            end
            globally_reachable = prototype
            """,
            sourceName: "=(close resurrection test)"
        )

        let report = state.close()
        XCTAssertEqual(events, ["gc"])
        XCTAssertEqual(report.additionalPasses, 0)
        XCTAssertEqual(report.deferredNewFinalizerCount, 1)
        XCTAssertTrue(report.errorMessages.isEmpty)
        if case .nilValue = state.getGlobal("globally_reachable") {
            // Expected: close tears down roots after finalization.
        } else {
            XCTFail("closed state retained its global table")
        }
    }
}
