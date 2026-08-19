import Foundation
import XCTest
import GModEngine
import GModLua

final class GMLuaBitLibraryTests: XCTestCase {
    func testLuaJITBitOpRegressionCorpus() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "GLuaBitLibraryRegression",
                withExtension: "lua",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(
                forResource: "GLuaBitLibraryRegression",
                withExtension: "lua"
            )
        )
        let source = try String(contentsOf: fixtureURL, encoding: .utf8)
        let state = LuaState(output: { _ in })

        try GMLuaBitLibrary.install(into: state)
        try state.execute(source, sourceName: "@GLuaBitLibraryRegression.lua")
    }

    func testInstallerPreservesExistingBitTableIdentity() throws {
        let state = LuaState(output: { _ in })
        try state.execute("bit = { marker = 42 }; captured_bit = bit")

        try GMLuaBitLibrary.install(into: state)
        try state.execute(
            """
            assert(bit == captured_bit)
            assert(bit.marker == 42)
            assert(require("bit") == bit)
            """
        )
    }
}
