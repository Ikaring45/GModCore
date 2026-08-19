import Foundation
import XCTest
@testable import GModEngine
import GModLua

final class GMLuaIncludeExecutionContextTests: XCTestCase {
    func testDynamicRootChunkContextAcrossHelpersNestedModulesAndCallbacks() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "GLuaIncludeExecutionContextRegression",
                withExtension: "lua",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(
                forResource: "GLuaIncludeExecutionContextRegression",
                withExtension: "lua"
            )
        )
        let fixture = try String(contentsOf: fixtureURL, encoding: .utf8)
        let files = try LuaMemoryFileSystem(initialFiles: [
            "lua/helpers/context_helper.lua": data(
                """
                function ContextInclude(path)
                    return include(path)
                end
                function ContextTailInclude(path)
                    return ContextInclude(path)
                end
                """
            ),
            "lua/context/caller/main.lua": Data(fixture.utf8),
            "lua/context/caller/child.lua": data("return 'caller-child'"),
            "lua/context/caller/nested/entry.lua": data(
                "return ContextInclude('leaf.lua')"
            ),
            "lua/context/caller/nested/leaf.lua": data("return 'nested-leaf'"),
            "lua/context/caller/callback.lua": data("return 'late-callback'"),
            // These decoys make a regression choose a valid but observably
            // wrong file instead of merely failing because a file is absent.
            "lua/helpers/child.lua": data("return 'wrong-helper-child'"),
            "lua/helpers/nested/entry.lua": data("return 'wrong-helper-nested'"),
            "lua/context_module.lua": data(
                "return ContextInclude('module_child.lua')"
            ),
            "lua/module_child.lua": data("return 'required-child'"),
            "lua/context/caller/module_child.lua": data("return 'wrong-caller-module'"),
            "lua/context/loadfile/module.lua": data(
                "return ContextInclude('child.lua')"
            ),
            "lua/context/loadfile/child.lua": data("return 'loadfile-child'"),
            "lua/context/caller/tail_main.lua": data(
                "return ContextTailInclude('tail_child.lua')"
            ),
            "lua/context/caller/tail_child.lua": data("return 'tail-child'")
        ])
        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            virtualFileSystem: files,
            bootstrapMode: .strict
        )
        defer { _ = runtime.close() }

        _ = try runtime.loadFile("lua/helpers/context_helper.lua")
        _ = try runtime.loadFile("lua/context/caller/main.lua")
        guard case .boolean(true) = runtime.state.getGlobal(
            "GLUA_INCLUDE_EXECUTION_CONTEXT_OK"
        ) else {
            return XCTFail("include execution-context fixture did not finish")
        }

        // The root chunk has returned. Calling its nested closure from the host
        // proves the fallback uses the callback's defining source and that no
        // stale dynamic file context leaked from an earlier execution.
        let callback = runtime.state.getGlobal("CONTEXT_LATE_CALLBACK")
        XCTAssertEqual(
            try runtime.state.call(callback).first?.printable,
            "late-callback"
        )

        // A tail-called helper replaces the live activation with a historical
        // tail frame. Its root-chunk metadata must still carry file context.
        let tailValues = try runtime.loadFile("lua/context/caller/tail_main.lua")
        XCTAssertEqual(tailValues.first?.printable, "tail-child")

        XCTAssertEqual(runtime.includedFiles, [
            "lua/context/caller/child.lua",
            "lua/context/caller/nested/entry.lua",
            "lua/context/caller/nested/leaf.lua",
            "lua/module_child.lua",
            "lua/context/loadfile/child.lua",
            "lua/context/caller/callback.lua",
            "lua/context/caller/tail_child.lua"
        ])
    }

    private func data(_ value: String) -> Data { Data(value.utf8) }
}
