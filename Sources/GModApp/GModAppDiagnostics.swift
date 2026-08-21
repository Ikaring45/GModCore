import Combine
import Foundation
import GModMetal

enum GModAppProblemKind: String, Sendable, CaseIterable {
    case vguiMissing
    case luaError
    case missingMaterial
    case missingTexture
    case rendererFallback
    case contentPack
    case audio
    case compatibility
}

enum GModAppProblemSeverity: Int, Sendable, Comparable {
    case information
    case warning
    case error

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct GModAppProblemRecord: Identifiable, Equatable, Sendable {
    let id: String
    let kind: GModAppProblemKind
    let severity: GModAppProblemSeverity
    /// A `#` prefix marks a catalog key. Runtime diagnostics remain verbatim.
    let title: String
    let detail: String
    let source: String?
    /// Named replacements for a localized title/detail template. Runtime
    /// values stay separate from translated prose so diagnostics can preserve
    /// exact dimensions and byte counts in every selected language.
    let localizationArguments: [String: String]

    init(
        id: String,
        kind: GModAppProblemKind,
        severity: GModAppProblemSeverity,
        title: String,
        detail: String,
        source: String?,
        localizationArguments: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.title = title
        self.detail = detail
        self.source = source
        self.localizationArguments = localizationArguments
    }

    func localizedTitle(using localization: GModMenuLanguageSnapshot) -> String {
        localized(title, using: localization)
    }

    func localizedDetail(using localization: GModMenuLanguageSnapshot) -> String {
        localized(detail, using: localization)
    }

    private func localized(
        _ value: String,
        using localization: GModMenuLanguageSnapshot
    ) -> String {
        var result = value.hasPrefix("#") ? localization.phrase(value) : value
        for (name, replacement) in localizationArguments.sorted(by: {
            $0.key < $1.key
        }) {
            result = result.replacingOccurrences(
                of: "{\(name)}",
                with: replacement
            )
        }
        return result
    }
}

struct GModAppLuaErrorRecord: Identifiable, Equatable, Sendable {
    let id: String
    let realm: String
    let source: String
    let line: Int?
    let message: String
    let traceback: String?
}

struct GModAppPermissionRecord: Identifiable, Equatable, Sendable {
    let id: String
    let serverIdentifier: String
    let permission: String
    let lifetime: GModPermissionLifetime
}

/// Cross-surface diagnostics that do not naturally flow through the retained
/// game console (WKWebView, AVAudioSession, and content-pack selection).
@MainActor
final class GModAppDiagnosticsStore: ObservableObject {
    static let shared = GModAppDiagnosticsStore()

    @Published private(set) var records: [GModAppProblemRecord] = []

    func record(_ record: GModAppProblemRecord) {
        guard !records.contains(where: { $0.id == record.id }) else { return }
        records.append(record)
        trimIfNeeded()
    }

    func record(
        kind: GModAppProblemKind,
        severity: GModAppProblemSeverity,
        title: String,
        detail: String,
        source: String? = nil
    ) {
        let key = "\(kind.rawValue)|\(title)|\(detail)|\(source ?? "")"
        guard !records.contains(where: { $0.id == key }) else { return }
        records.append(GModAppProblemRecord(
            id: key,
            kind: kind,
            severity: severity,
            title: title,
            detail: detail,
            source: source
        ))
        trimIfNeeded()
    }

    private func trimIfNeeded() {
        if records.count > 256 {
            records.removeFirst(records.count - 256)
        }
    }

