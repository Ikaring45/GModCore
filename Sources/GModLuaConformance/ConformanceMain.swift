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
        if arguments.first == "--file", arguments.count == 2 {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
                guard let source = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) else {
                    throw ConformanceCLIError.cannotDecode(arguments[1])
                }
                let runtime = GMLuaRuntime(realm: .server) { print($0) }
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

        let report = await Lua51ConformanceRunner.runBasicSuite { line in
            print(line)
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
