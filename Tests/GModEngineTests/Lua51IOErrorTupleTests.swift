import Foundation
import GModLua
import XCTest

final class Lua51IOErrorTupleTests: XCTestCase {
    func testVirtualIOOpenFailuresReturnLua51ErrnoTriples() throws {
        let fileSystem = try LuaMemoryFileSystem(initialFiles: [
            "regular.txt": Data("read only".utf8)
        ])
        let state = LuaState(output: { _ in }, virtualFileSystem: fileSystem)
        setExpectedErrno(.ENOENT, named: "EXPECTED_ENOENT", in: state)
        setExpectedErrno(.EINVAL, named: "EXPECTED_EINVAL", in: state)
        setExpectedErrno(.ENOTDIR, named: "EXPECTED_ENOTDIR", in: state)

        try state.execute(
            #"""
            local function check(path, mode, expected)
                assert(select("#", io.open(path, mode)) == 3)
                local handle, message, errno = io.open(path, mode)
                assert(handle == nil)
                assert(type(message) == "string" and #message > 0)
                assert(errno == expected)
            end

            check("missing.txt", "r", EXPECTED_ENOENT)
            check("/outside/sandbox.txt", "w", EXPECTED_EINVAL)
            check("regular.txt/child.txt", "w", EXPECTED_ENOTDIR)
            check("unused.txt", "invalid", EXPECTED_EINVAL)
            """#,
            sourceName: "@Lua51VirtualIOOpenFailureTuples.lua"
        )
    }

    func testHostIOOpenPreservesUnderlyingMissingFileErrno() throws {
        let missingName = "lua51-io-missing-\(UUID().uuidString).tmp"
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingName))
        let state = LuaState(output: { _ in })
        setExpectedErrno(.ENOENT, named: "EXPECTED_ENOENT", in: state)

        try state.execute(
            """
            local handle, message, errno = io.open(\"\(missingName)\", \"r\")
            assert(handle == nil)
            assert(type(message) == \"string\" and #message > 0)
            assert(errno == EXPECTED_ENOENT, tostring(errno))
            """,
            sourceName: "@Lua51HostIOOpenFailureTuple.lua"
        )
    }

    func testFileWriteFailureKeepsLua51ErrnoTriple() throws {
        let fileSystem = try LuaMemoryFileSystem(initialFiles: [
            "input.txt": Data("input".utf8)
        ])
        let state = LuaState(output: { _ in }, virtualFileSystem: fileSystem)
        setExpectedErrno(.EBADF, named: "EXPECTED_EBADF", in: state)

        try state.execute(
            #"""
            local input = assert(io.open("input.txt", "r"))
            assert(select("#", input:write("x")) == 3)
            local ok, message, errno = input:write("x")
            assert(ok == nil)
            assert(type(message) == "string" and #message > 0)
            assert(errno == EXPECTED_EBADF)
            """#,
            sourceName: "@Lua51FileWriteFailureTuple.lua"
        )
    }

    func testDirectoryNotEmptyUsesTargetNativePOSIXValue() throws {
        let state = LuaState(
            output: { _ in },
            virtualFileSystem: DirectoryNotEmptyOpenFileSystem()
        )
        setExpectedErrno(.ENOTEMPTY, named: "EXPECTED_ENOTEMPTY", in: state)

        try state.execute(
            #"""
            local handle, message, errno = io.open("non-empty", "r")
            assert(handle == nil)
            assert(type(message) == "string" and #message > 0)
            assert(errno == EXPECTED_ENOTEMPTY, tostring(errno))
            """#,
            sourceName: "@Lua51DirectoryNotEmptyErrno.lua"
        )
    }

    private func setExpectedErrno(
        _ code: POSIXErrorCode,
        named name: String,
        in state: LuaState
    ) {
        state.setGlobal(name, value: .number(Double(code.rawValue)))
    }
}

private final class DirectoryNotEmptyOpenFileSystem: LuaVirtualFileSystem {
    func fileExists(at path: String) -> Bool { true }
    func directoryExists(at path: String) -> Bool { false }

    func listDirectory(at path: String) throws -> [LuaVirtualFileSystemEntry] {
        throw LuaVirtualFileSystemError.directoryNotEmpty(path)
    }

    func readFile(at path: String) throws -> Data {
        throw LuaVirtualFileSystemError.directoryNotEmpty(path)
    }

    func writeFile(_ data: Data, at path: String) throws {
        throw LuaVirtualFileSystemError.directoryNotEmpty(path)
    }

    func removeFile(at path: String) throws {
        throw LuaVirtualFileSystemError.directoryNotEmpty(path)
    }

    func moveFile(from sourcePath: String, to destinationPath: String) throws {
        throw LuaVirtualFileSystemError.directoryNotEmpty(sourcePath)
    }

    func createDirectory(at path: String) throws {
        throw LuaVirtualFileSystemError.directoryNotEmpty(path)
    }

    func removeDirectory(at path: String) throws {
        throw LuaVirtualFileSystemError.directoryNotEmpty(path)
    }

    func moveDirectory(from sourcePath: String, to destinationPath: String) throws {
        throw LuaVirtualFileSystemError.directoryNotEmpty(sourcePath)
    }
}
