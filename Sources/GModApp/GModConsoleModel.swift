import Foundation
import Combine
import GModEngine

@MainActor
private final class GModConsoleLogSink {
    weak var target: GModConsoleModel?

    func publish(_ message: String) {
        target?.append(message)
    }
}

@MainActor
final class GModConsoleModel: ObservableObject {
    enum Submission {
        case clear
        case commandLine(String)
        case luaSource(String)
    }
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
        Line(
            text: "Source commands use the active CLIENT; explicit Lua uses lua_run <code>.",
            kind: .normal
        )
    ]
    @Published var input = ""
    @Published var removeContaining = ""
    @Published private(set) var fontRegistrationReport: GModBundledFontRegistrationReport?

    private let runtimeFactory: GModAppRuntimeFactory
    private let clientSurfaceRuntime: GMLuaRuntime
    private let runtimeLogSink = GModConsoleLogSink()
    private lazy var runtime: GMLuaRuntime = {
        let sink = runtimeLogSink
        return runtimeFactory.makeRuntime(
            realm: .server,
            logger: { message in
                Task { @MainActor in
                    sink.publish(message)
                }
            }
        )
    }()

    init(runtimeFactory factory: GModAppRuntimeFactory = GModAppRuntimeFactory()) {
        runtimeFactory = factory
        clientSurfaceRuntime = factory.makeRuntime(
            realm: .client,
            logger: { _ in }
        )
        fontRegistrationReport = factory.fontRegistrationReport
        runtimeLogSink.target = self

        if let report = factory.fontRegistrationReport {
            let summary = "[FONT] bundled=\(report.bundledFileCount) " +
                "registered=\(report.registeredFileCount) " +
                "already=\(report.alreadyRegisteredFileCount) " +
                "failed=\(report.failures.count)"
            lines.append(
                Line(
                    text: summary,
                    kind: report.succeeded ? .success : .warning
                )
            )
            for failure in report.failures {
                lines.append(
                    Line(
                        text: "[FONT][WARN] \(failure.bundleFile): \(failure.message)",
                        kind: .warning
                    )
                )
            }
        }
        if let fidelity = clientSurfaceRuntime.surfaceCommandState?
            .textMeasurementFidelity {
            lines.append(
                Line(
                    text: "[FONT] CLIENT surface measurement=\(fidelity.rawValue)",
                    kind: .info
                )
            )
        }
    }

    var clientSurfaceMeasurementFidelity: GMLuaTextMeasurementFidelity? {
        clientSurfaceRuntime.surfaceCommandState?.textMeasurementFidelity
    }

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
        guard let submission = takeSubmission() else { return }
        switch submission {
        case .clear:
            return
        case let .commandLine(line):
            append(
                "[ERROR] No active CLIENT console for '\(line)'. " +
                    "Start or resume Sandbox, or use lua_run for the isolated Lua console."
            )
        case let .luaSource(source):
            do {
                try runtime.execute(source, sourceName: "=Console")
            } catch {
                append("[ERROR] \(error)")
            }
        }
    }

    func takeSubmission() -> Submission? {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        input = ""
        appendCommand(raw)

        if raw.caseInsensitiveCompare("clear") == .orderedSame {
            clear()
            return .clear
        }

        if raw.hasPrefix("lua_run ") {
            return .luaSource(String(raw.dropFirst("lua_run ".count)))
        }
        return .commandLine(raw)
    }

    func advanceSimulation(ticks: Int) {
        guard ticks > 0, let scheduler = runtime.timerScheduler else { return }
        do {
            for _ in 0..<ticks {
                for failure in try scheduler.advance(by: GMEngine.tickInterval) {
                    append("[ERROR][timer][\(failure.identifier)] \(failure.message)")
                }
            }
        } catch {
            append("[ERROR][timer] \(GMLuaRuntime.describe(error))")
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