    func clearTransientRecords() {
        records.removeAll(keepingCapacity: true)
    }
}

struct GModAppProblemSnapshot: Equatable, Sendable {
    let problems: [GModAppProblemRecord]
    let luaErrors: [GModAppLuaErrorRecord]
    let permissions: [GModAppPermissionRecord]
}

enum GModAppProblemSnapshotBuilder {
    static func build(
        retained: [GModAppProblemRecord],
        gameLogs: [String],
        consoleLogs: [String],
        worldScene: GModMetalWorldScene?,
        surfaceDiagnostics: GModMetalSurfaceDiagnostics?,
        contentError: String?,
        rendererFailure: GModMetalWorldRendererFailure? = nil,
        startFailure: GModGameStartFailure? = nil,
        permissionCollection: GModPermissionCollection = .empty,
        permissionPersistenceError: GModPermissionStoreError? = nil
    ) -> GModAppProblemSnapshot {
        var problems = retained
        var luaErrors: [GModAppLuaErrorRecord] = []
        let logs = gameLogs + consoleLogs

        for line in logs {
            let lower = line.lowercased()
            if line.contains("[VGUI][MISSING]") {
                appendUnique(GModAppProblemRecord(
                    id: "vgui|\(line)",
                    kind: .vguiMissing,
                    severity: .error,
                    title: "#garryspad.problem.vgui-missing",
                    detail: line,
                    source: sourceAndLine(in: line).source
                ), to: &problems)
            }

            if isLuaFailure(lower), let parsed = luaError(from: line) {
                if !luaErrors.contains(where: { $0.id == parsed.id }) {
                    luaErrors.append(parsed)
                }
                appendUnique(GModAppProblemRecord(
                    id: "lua|\(parsed.id)",
                    kind: .luaError,
                    severity: .error,
                    title: "#garryspad.problem.lua-error",
                    detail: parsed.message,
                    source: parsed.source
                ), to: &problems)
            }

            if lower.contains("missing material") {
                appendUnique(runtimeProblem(
                    line,
                    kind: .missingMaterial,
                    title: "#garryspad.problem.missing-material"
                ), to: &problems)
            } else if lower.contains("missing texture") {
                appendUnique(runtimeProblem(
                    line,
                    kind: .missingTexture,
                    title: "#garryspad.problem.missing-texture"
                ), to: &problems)
            } else if lower.contains("renderer fallback")
                        || lower.contains("fallback material")
                        || lower.contains("material fallback") {
                appendUnique(runtimeProblem(
                    line,
                    kind: .rendererFallback,
                    title: "#garryspad.problem.renderer-fallback"
                ), to: &problems)
            }
        }

        if let worldScene {
            for (index, range) in worldScene.materialRanges.enumerated() {
                guard let materialName = range.materialName else { continue }
                switch range.materialResolution {
                case .notApplicable, .resolved:
                    break
                case .sourceMissing:
                    appendUnique(GModAppProblemRecord(
                        id: "world-material-source-missing|" +
                            "\(worldScene.meshIdentifier)|\(index)|\(materialName)",
                        kind: .missingMaterial,
                        severity: .warning,
                        title: "#garryspad.problem.missing-material",
                        detail: materialName,
                        source: worldScene.meshIdentifier
                    ), to: &problems)
                case let .decodeFailed(detail):
                    appendUnique(GModAppProblemRecord(
                        id: "world-material-decode-failed|" +
                            "\(worldScene.meshIdentifier)|\(index)|\(materialName)",
                        kind: .missingTexture,
                        severity: .error,
                        title: "#garryspad.problem.missing-texture",
                        detail: "\(materialName): \(detail)",
                        source: worldScene.meshIdentifier
                    ), to: &problems)
                case let .retentionCapacityExceeded(
                    requiredByteCount,
                    retainedByteCount,
                    maximumByteCount
                ):
                    appendUnique(GModAppProblemRecord(
                        id: "world-material-retention-capacity|" +
                            "\(worldScene.meshIdentifier)|\(index)|\(materialName)",
                        kind: .rendererFallback,
                        severity: .warning,
                        title: "#garryspad.problem.renderer-fallback",
                        detail: "\(materialName) requires \(requiredByteCount) bytes; " +
                            "\(retainedByteCount) retained / \(maximumByteCount) cap",
                        source: worldScene.meshIdentifier
                    ), to: &problems)
                }
            }

            if case let .capacityExceeded(
                requiredWidth,
                requiredHeight,
                requiredByteCount,
                maximumWidth,
                maximumHeight,
                maximumByteCount
            ) = worldScene.lightmapDiagnostics.atlasStatus {
                appendUnique(GModAppProblemRecord(
                    id: "world-lightmap-capacity|\(worldScene.meshIdentifier)|" +
                        "\(requiredWidth)x\(requiredHeight)|\(requiredByteCount)",
                    kind: .rendererFallback,
                    severity: .warning,
                    title: "#garryspad.problem.renderer-fallback",
                    detail: "#garryspad.problem.lightmap-atlas-capacity",
                    source: worldScene.meshIdentifier,
                    localizationArguments: [
                        "requiredWidth": String(requiredWidth),
                        "requiredHeight": String(requiredHeight),
                        "requiredByteCount": String(requiredByteCount),
                        "maximumWidth": String(maximumWidth),
                        "maximumHeight": String(maximumHeight),
                        "maximumByteCount": String(maximumByteCount),
                    ]
                ), to: &problems)
            }
        }

        if let startFailure {
            switch startFailure.origin {
            case .cpu:
                appendUnique(GModAppProblemRecord(
                    id: "session-start-failure|\(startFailure.map.rawValue)|" +
                        startFailure.detail,
                    kind: .compatibility,
                    severity: .error,
                    title: "#garryspad.problem.session-start",
                    detail: startFailure.detail,
                    source: startFailure.map.rawValue
                ), to: &problems)
            case let .renderer(meshIdentifier) where rendererFailure == nil:
                appendUnique(GModAppProblemRecord(
                    id: "renderer-start-failure|\(meshIdentifier)|" +
                        startFailure.detail,
                    kind: .rendererFallback,
                    severity: .error,
                    title: "#garryspad.problem.renderer-fallback",
                    detail: startFailure.detail,
                    source: meshIdentifier
                ), to: &problems)
            case .renderer:
                break
            }
        }

        if let rendererFailure {
            appendUnique(GModAppProblemRecord(
                id: "renderer-failure|\(rendererFailure.meshIdentifier)|" +
                    rendererFailure.reason.diagnosticDescription,
                kind: .rendererFallback,
                severity: .error,
                title: "#garryspad.problem.renderer-fallback",
                detail: rendererFailure.reason.diagnosticDescription,
                source: rendererFailure.meshIdentifier
            ), to: &problems)
        }

        if let diagnostics = surfaceDiagnostics {
            for unresolved in diagnostics.unresolvedCommands.prefix(64) {
                let lower = unresolved.reason.lowercased()
                let kind: GModAppProblemKind = lower.contains("texture")
                    || lower.contains("material") ? .missingTexture : .rendererFallback
                appendUnique(GModAppProblemRecord(
                    id: "surface|\(unresolved.commandIndex)|\(unresolved.reason)",
                    kind: kind,
                    severity: .warning,
                    title: kind == .missingTexture
                        ? "#garryspad.problem.missing-texture"
                        : "#garryspad.problem.renderer-fallback",
                    detail: unresolved.reason,
                    source: "surface command \(unresolved.commandIndex)"
                ), to: &problems)
            }
            if diagnostics.overflowed {
                appendUnique(GModAppProblemRecord(
                    id: "surface-overflow",
                    kind: .rendererFallback,
                    severity: .error,
                    title: "#garryspad.problem.renderer-fallback",
                    detail: "surface command budget overflow",
                    source: "GModMetalSurfaceScene"
                ), to: &problems)
            }
        }

        if let contentError, !contentError.isEmpty {
            appendUnique(GModAppProblemRecord(
                id: "content|\(contentError)",
                kind: .contentPack,
                severity: .error,
                title: "#garryspad.problem.content-pack",
                detail: contentError,
                source: nil
            ), to: &problems)
        }

        // The native store below is real, but it is not presented as the
        // original MENU realm. Transport and the MENU Lua bridge remain
        // explicit compatibility gaps until those systems exist.
        appendUnique(GModAppProblemRecord(
            id: "permissions-menu-transport-unavailable",
            kind: .compatibility,
            severity: .warning,
            title: "#garryspad.problem.permissions-limited",
            detail: "#garryspad.problem.permissions-limited-detail",
            source: "permissions"
        ), to: &problems)

        if let permissionPersistenceError {
            appendUnique(GModAppProblemRecord(
                id: "permissions-persistence|\(permissionPersistenceError)",
                kind: .compatibility,
                severity: .error,
                title: "#garryspad.problem.permissions-storage",
                detail: permissionPersistenceError.localizedDescription,
                source: "UserDefaults"
            ), to: &problems)
        }

        let permissions = permissionCollection.grants.map { grant in
            GModAppPermissionRecord(
                id: grant.id,
                serverIdentifier: grant.serverIdentifier,
                permission: grant.permission,
                lifetime: grant.lifetime
            )
        }

        problems.sort {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            return $0.id < $1.id
        }
        return GModAppProblemSnapshot(
            problems: problems,
            luaErrors: luaErrors,
            permissions: permissions
        )
    }

