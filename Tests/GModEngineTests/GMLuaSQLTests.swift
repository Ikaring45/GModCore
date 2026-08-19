import Foundation
import XCTest
import GModEngine
import GModLua

final class GMLuaSQLTests: XCTestCase {
    func testStateLocalSQLiteCompatibilityRegression() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "GLuaSQLRegression",
                withExtension: "lua",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(
                forResource: "GLuaSQLRegression",
                withExtension: "lua"
            )
        )
        let source = try String(contentsOf: fixtureURL, encoding: .utf8)

        let state = LuaState(output: { _ in })
        try GMLuaSQL.install(into: state)
        try state.execute(source, sourceName: "@GLuaSQLRegression.lua")

        guard case .boolean(true) = state.getGlobal("GLUA_SQL_REGRESSION_OK") else {
            return XCTFail("SQL regression fixture did not reach its success sentinel")
        }
    }

    func testDatabasesAreIsolatedAndNotPresentedAsPersistentStorage() throws {
        let first = LuaState(output: { _ in })
        try GMLuaSQL.install(into: first)
        try first.execute(
            "assert(sql.Query([[CREATE TABLE state_only (value TEXT)]]) == nil)",
            sourceName: "@GMLuaSQLFirstState.lua"
        )

        let second = LuaState(output: { _ in })
        try GMLuaSQL.install(into: second)
        try second.execute(
            """
            assert(sql.Query([[SELECT value FROM state_only]]) == false)
            assert(type(sql.m_strError) == "string" and #sql.m_strError > 0)
            """,
            sourceName: "@GMLuaSQLSecondState.lua"
        )
    }

    func testStrictRuntimeInstallsSQLBeforeOfficialUtilityLayer() throws {
        let runtime = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            bootstrapMode: .strict
        )
        try runtime.execute(
            """
            assert(type(sql) == "table" and type(sql.Query) == "function")
            assert(sql.Query([[CREATE TABLE runtime_sql (value TEXT)]]) == nil)
            assert(sql.Query([[INSERT INTO runtime_sql VALUES ('ready')]]) == nil)
            local rows = sql.Query([[SELECT value FROM runtime_sql]])
            assert(rows[1].value == "ready")
            """,
            sourceName: "@GMLuaSQLStrictBootstrap.lua"
        )
    }

    #if os(iOS)
    func testIOSSystemSQLiteLinkAndInitializationContract() throws {
        // Linking this test is part of the contract: iOS system SQLite does
        // not export sqlite3_enable_load_extension.
        let state = LuaState(output: { _ in })
        try GMLuaSQL.install(into: state)
        try state.execute(
            """
            local rows = sql.Query([[SELECT 1 AS value]])
            assert(rows[1].value == "1")
            """,
            sourceName: "@GMLuaSQLIOSSystemSQLiteContract.lua"
        )
    }
    #endif
}
