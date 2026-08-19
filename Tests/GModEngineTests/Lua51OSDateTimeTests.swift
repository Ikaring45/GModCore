import Foundation
@testable import GModLua
import XCTest

final class Lua51OSDateTimeTests: XCTestCase {
    func testUTCDateTableMatchesGregorianLeapAndYearBoundaries() throws {
        let state = LuaState(output: { _ in })
        setTimestamp(year: 2019, month: 1, day: 1, named: "UTC_2019_START", utc: true, in: state)
        setTimestamp(year: 2019, month: 12, day: 31, named: "UTC_2019_END", utc: true, in: state)
        setTimestamp(year: 2020, month: 2, day: 29, named: "UTC_2020_LEAP", utc: true, in: state)
        setTimestamp(year: 2020, month: 12, day: 31, named: "UTC_2020_END", utc: true, in: state)
        setTimestamp(year: 2021, month: 1, day: 1, named: "UTC_2021_START", utc: true, in: state)

        try state.execute(
            #"""
            local function check(timestamp, year, month, day, wday, yday)
                local value = os.date("!*t", timestamp)
                assert(value.year == year)
                assert(value.month == month)
                assert(value.day == day)
                assert(value.hour == 12 and value.min == 0 and value.sec == 0)
                assert(value.wday == wday)
                assert(value.yday == yday)
                assert(type(value.isdst) == "boolean" and value.isdst == false)
                assert(tonumber(os.date("!%w", timestamp)) + 1 == wday)
                assert(tonumber(os.date("!%j", timestamp)) == yday)
            end

            check(UTC_2019_START, 2019, 1, 1, 3, 1)
            check(UTC_2019_END, 2019, 12, 31, 3, 365)
            check(UTC_2020_LEAP, 2020, 2, 29, 7, 60)
            check(UTC_2020_END, 2020, 12, 31, 5, 366)
            check(UTC_2021_START, 2021, 1, 1, 6, 1)
            """#,
            sourceName: "@Lua51UTCDateTable.lua"
        )
    }

    func testLocalDateTableMatchesGregorianBoundariesAndRoundTrips() throws {
        let state = LuaState(output: { _ in })
        setTimestamp(year: 2019, month: 12, day: 31, named: "LOCAL_2019_END", utc: false, in: state)
        setTimestamp(year: 2020, month: 2, day: 29, named: "LOCAL_2020_LEAP", utc: false, in: state)
        setTimestamp(year: 2020, month: 12, day: 31, named: "LOCAL_2020_END", utc: false, in: state)
        setTimestamp(year: 2021, month: 1, day: 1, named: "LOCAL_2021_START", utc: false, in: state)

        try state.execute(
            #"""
            local function check(timestamp, year, month, day, wday, yday)
                local value = os.date("*t", timestamp)
                assert(value.year == year)
                assert(value.month == month)
                assert(value.day == day)
                assert(value.hour == 12 and value.min == 0 and value.sec == 0)
                assert(value.wday == wday)
                assert(value.yday == yday)
                assert(type(value.isdst) == "boolean")
                assert(os.time(value) == timestamp)

                local with_inferred_dst = {
                    year = value.year,
                    month = value.month,
                    day = value.day,
                    hour = value.hour,
                    min = value.min,
                    sec = value.sec
                }
                assert(os.time(with_inferred_dst) == timestamp)
            end

            check(LOCAL_2019_END, 2019, 12, 31, 3, 365)
            check(LOCAL_2020_LEAP, 2020, 2, 29, 7, 60)
            check(LOCAL_2020_END, 2020, 12, 31, 5, 366)
            check(LOCAL_2021_START, 2021, 1, 1, 6, 1)
            assert(os.time{year = 2020, month = 2, day = 29} == LOCAL_2020_LEAP)
            """#,
            sourceName: "@Lua51LocalDateTable.lua"
        )
    }

    func testCurrentTimeUsesWholeSecondsAndRoundTripsThroughLocalTable() throws {
        let state = LuaState(output: { _ in })

        try state.execute(
            #"""
            local timestamp = os.time()
            assert(timestamp == math.floor(timestamp))
            local value = os.date("*t", timestamp)
            assert(type(value.yday) == "number")
            assert(type(value.wday) == "number")
            assert(type(value.isdst) == "boolean")
            assert(os.time(value) == timestamp)

            value.isdst = nil
            assert(os.time(value) == timestamp)
            """#,
            sourceName: "@Lua51CurrentTimeRoundTrip.lua"
        )
    }

    func testTimeReadsFieldsThroughIndexAndUsesLua51Defaults() throws {
        let state = LuaState(output: { _ in })
        setTimestamp(year: 2020, month: 2, day: 29, named: "LOCAL_2020_NOON", utc: false, in: state)
        let forcedStandard = state.luaOSLocalDate(
            from: dateComponents(year: 2020, month: 2, day: 29, hour: 12),
            requestedDaylightSavingTime: false
        )!
        state.setGlobal(
            "LOCAL_2020_FORCED_STANDARD",
            value: .number(forcedStandard.timeIntervalSince1970)
        )

        try state.execute(
            #"""
            local values = {year = 2020, month = 2, day = 29, isdst = false}
            local reads = {}
            local order = {}
            local inherited = setmetatable({}, {
                __index = function(_, key)
                    reads[key] = (reads[key] or 0) + 1
                    order[#order + 1] = key
                    return values[key]
                end
            })
            assert(os.time(inherited) == LOCAL_2020_FORCED_STANDARD)
            assert(reads.year == 1 and reads.month == 1 and reads.day == 1)
            assert(reads.hour == 1 and reads.min == 1 and reads.sec == 1)
            assert(reads.isdst == 1)
            assert(table.concat(order, ",") == "sec,min,hour,day,month,year,isdst")

            local inherited_table = setmetatable({}, {__index = values})
            assert(os.time(inherited_table) == LOCAL_2020_FORCED_STANDARD)

            local nonnumeric_optional = {
                year = "2020",
                month = "2",
                day = "29",
                hour = false,
                min = {},
                sec = function() end
            }
            assert(os.time(nonnumeric_optional) == LOCAL_2020_NOON)
            """#,
            sourceName: "@Lua51TimeMetatableAndDefaults.lua"
        )
    }

    func testTimeRejectsMissingOrNonnumericMandatoryFields() throws {
        let state = LuaState(output: { _ in })

        try state.execute(
            #"""
            local function expect_missing_field(value, field)
                local ok, message = pcall(os.time, value)
                assert(ok == false)
                assert(type(message) == "string")
                assert(string.find(message, "field '" .. field .. "' missing in date table", 1, true))
            end

            expect_missing_field({month = 1, day = 1}, "year")
            expect_missing_field({year = {}, month = 1, day = 1}, "year")
            expect_missing_field({year = 2020, month = false, day = 1}, "month")
            expect_missing_field({year = 2020, month = 1, day = function() end}, "day")
            """#,
            sourceName: "@Lua51TimeMandatoryFields.lua"
        )
    }

    func testExplicitDSTNormalizesOrdinaryRepeatedAndMissingWallTimes() throws {
        let state = LuaState(output: { _ in })
        let timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = timeZone

        let summer = dateComponents(year: 2020, month: 7, day: 1, hour: 12)
        let staleSummer = try XCTUnwrap(
            state.luaOSLocalDate(
                from: summer,
                requestedDaylightSavingTime: false,
                timeZone: timeZone
            )
        )
        XCTAssertEqual(staleSummer, utcDate(year: 2020, month: 7, day: 1, hour: 17))
        assertLocalDate(staleSummer, hour: 13, minute: 0, isDST: true, calendar: localCalendar)

        let winter = dateComponents(year: 2020, month: 1, day: 1, hour: 12)
        let staleWinter = try XCTUnwrap(
            state.luaOSLocalDate(
                from: winter,
                requestedDaylightSavingTime: true,
                timeZone: timeZone
            )
        )
        XCTAssertEqual(staleWinter, utcDate(year: 2020, month: 1, day: 1, hour: 16))
        assertLocalDate(staleWinter, hour: 11, minute: 0, isDST: false, calendar: localCalendar)

        let repeated = dateComponents(year: 2020, month: 11, day: 1, hour: 1, minute: 30)
        let repeatedDST = try XCTUnwrap(
            state.luaOSLocalDate(
                from: repeated,
                requestedDaylightSavingTime: true,
                timeZone: timeZone
            )
        )
        let repeatedStandard = try XCTUnwrap(
            state.luaOSLocalDate(
                from: repeated,
                requestedDaylightSavingTime: false,
                timeZone: timeZone
            )
        )
        XCTAssertEqual(repeatedDST, utcDate(year: 2020, month: 11, day: 1, hour: 5, minute: 30))
        XCTAssertEqual(repeatedStandard, utcDate(year: 2020, month: 11, day: 1, hour: 6, minute: 30))
        assertLocalDate(repeatedDST, hour: 1, minute: 30, isDST: true, calendar: localCalendar)
        assertLocalDate(repeatedStandard, hour: 1, minute: 30, isDST: false, calendar: localCalendar)

        let missing = dateComponents(year: 2020, month: 3, day: 8, hour: 2, minute: 30)
        let missingDST = try XCTUnwrap(
            state.luaOSLocalDate(
                from: missing,
                requestedDaylightSavingTime: true,
                timeZone: timeZone
            )
        )
        let missingStandard = try XCTUnwrap(
            state.luaOSLocalDate(
                from: missing,
                requestedDaylightSavingTime: false,
                timeZone: timeZone
            )
        )
        XCTAssertEqual(missingDST, utcDate(year: 2020, month: 3, day: 8, hour: 6, minute: 30))
        XCTAssertEqual(missingStandard, utcDate(year: 2020, month: 3, day: 8, hour: 7, minute: 30))
        assertLocalDate(missingDST, hour: 1, minute: 30, isDST: false, calendar: localCalendar)
        assertLocalDate(missingStandard, hour: 3, minute: 30, isDST: true, calendar: localCalendar)
    }

    private func setTimestamp(
        year: Int,
        month: Int,
        day: Int,
        named name: String,
        utc: Bool,
        in state: LuaState
    ) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc ? TimeZone(secondsFromGMT: 0)! : TimeZone.current
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        components.minute = 0
        components.second = 0
        let date = calendar.date(from: components)!
        state.setGlobal(name, value: .number(date.timeIntervalSince1970))
    }

    private func dateComponents(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int = 0
    ) -> DateComponents {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = 0
        return components
    }

    private func utcDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int = 0
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(
            from: dateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
        )!
    }

    private func assertLocalDate(
        _ date: Date,
        hour: Int,
        minute: Int,
        isDST: Bool,
        calendar: Calendar,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        XCTAssertEqual(components.hour, hour, file: file, line: line)
        XCTAssertEqual(components.minute, minute, file: file, line: line)
        XCTAssertEqual(calendar.timeZone.isDaylightSavingTime(for: date), isDST, file: file, line: line)
    }
}
