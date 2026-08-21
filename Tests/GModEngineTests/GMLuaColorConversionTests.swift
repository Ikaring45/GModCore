import XCTest
@testable import GModEngine
import GModGameAssets

final class GMLuaColorConversionTests: XCTestCase {
    func testColorToHSVPrimariesAchromaticWrapRangeAndBundledRoundTrip() throws {
        let fileSystem = try GMLuaHostDirectoryFileSystem(
            rootURL: GModGameAssets.clientContentRootURL(),
            writable: false
        )
        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            virtualFileSystem: fileSystem,
            bootstrapMode: .strict
        )
        defer { _ = runtime.close() }

        try runtime.loadFile("lua/includes/extensions/math.lua")
        try runtime.loadFile("lua/includes/util/color.lua")
        try runtime.execute(
            """
            local function near(actual, expected)
                assert(math.abs(actual - expected) < 0.000000001,
                    tostring(actual) .. " != " .. tostring(expected))
            end

            local primaries = {
                { Color(255, 0, 0), 0 },
                { Color(255, 255, 0), 60 },
                { Color(0, 255, 0), 120 },
                { Color(0, 255, 255), 180 },
                { Color(0, 0, 255), 240 },
                { Color(255, 0, 255), 300 }
            }
            for _, probe in ipairs(primaries) do
                local h, s, v = ColorToHSV(probe[1])
                near(h, probe[2])
                near(s, 1)
                near(v, 1)
            end

            local blackH, blackS, blackV = ColorToHSV(Color(0, 0, 0))
            near(blackH, 0)
            near(blackS, 0)
            near(blackV, 0)

            local grayH, grayS, grayV = ColorToHSV(Color(128, 128, 128))
            near(grayH, 0)
            near(grayS, 0)
            near(grayV, 128 / 255)

            local wrappedH, wrappedS, wrappedV = ColorToHSV(Color(255, 0, 1))
            assert(wrappedH > 359 and wrappedH < 360)
            assert(wrappedS >= 0 and wrappedS <= 1)
            assert(wrappedV >= 0 and wrappedV <= 1)

            -- The documented argument is a table. It need not carry the Lua
            -- Color metatable when its numeric channels satisfy the contract.
            local tableH, tableS, tableV = ColorToHSV({ r = 255, g = 128, b = 0 })
            assert(tableH >= 0 and tableH < 360)
            assert(tableS >= 0 and tableS <= 1)
            assert(tableV >= 0 and tableV <= 1)

            local roundTrips = {
                Color(12, 34, 56), Color(253, 117, 9), Color(1, 254, 128),
                Color(255, 255, 255), Color(0, 0, 0)
            }
            for _, original in ipairs(roundTrips) do
                local h, s, v = ColorToHSV(original)
                local decoded = HSVToColor(h, s, v)
                assert(math.abs(decoded.r - original.r) <= 1)
                assert(math.abs(decoded.g - original.g) <= 1)
                assert(math.abs(decoded.b - original.b) <= 1)
            end

            local okNil, nilError = pcall(ColorToHSV, nil)
            assert(not okNil and string.find(nilError, "table expected, got nil", 1, true))
            assert(not pcall(ColorToHSV, "white"))
            assert(not pcall(ColorToHSV, { r = 0, g = 0 }))
            assert(not pcall(ColorToHSV, { r = "0", g = 0, b = 0 }))
            assert(not pcall(ColorToHSV, { r = -1, g = 0, b = 0 }))
            assert(not pcall(ColorToHSV, { r = 256, g = 0, b = 0 }))
            assert(not pcall(ColorToHSV, { r = 0 / 0, g = 0, b = 0 }))
            """,
            sourceName: "@GMLuaColorToHSVOfficialShapeRegression.lua"
        )
    }
}
