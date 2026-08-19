import Foundation
import GModEngine

struct Lua51ConformanceReport: Sendable {
    let passed: Bool
    let finalOKFound: Bool
    let elapsedSeconds: Double
    let loadedFiles: [String]
    let outputLines: [String]
    let failure: String?

    var lastLoadedFile: String? {
        loadedFiles.last
    }

    var summaryText: String {
        var lines: [String] = []
        lines.append("Lua 5.1 Official Basic Conformance")
        lines.append("Mode: _U=true")
        lines.append("Result: \(passed ? "PASS" : "FAIL")")
        lines.append(String(format: "Elapsed: %.2fs", elapsedSeconds))
        lines.append("Loaded files: \(loadedFiles.count)")
        lines.append("final OK: \(finalOKFound ? "YES" : "NO")")
        if let lastLoadedFile {
            lines.append("Last loaded: \(lastLoadedFile)")
        }
        if let failure {
            lines.append("Failure: \(failure)")
        }
        return lines.joined(separator: "\n")
    }

    var fullText: String {
        let maxLines = 800
        let shown = outputLines.count > maxLines
            ? Array(outputLines.suffix(maxLines))
            : outputLines
        let omitted = outputLines.count - shown.count
        var text = summaryText
        text += "\n\n--- official test output ---\n"
        if omitted > 0 {
            text += "(\(omitted) earlier lines omitted)\n"
        }
        text += shown.joined(separator: "\n")
        return text
    }
}

enum Lua51ConformanceRunner {
    static func runBasicSuite(
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> Lua51ConformanceReport {
        await Task.detached(priority: .userInitiated) {
            runBasicSuiteSynchronously(progress: progress)
        }.value
    }

    private static func runBasicSuiteSynchronously(
        progress: @escaping @Sendable (String) -> Void
    ) -> Lua51ConformanceReport {
        let started = Date()
        var output: [String] = []
        var loadedFiles: [String] = []
        var failure: String?

        func append(_ line: String) {
            output.append(line)
            progress(line)
        }

        let loader: (String) throws -> String = { requestedPath in
            let normalized = normalizePath(requestedPath)
            loadedFiles.append(normalized)
            append("[LOAD] \(normalized)")
            return try sourceForOfficialTest(path: normalized)
        }

        let runtime = GMLuaRuntime(
            realm: .server,
            logger: { append($0) },
            fileLoader: loader
        )

        do {
            let allLua = try loader("all.lua")
            let bootstrap = #"""
            _U = true
            package.path = "?;./?.lua;" .. package.path
            """#

            try runtime.execute(
                bootstrap + "\n" + allLua,
                sourceName: "@all.lua"
            )
        } catch {
            failure = String(describing: error)
            append("[CONFORMANCE][FAIL] \(failure!)")
        }

        let finalOK = output.contains { line in
            line.range(of: "final OK", options: [.caseInsensitive]) != nil
        }

        if failure == nil && !finalOK {
            failure = "all.lua returned without printing final OK"
            append("[CONFORMANCE][FAIL] \(failure!)")
        }

        let passed = failure == nil && finalOK
        append("[CONFORMANCE][\(passed ? "PASS" : "FAIL")] final OK = \(finalOK)")

        return Lua51ConformanceReport(
            passed: passed,
            finalOKFound: finalOK,
            elapsedSeconds: Date().timeIntervalSince(started),
            loadedFiles: loadedFiles,
            outputLines: output,
            failure: failure
        )
    }

    private static func normalizePath(_ raw: String) -> String {
        var path = raw.replacingOccurrences(of: "\\", with: "/")
        while path.hasPrefix("./") {
            path.removeFirst(2)
        }

        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                if !components.isEmpty { components.removeLast() }
                continue
            }
            components.append(component)
        }
        return components.joined(separator: "/")
    }

    private static func sourceForOfficialTest(path: String) throws -> String {
        let nsPath = path as NSString
        let last = nsPath.lastPathComponent as NSString
        let directory = nsPath.deletingLastPathComponent
        let ext = last.pathExtension
        let name = last.deletingPathExtension

        let subdirectory: String
        if directory.isEmpty || directory == "." {
            subdirectory = "Lua51Tests"
        } else {
            subdirectory = "Lua51Tests/\(directory)"
        }

        let fileExtension: String? = ext.isEmpty ? nil : ext
        let url = Bundle.module.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: subdirectory
        ) ?? Bundle.module.url(
            forResource: name,
            withExtension: fileExtension
        )

        guard let url else {
            throw Lua51ConformanceResourceError.missing(path)
        }

        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw Lua51ConformanceResourceError.unreadable(path, String(describing: error))
        }
    }
}

enum Lua51ConformanceResourceError: Error, CustomStringConvertible {
    case missing(String)
    case unreadable(String, String)

    var description: String {
        switch self {
        case let .missing(path):
            return "official Lua 5.1 test resource is missing: \(path)"
        case let .unreadable(path, reason):
            return "cannot read official Lua 5.1 test resource \(path): \(reason)"
        }
    }
}
