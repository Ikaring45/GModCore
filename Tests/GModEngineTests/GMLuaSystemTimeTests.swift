import Foundation
import XCTest
@testable import GModEngine

final class GMLuaSystemTimeTests: XCTestCase {
    func testSysTimeSamplesInjectedHighResolutionSourceOnEveryCall() throws {
        let source = SequenceSystemTimeSource([12.5, 12.500_001, 13.25])
        for realm in [GMLuaRealm.server, .client, .menu] {
            source.reset()
            let runtime = GMLuaRuntime(
                realm: realm,
                logger: { _ in },
                systemTimeSource: source
            )
            let values = try runtime.executeReturningValues(
                "return SysTime(), SysTime(\"ignored\"), SysTime()",
                sourceName: "=(SysTime injected source)"
            )
            XCTAssertEqual(values.count, 3)
            for (value, expected) in zip(
                values,
                [12.5, 12.500_001, 13.25]
            ) {
                guard case let .number(actual) = value else {
                    return XCTFail("SysTime did not return a number")
                }
                XCTAssertEqual(actual, expected)
            }
            XCTAssertTrue(
                (runtime.systemTimeSource as AnyObject?) === source
            )
        }
    }

    func testSysTimeRejectsInvalidHostValuesAndDefaultClockIsMonotonic() throws {
        for invalid in [-1.0, Double.infinity, -Double.infinity, Double.nan] {
            let runtime = GMLuaRuntime(
                realm: .client,
                logger: { _ in },
                systemTimeSource: SequenceSystemTimeSource([invalid])
            )
            XCTAssertThrowsError(try runtime.execute("SysTime()")) { error in
                XCTAssertTrue(
                    GMLuaRuntime.describe(error).contains("invalid uptime")
                )
            }
        }

        let runtime = GMLuaRuntime(realm: .server, logger: { _ in })
        let values = try runtime.executeReturningValues(
            "local a = SysTime(); local b = SysTime(); return a, b, b >= a",
            sourceName: "=(SysTime monotonic source)"
        )
        guard case let .number(first) = values[0],
              case let .number(second) = values[1] else {
            return XCTFail("SysTime did not return numbers")
        }
        XCTAssertGreaterThanOrEqual(first, 0)
        XCTAssertGreaterThanOrEqual(second, first)
        guard case .boolean(true) = values[2] else {
            return XCTFail("SysTime monotonic comparison failed")
        }
    }
}

private final class SequenceSystemTimeSource: GMLuaSystemTimeSource,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let values: [Double]
    private var index = 0

    init(_ values: [Double]) {
        precondition(!values.isEmpty)
        self.values = values
    }

    func reset() {
        lock.lock()
        index = 0
        lock.unlock()
    }

    func currentSystemTime() -> Double {
        lock.lock()
        defer { lock.unlock() }
        let value = values[min(index, values.count - 1)]
        index += 1
        return value
    }
}
