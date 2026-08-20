import Foundation
import GModLua

public struct Lua51ConformanceReport: Sendable {
    public let passed: Bool
    public let finalOKFound: Bool
    public let elapsedSeconds: Double
    public let loadedFiles: [String]
    public let availableFiles: Int
    public let skippedFiles: [String]
    public let outputLines: [String]
    public let failure: String?

    public var lastLoadedFile: String? { loadedFiles.last }

    public var summaryText: String {
        var lines: [String] = []
        lines.append("Lua 5.1 Official Basic Conformance")
        lines.append("Mode: _U=true")
        lines.append("Result: \(passed ? "PASS" : "FAIL")")
        lines.append(String(format: "Elapsed: %.2fs", elapsedSeconds))
        lines.append("Available test files: \(availableFiles)")
        lines.append("Loaded files: \(loadedFiles.count)")
        lines.append("Skipped classified files: \(skippedFiles.count)")
        lines.append("final OK: \(finalOKFound ? "YES" : "NO")")
        if let lastLoadedFile { lines.append("Last loaded: \(lastLoadedFile)") }
        if let failure { lines.append("Failure: \(failure)") }
        return lines.joined(separator: "\n")
    }

    @available(*, deprecated, renamed: "availableFiles")
    public var fetchedFiles: Int { availableFiles }

    public var fullText: String {
        let maxLines = 800
        let shown = outputLines.count > maxLines ? Array(outputLines.suffix(maxLines)) : outputLines
        let omitted = outputLines.count - shown.count
        var text = summaryText
        text += "\n\n--- official test output ---\n"
        if omitted > 0 { text += "(\(omitted) earlier lines omitted)\n" }
        text += shown.joined(separator: "\n")
        return text
    }
}

