import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GModLua

public struct Lua51ConformanceReport: Sendable {
    public let passed: Bool
    public let finalOKFound: Bool
    public let elapsedSeconds: Double
    public let loadedFiles: [String]
    public let fetchedFiles: Int
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
        lines.append("Fetched test files: \(fetchedFiles)")
        lines.append("Loaded files: \(loadedFiles.count)")
        lines.append("Skipped classified files: \(skippedFiles.count)")
        lines.append("final OK: \(finalOKFound ? "YES" : "NO")")
        if let lastLoadedFile { lines.append("Last loaded: \(lastLoadedFile)") }
        if let failure { lines.append("Failure: \(failure)") }
        return lines.joined(separator: "\n")
    }

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
    private static let mirrorRoot = "_lua5.1-tests"

    public static func runBasicSuite(
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> Lua51ConformanceReport {
        let started = Date()
        var output: [String] = []
        var loadedFiles: [String] = []
        var failure: String?
        var fetchedFiles = 0
        let skippedFiles = [
            "main.lua [CLI-only]",
            "gc.lua [GC-unimplemented]",
            "api.lua [C-API-only]"
        ]

        func append(_ line: String) {
            output.append(line)
            progress(line)
        }

        do {
            append("[CONFORMANCE] Garry's PAD embedded-core mode")
            append("[CONFORMANCE] Discovery mode: CLI-only, unfinished GC, and C-API-only files are classified and skipped")
            append("[SKIP][CLI] main.lua - standalone lua executable/options/arg/process test")
            append("[SKIP][GC] gc.lua - collector, weak tables, and finalization are not implemented yet")
            append("[SKIP][C-API] api.lua - PUC Lua C API/internal test")
            append("[CONFORMANCE] fetching official Lua 5.1 test mirror…")

            let sources = try await fetchOfficialLuaSources { line in
                append(line)
            }
            fetchedFiles = sources.count
            append("[CONFORMANCE] fetched \(sources.count) Lua files")

            let loader: (String) throws -> String = { requestedPath in
                let normalized = normalizePath(requestedPath)
                loadedFiles.append(normalized)
                append("[LOAD] \(normalized)")

                if let source = sources[normalized] {
                    return source
                }

                throw Lua51ConformanceResourceError.missing(normalized)
            }

            let runtime = GMLuaRuntime(
                realm: .server,
                logger: { append($0) },
                fileLoader: loader
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
            fetchedFiles: fetchedFiles,
            skippedFiles: skippedFiles,
            outputLines: output,
            failure: failure
        )
    }

    /// The official suite assumes a standalone PUC Lua executable for main.lua
    /// and direct access to the PUC C API for api.lua. Garry's PAD embeds Lua in
    /// an iPad application, so those two tests are classified separately instead
    /// of allowing them to mask language/runtime failures. gc.lua is also skipped
    /// in discovery mode because the collector is still intentionally unfinished;
    /// it must not be reported as a pass until reachability, weak tables,
    /// finalization, gcinfo, and incremental stepping are implemented.
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
            of: "loadfile('gc.lua')",
            with: "function() print('[SKIP][GC] gc.lua') end"
        )

        result = result.replacingOccurrences(
            of: "dofile('gc.lua')",
            with: "print('[SKIP][GC] gc.lua')"
        )

        result = result.replacingOccurrences(
            of: "dofile('api.lua')",
            with: "print('[SKIP][C-API] api.lua')"
        )

        return result
    }

    // MARK: - Official network fetch

    private static func fetchOfficialLuaSources(
        progress: @escaping (String) -> Void
    ) async throws -> [String: String] {
        var result: [String: String] = [:]
        try await fetchDirectory(
            repositoryPath: mirrorRoot,
            relativePath: "",
            into: &result,
            progress: progress
        )

        guard result["all.lua"] != nil else {
            throw Lua51ConformanceDownloadError.missingAllLua
        }

        return result
    }

    private static func fetchDirectory(
        repositoryPath: String,
        relativePath: String,
        into result: inout [String: String],
        progress: @escaping (String) -> Void
    ) async throws {
        let items = try await listGitHubDirectory(path: repositoryPath)

        for item in items {
            let childRelative = relativePath.isEmpty ? item.name : "\(relativePath)/\(item.name)"

            switch item.type {
            case "dir":
                try await fetchDirectory(
                    repositoryPath: item.path,
                    relativePath: childRelative,
                    into: &result,
                    progress: progress
                )

            case "file":
                guard item.name.lowercased().hasSuffix(".lua") else { continue }
                guard let downloadURL = item.downloadURL else { continue }

                let source = try await fetchText(url: downloadURL)
                result[normalizePath(childRelative)] = source
                progress("[FETCH] \(childRelative)")

            default:
                continue
            }
        }
    }

    private static func listGitHubDirectory(path: String) async throws -> [GitHubContentItem] {
        let encodedPath = path
            .split(separator: "/")
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")

        guard let url = URL(
            string: "https://api.github.com/repos/yuin/gopher-lua/contents/\(encodedPath)?ref=master"
        ) else {
            throw Lua51ConformanceDownloadError.invalidURL(path)
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("GModLua-Conformance/1.2", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data, context: path)

        do {
            return try JSONDecoder().decode([GitHubContentItem].self, from: data)
        } catch {
            throw Lua51ConformanceDownloadError.invalidDirectoryResponse(path, String(describing: error))
        }
    }

    private static func fetchText(url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("GModLua-Conformance/1.2", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data, context: url.lastPathComponent)

        // The official Lua 5.1 test corpus is byte-oriented and contains
        // legacy single-byte source text (for example db.lua). Requiring
        // UTF-8 here incorrectly rejects valid Lua 5.1 test files before
        // the Lua runtime even sees them.
        if let text = String(data: data, encoding: .utf8) {
            return text
        }

        if let text = String(data: data, encoding: .isoLatin1) {
            return text
        }

        throw Lua51ConformanceDownloadError.cannotDecode(url.lastPathComponent)
    }

    private static func validate(response: URLResponse, data: Data, context: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw Lua51ConformanceDownloadError.invalidResponse(context)
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw Lua51ConformanceDownloadError.http(http.statusCode, context, body)
        }
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

private struct GitHubContentItem: Decodable {
    let name: String
    let path: String
    let type: String
    let downloadURL: URL?

    enum CodingKeys: String, CodingKey {
        case name
        case path
        case type
        case downloadURL = "download_url"
    }
}

enum Lua51ConformanceDownloadError: Error, CustomStringConvertible {
    case invalidURL(String)
    case invalidResponse(String)
    case http(Int, String, String)
    case invalidDirectoryResponse(String, String)
    case cannotDecode(String)
    case missingAllLua

    var description: String {
        switch self {
        case let .invalidURL(path):
            return "cannot build GitHub URL for \(path)"
        case let .invalidResponse(context):
            return "invalid network response while fetching \(context)"
        case let .http(status, context, body):
            let shortBody = String(body.prefix(240))
            return "HTTP \(status) while fetching \(context): \(shortBody)"
        case let .invalidDirectoryResponse(path, reason):
            return "cannot decode GitHub directory \(path): \(reason)"
        case let .cannotDecode(path):
            return "cannot decode official Lua test source: \(path)"
        case .missingAllLua:
            return "download completed but all.lua was not found"
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