    private static func isLuaFailure(_ lower: String) -> Bool {
        let hasLuaSource = lower.contains(".lua:")
        return hasLuaSource && (
            lower.contains("attempt to")
                || lower.contains("error")
                || lower.contains("failed")
                || lower.contains("bad argument")
        )
    }

    private static func luaError(from line: String) -> GModAppLuaErrorRecord? {
        let location = sourceAndLine(in: line)
        guard let source = location.source else { return nil }
        let realm: String
        if line.uppercased().contains("[SERVER]") {
            realm = "SERVER"
        } else if line.uppercased().contains("[MENU]") {
            realm = "MENU"
        } else {
            realm = "CLIENT"
        }
        let newline = line.firstIndex(of: "\n")
        let traceback: String?
        if let newline {
            let remainder = line[line.index(after: newline)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            traceback = remainder.isEmpty ? nil : remainder
        } else {
            traceback = line.lowercased().contains("traceback") ? line : nil
        }
        return GModAppLuaErrorRecord(
            id: "\(realm)|\(source)|\(location.line ?? 0)|\(line)",
            realm: realm,
            source: source,
            line: location.line,
            message: line,
            traceback: traceback
        )
    }

    private static func sourceAndLine(
        in value: String
    ) -> (source: String?, line: Int?) {
        let pattern = #"((?:lua|gamemodes)[/\\][^\s:]+\.lua):(\d+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
              ),
              let sourceRange = Range(match.range(at: 1), in: value),
              let lineRange = Range(match.range(at: 2), in: value) else {
            return (nil, nil)
        }
        return (
            String(value[sourceRange]).replacingOccurrences(of: "\\", with: "/"),
            Int(value[lineRange])
        )
    }

    private static func runtimeProblem(
        _ line: String,
        kind: GModAppProblemKind,
        title: String
    ) -> GModAppProblemRecord {
        GModAppProblemRecord(
            id: "\(kind.rawValue)|\(line)",
            kind: kind,
            severity: .warning,
            title: title,
            detail: line,
            source: sourceAndLine(in: line).source
        )
    }

    private static func appendUnique(
        _ record: GModAppProblemRecord,
        to records: inout [GModAppProblemRecord]
    ) {
        guard !records.contains(where: {
            $0.id == record.id || (
                $0.kind == record.kind
                    && $0.detail == record.detail
                    && $0.source == record.source
            )
        }) else { return }
        records.append(record)
    }
}