public enum Lua51ConformanceRunner {
    public static func runBasicSuite(
        sourceDirectory: URL? = nil,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> Lua51ConformanceReport {
        let started = Date()
        var output: [String] = []
        var loadedFiles: [String] = []
        var failure: String?
        var availableFiles = 0
        let skippedFiles = [
            "main.lua [CLI-only]",
            "api.lua [C-API-only]"
        ]

        func append(_ line: String) {
            output.append(line)
            progress(line)
        }

        do {
            append("[CONFORMANCE] Garry's PAD embedded-core mode")
            append("[CONFORMANCE] Embedded mode: CLI-only and C-API-only files are classified and skipped")
            append("[SKIP][CLI] main.lua - standalone lua executable/options/arg/process test")
            append("[TEST][GC] gc.lua - explicit mark/sweep, weak tables, incremental steps, and finalizers enabled")
            append("[SKIP][C-API] api.lua - PUC Lua C API/internal test")
            let sources: [String: String]
            if let sourceDirectory {
                append("[CONFORMANCE] loading official Lua 5.1 tests from \(sourceDirectory.path)")
                sources = try loadLocalLuaSources(from: sourceDirectory) { line in append(line) }
            } else {
                append("[CONFORMANCE] loading bundled official Lua 5.1 tests")
                sources = try loadBundledOfficialLuaSources { line in append(line) }
            }
            availableFiles = sources.count
            append("[CONFORMANCE] available source set contains \(sources.count) Lua files")

            let loader: (String) throws -> String = { requestedPath in
                let normalized = normalizePath(requestedPath)
                loadedFiles.append(normalized)
                append("[LOAD] \(normalized)")

                if let source = sources[normalized] {
                    return source
                }

                throw Lua51ConformanceResourceError.missing(normalized)
            }

            let writableFileSystem = try LuaMemoryFileSystem()
            let runtime = GMLuaRuntime(
                realm: .server,
                logger: { append($0) },
                fileLoader: loader,
                virtualFileSystem: writableFileSystem
            )

            let allLua = try loader("all.lua")
            let bootstrap = #"""
            _U = true
            package.path = "?;./?.lua;" .. package.path
            """#

            // Execute the bootstrap separately. The official all.lua starts
            // with a Unix shebang (#!../lua), and Lua only treats a shebang
            // specially when it is the very first line of a chunk.
            try runtime.execute(
                bootstrap,
                sourceName: "=(lua51-conformance-bootstrap)"
            )

            let embeddedAllLua = makeEmbeddedCoreAllLua(from: allLua)

            try runtime.execute(
                embeddedAllLua,
                sourceName: "@all.lua"
            )
            let closeReport = runtime.close()
            append(
                "[CONFORMANCE][CLOSE] finalized \(closeReport.finalizedUserdataCount) userdata; "
                    + "additional passes \(closeReport.additionalPasses); "
                    + "ignored finalizer errors \(closeReport.errorMessages.count)"
            )
        } catch {
            failure = describe(error)
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
            availableFiles: availableFiles,
            skippedFiles: skippedFiles,
            outputLines: output,
            failure: failure
        )
    }

    /// The official suite assumes a standalone PUC Lua executable for main.lua
    /// and direct access to the PUC C API for api.lua. Garry's PAD embeds Lua in
    /// an iPad application, so those two tests are classified separately instead
    /// of allowing them to mask language/runtime failures. gc.lua is executed in
    /// its original all.lua position and is required for an overall PASS.
    ///
    /// Everything else remains in the official all.lua order, including debug,
    /// patterns, libraries, files, closures, varargs, and events.
    private static func makeEmbeddedCoreAllLua(from source: String) -> String {
        var result = source

        result = result.replacingOccurrences(
            of: "dofile('main.lua')",
            with: "print('[SKIP][CLI] main.lua')"
        )

        result = result.replacingOccurrences(
            of: "dofile('api.lua')",
            with: "print('[SKIP][C-API] api.lua')"
        )

        return result
    }

    // MARK: - Official suite sources

    private static func loadBundledOfficialLuaSources(
        progress: (String) -> Void
    ) throws -> [String: String] {
        guard let resourceRoot = Bundle.module.resourceURL else {
            throw Lua51ConformanceResourceError.missing("bundled resource root")
        }
        let suiteRoot = resourceRoot.appendingPathComponent("Lua51Tests", isDirectory: true)
        progress("[BUNDLED] \(suiteRoot.path)")
        return try loadLocalLuaSources(from: suiteRoot, progress: progress)
    }

    private static func loadLocalLuaSources(
        from directory: URL,
        progress: (String) -> Void
    ) throws -> [String: String] {
        let root = directory.standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw Lua51ConformanceResourceError.missing(root.path)
        }

        var result: [String: String] = [:]
        for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "lua" {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
            guard fileURL.path.hasPrefix(rootPath) else { continue }
            let relative = normalizePath(String(fileURL.path.dropFirst(rootPath.count)))
            let data = try Data(contentsOf: fileURL)
            guard let source = LuaSourceDecoder.decode(data) else {
                throw Lua51ConformanceDownloadError.cannotDecode(relative)
            }
            result[relative] = source
            progress("[LOCAL] \(relative)")
        }

        guard result["all.lua"] != nil else {
            throw Lua51ConformanceDownloadError.missingAllLua
        }
        return result
    }

    // MARK: - Helpers

    private static func describe(_ error: Error) -> String {
        if let raised = error as? LuaRaisedError { return raised.value.printable }
        return String(describing: error)
    }

    private static func normalizePath(_ raw: String) -> String {
        var path = raw.replacingOccurrences(of: "\\", with: "/")
        while path.hasPrefix("./") { path.removeFirst(2) }

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

}

enum Lua51ConformanceDownloadError: Error, CustomStringConvertible {
    case cannotDecode(String)
    case missingAllLua

    var description: String {
        switch self {
        case let .cannotDecode(path):
            return "cannot decode official Lua test source: \(path)"
        case .missingAllLua:
            return "official Lua test source set does not contain all.lua"
        }
    }
}

enum Lua51ConformanceResourceError: Error, CustomStringConvertible {
    case missing(String)

    var description: String {
        switch self {
        case let .missing(path):
            return "official Lua 5.1 test resource is missing: \(path)"
        }
    }
}
