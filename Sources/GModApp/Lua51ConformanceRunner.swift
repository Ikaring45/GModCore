import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GModEngine

struct Lua51ConformanceReport: Sendable {
    let passed: Bool
    let finalOKFound: Bool
    let elapsedSeconds: Double
    let loadedFiles: [String]
    let fetchedFiles: Int
    let outputLines: [String]
    let failure: String?

    var lastLoadedFile: String? { loadedFiles.last }

    var summaryText: String {
        var lines: [String] = []
        lines.append("Lua 5.1 Official Basic Conformance")
        lines.append("Mode: _U=true")
        lines.append("Result: \(passed ? "PASS" : "FAIL")")
        lines.append(String(format: "Elapsed: %.2fs", elapsedSeconds))
        lines.append("Fetched test files: \(fetchedFiles)")
        lines.append("Loaded files: \(loadedFiles.count)")
        lines.append("final OK: \(finalOKFound ? "YES" : "NO")")
        if let lastLoadedFile { lines.append("Last loaded: \(lastLoadedFile)") }
        if let failure { lines.append("Failure: \(failure)") }
        return lines.joined(separator: "\n")
    }

    var fullText: String {
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

enum Lua51ConformanceRunner {
    private static let mirrorRoot = "_lua5.1-tests"

    static func runBasicSuite(
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> Lua51ConformanceReport {
        let started = Date()
        var output: [String] = []
        var loadedFiles: [String] = []
        var failure: String?
        var fetchedFiles = 0

        func append(_ line: String) {
            output.append(line)
            progress(line)
        }

        do {
            append("[CONFORMANCE] iPad-only mode")
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

                if let bundled = try? sourceForBundledOfficialTest(path: normalized) {
                    return bundled
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
            fetchedFiles: fetchedFiles,
            outputLines: output,
            failure: failure
        )
    }

    // MARK: - iPad-only network fetch

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
        request.setValue("GModLua-iPad-Conformance/1.0", forHTTPHeaderField: "User-Agent")
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
        request.setValue("GModLua-iPad-Conformance/1.1", forHTTPHeaderField: "User-Agent")

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

    // MARK: - Resource fallback

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

    private static func sourceForBundledOfficialTest(path: String) throws -> String {
        let nsPath = path as NSString
        let last = nsPath.lastPathComponent as NSString
        let directory = nsPath.deletingLastPathComponent
        let ext = last.pathExtension
        let name = last.deletingPathExtension

        let subdirectory = directory.isEmpty || directory == "."
            ? "Lua51Tests"
            : "Lua51Tests/\(directory)"

        let fileExtension: String? = ext.isEmpty ? nil : ext
        let url = Bundle.module.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: subdirectory
        ) ?? Bundle.module.url(
            forResource: name,
            withExtension: fileExtension
        )

        guard let url else { throw Lua51ConformanceResourceError.missing(path) }
        do {
            let data = try Data(contentsOf: url)
            if let text = String(data: data, encoding: .utf8) {
                return text
            }
            if let text = String(data: data, encoding: .isoLatin1) {
                return text
            }
            throw Lua51ConformanceResourceError.unreadable(path, "unsupported source encoding")
        } catch let error as Lua51ConformanceResourceError {
            throw error
        } catch {
            throw Lua51ConformanceResourceError.unreadable(path, String(describing: error))
        }
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
