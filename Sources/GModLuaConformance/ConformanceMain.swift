import Foundation
import GModEngine

#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main
enum GModLuaConformanceMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if (arguments.first == "--file" || arguments.first == "--trace-file"), arguments.count == 2 {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
                guard let source = GMLuaRuntime.decodeSource(data) else {
                    throw ConformanceCLIError.cannotDecode(arguments[1])
                }
                let runtime = GMLuaRuntime(realm: .server) { print($0) }
                if arguments.first == "--trace-file" {
                    try runtime.execute(
                        """
                        local original_assert = assert
                        function assert(value, ...)
                          if not value then print(debug.traceback("ASSERT TRACE", 2)) end
                          return original_assert(value, ...)
                        end
                        """,
                        sourceName: "=(trace bootstrap)"
                    )
                }
                try runtime.execute(source, sourceName: "@\(arguments[1])")
            } catch {
                print("[FILE][FAIL] \(GMLuaRuntime.describe(error))")
                terminate(1)
            }
            return
        }

        if arguments.first == "--eval" {
            let source = arguments.dropFirst().joined(separator: " ")
            guard !source.isEmpty else {
                print("usage: GModLuaConformance --eval <lua source>")
                terminate(2)
                return
            }

            let runtime = GMLuaRuntime(realm: .server) { print($0) }
            do {
                try runtime.execute(source, sourceName: "=(command line)")
            } catch {
                print("[EVAL][FAIL] \(GMLuaRuntime.describe(error))")
                terminate(1)
            }
            return
        }

        if arguments.first == "--eval-name", arguments.count >= 3 {
            let sourceName = arguments[1]
            let source = arguments.dropFirst(2).joined(separator: " ")
            let runtime = GMLuaRuntime(realm: .server) { print($0) }
            do {
                try runtime.execute(source, sourceName: sourceName)
            } catch {
                print("[EVAL][FAIL] \(GMLuaRuntime.describe(error))")
                terminate(1)
            }
            return
        }

        let report = await Lua51ConformanceRunner.runBasicSuite { line in
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
        }

        print("")
        print("========== Lua 5.1 Official Conformance ==========")
        print(report.summaryText)

        guard report.passed else {
            terminate(1)
            return
        }
    }

    private static func terminate(_ code: Int32) {
        #if os(Windows)
        ExitProcess(UINT(code))
        #else
        exit(code)
        #endif
    }
}

private enum ConformanceCLIError: Error {
    case cannotDecode(String)
}
