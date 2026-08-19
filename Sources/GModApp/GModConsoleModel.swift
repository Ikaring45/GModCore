import Foundation
import Combine
import GModEngine

@MainActor
final class GModConsoleModel: ObservableObject {
    struct Line: Identifiable, Equatable {
        enum Kind {
            case normal
            case command
            case info
            case success
            case warning
            case error
        }

        let id = UUID()
        let text: String
        let kind: Kind
    }

    @Published var lines: [Line] = [
        Line(text: "GModLua Console initialized", kind: .info),
        Line(text: "Lua 5.1 runtime ready. Type Lua directly or use lua_run <code>.", kind: .normal)
    ]
    @Published var input = ""
    @Published var removeContaining = ""

    private lazy var runtime: GMLuaRuntime = {
        GMLuaRuntime(
            realm: .server,
            logger: { [weak self] message in
                Task { @MainActor in
                    self?.append(message)
                }
            }
        )
    }()

    var visibleLines: [Line] {
        let filter = removeContaining.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filter.isEmpty else { return lines }
        return lines.filter {
            $0.text.range(of: filter, options: [.caseInsensitive]) == nil
        }
    }

    func append(_ text: String) {
        let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
        for part in parts {
            let string = String(part)
            lines.append(Line(text: string, kind: Self.kind(for: string)))
        }
        trimIfNeeded()
    }

    func appendCommand(_ text: String) {
        lines.append(Line(text: "] \(text)", kind: .command))
        trimIfNeeded()
    }

    func replaceWithReport(_ report: Lua51ConformanceReport) {
        append("")
        append("========== Lua 5.1 Official Conformance ==========")
        append(report.summaryText)
        append("---------- official test output ----------")
        for line in report.outputLines.suffix(1200) {
            append(line)
        }
    }

    func clear() {
        lines.removeAll(keepingCapacity: true)
        append("Console cleared")
    }

    func submit() {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        input = ""
        appendCommand(raw)

        if raw.caseInsensitiveCompare("clear") == .orderedSame {
            clear()
            return
        }

        let source: String
        if raw.hasPrefix("lua_run ") {
            source = String(raw.dropFirst("lua_run ".count))
        } else {
            source = raw
        }

        do {
            try runtime.execute(source, sourceName: "=Console")
        } catch {
            append("[ERROR] \(error)")
        }
    }

    private func trimIfNeeded() {
        let maximum = 4000
        if lines.count > maximum {
            lines.removeFirst(lines.count - maximum)
        }
    }

    private static func kind(for text: String) -> Line.Kind {
        let lower = text.lowercased()

        if lower.contains("[fatal]") ||
            lower.contains("[error]") ||
            lower.contains("[fail]") ||
            lower.hasPrefix("failure:") ||
            lower.contains("result: fail") {
            return .error
        }

        if lower.contains("warning") || lower.contains("[warn]") {
            return .warning
        }

        if lower.contains("[fetch]") ||
            lower.contains("[load]") ||
            lower.contains("[conformance]") {
            return .info
        }

        if lower.contains("[pass]") ||
            lower.contains("result: pass") ||
            lower.contains("final ok: yes") ||
            lower.contains("final ok !!!") {
            return .success
        }

        return .normal
    }
}
