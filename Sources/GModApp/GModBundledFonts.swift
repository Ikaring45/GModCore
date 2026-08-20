import CoreGraphics
import CoreText
import Foundation
import GModEngine
import GModLua

public struct GModBundledFontRegistrationFailure: Sendable, Equatable {
    public let bundleFile: String
    public let message: String

    public init(bundleFile: String, message: String) {
        self.bundleFile = bundleFile
        self.message = message
    }
}

public struct GModBundledFontRegistrationReport: Sendable, Equatable {
    public let sourceAliasCount: Int
    public let bundledFileCount: Int
    public let registeredFileCount: Int
    public let alreadyRegisteredFileCount: Int
    public let failures: [GModBundledFontRegistrationFailure]

    public var succeeded: Bool {
        failures.isEmpty
            && registeredFileCount + alreadyRegisteredFileCount == bundledFileCount
    }
}

enum GModFontRegistrationAttempt: Sendable, Equatable {
    case registered
    case alreadyRegistered
    case failed(String)
}

protocol GModFontRegistering: Sendable {
    func registerFont(at url: URL) -> GModFontRegistrationAttempt
    func exactPostScriptFaceResolves(_ postScriptName: String) -> Bool
}

protocol GModFontResourceResolving: Sendable {
    func data(named name: String) throws -> Data
    func resourceURL(named name: String) -> URL?
    func byteCount(at url: URL) -> Int64?
}

private final class GModBundleFontResourceResolver:
    GModFontResourceResolving,
    @unchecked Sendable
{
    private let bundle: Bundle

    init(bundle: Bundle) {
        self.bundle = bundle
    }

    func data(named name: String) throws -> Data {
        guard let url = resourceURL(named: name) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    func resourceURL(named name: String) -> URL? {
        let filename = name as NSString
        let stem = filename.deletingPathExtension
        let extensionName = filename.pathExtension.isEmpty ? nil : filename.pathExtension
        return bundle.url(
            forResource: stem,
            withExtension: extensionName,
            subdirectory: "Fonts/GMod"
        ) ?? bundle.url(forResource: stem, withExtension: extensionName)
    }

    func byteCount(at url: URL) -> Int64? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return nil
        }
        return Int64(size)
    }
}

private struct GModCoreTextFontRegistrar: GModFontRegistering {
    func registerFont(at url: URL) -> GModFontRegistrationAttempt {
        var registrationError: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(
            url as CFURL,
            .process,
            &registrationError
        ) {
            return .registered
        }
        guard let error = registrationError?.takeRetainedValue() else {
            return .failed("CoreText rejected the font without an error")
        }
        if CFErrorGetCode(error) == CTFontManagerError.alreadyRegistered.rawValue {
            return .alreadyRegistered
        }
        return .failed(String(describing: error))
    }

    func exactPostScriptFaceResolves(_ postScriptName: String) -> Bool {
        let font = CTFontCreateWithName(postScriptName as CFString, 12, nil)
        let resolvedName = CTFontCopyPostScriptName(font) as String
        return resolvedName.caseInsensitiveCompare(postScriptName) == .orderedSame
    }
}

/// Loads and registers only the project-authorized fonts copied from the base
/// Garry's Mod install. The resource manifest deliberately excludes Workshop,
/// cache, addons, and every non-font game asset.
public final class GModBundledFontRegistry: @unchecked Sendable {
    public static let shared = GModBundledFontRegistry(
        resourceResolver: GModBundleFontResourceResolver(bundle: .module),
        registrar: GModCoreTextFontRegistrar()
    )

    private struct Manifest: Decodable {
        let sourceAliasCount: Int
        let bundledFileCount: Int
        let bundledByteCount: Int64
        let entries: [Entry]
    }

    private struct Entry: Decodable {
        let sourceAlias: String
        let bundleFile: String
        let byteCount: Int64
        let sha256: String
        let fontNames: FontNames
    }

    private struct FontNames: Decodable {
        let family: String
        let subfamily: String
        let full: String
        let postScript: String
    }

    private struct Face {
        let postScript: String
        let weight: Int
        let italic: Bool
        let condensed: Bool
    }

    private let lock = NSLock()
    private let resourceResolver: any GModFontResourceResolving
    private let registrar: any GModFontRegistering
    private let manifest: Manifest?
    private let manifestLoadFailure: GModBundledFontRegistrationFailure?
    private let faces: [Face]
    private let directPostScriptNames: [String: String]
    private var cachedRegistrationReport: GModBundledFontRegistrationReport?

    init(
        resourceResolver: any GModFontResourceResolving,
        registrar: any GModFontRegistering
    ) {
        self.resourceResolver = resourceResolver
        self.registrar = registrar

        do {
            let decoded = try JSONDecoder().decode(
                Manifest.self,
                from: resourceResolver.data(named: "GModFonts.manifest.json")
            )
            guard decoded.entries.count == decoded.sourceAliasCount else {
                throw ManifestError(
                    "sourceAliasCount is \(decoded.sourceAliasCount), " +
                    "but the manifest contains \(decoded.entries.count) entries"
                )
            }
            let uniqueFiles = Set(decoded.entries.map(\.bundleFile))
            guard uniqueFiles.count == decoded.bundledFileCount else {
                throw ManifestError(
                    "bundledFileCount is \(decoded.bundledFileCount), " +
                    "but the manifest names \(uniqueFiles.count) unique files"
                )
            }
            let uniqueBytes = Dictionary(
                grouping: decoded.entries,
                by: \.bundleFile
            ).values.reduce(Int64(0)) { partialResult, aliases in
                partialResult + (aliases.first?.byteCount ?? 0)
            }
            guard uniqueBytes == decoded.bundledByteCount else {
                throw ManifestError(
                    "bundledByteCount is \(decoded.bundledByteCount), " +
                    "but the unique entries total \(uniqueBytes) bytes"
                )
            }
            manifest = decoded
            manifestLoadFailure = nil

            var seenFiles = Set<String>()
            let uniqueEntries = decoded.entries.filter {
                seenFiles.insert($0.bundleFile).inserted
            }
            faces = uniqueEntries.map { entry in
                Face(
                    postScript: entry.fontNames.postScript,
                    weight: Self.weight(of: entry.fontNames.postScript),
                    italic: entry.fontNames.postScript
                        .localizedCaseInsensitiveContains("Italic"),
                    condensed: entry.fontNames.postScript
                        .localizedCaseInsensitiveContains("Condensed")
                )
            }

            var aliases: [String: String] = [:]
            for entry in uniqueEntries {
                var names = [
                    entry.fontNames.full,
                    entry.fontNames.postScript,
                    URL(fileURLWithPath: entry.bundleFile)
                        .deletingPathExtension()
                        .lastPathComponent
                ]
                if !Self.canonicalName(entry.fontNames.family).hasPrefix("roboto") {
                    names.append(entry.fontNames.family)
                }
                for name in names {
                    aliases[Self.canonicalName(name)] = entry.fontNames.postScript
                }
            }
            directPostScriptNames = aliases
        } catch {
            manifest = nil
            manifestLoadFailure = GModBundledFontRegistrationFailure(
                bundleFile: "GModFonts.manifest.json",
                message: String(describing: error)
            )
            faces = []
            directPostScriptNames = [:]
        }
    }

    /// Registers each unique bundled font at process scope exactly once. Calls
    /// after the first completed attempt return the cached report without
    /// invoking CoreText again.
    @discardableResult
    public func registerAllFonts() -> GModBundledFontRegistrationReport {
        lock.lock()
        defer { lock.unlock() }

        if let cachedRegistrationReport {
            return cachedRegistrationReport
        }
        guard let manifest else {
            let report = GModBundledFontRegistrationReport(
                sourceAliasCount: 0,
                bundledFileCount: 0,
                registeredFileCount: 0,
                alreadyRegisteredFileCount: 0,
                failures: manifestLoadFailure.map { [$0] } ?? []
            )
            cachedRegistrationReport = report
            return report
        }

        var failures: [GModBundledFontRegistrationFailure] = []
        var registeredFileCount = 0
        var alreadyRegisteredFileCount = 0
        var seenFiles = Set<String>()
        for entry in manifest.entries where seenFiles.insert(entry.bundleFile).inserted {
            guard let url = resourceResolver.resourceURL(named: entry.bundleFile) else {
                failures.append(
                    GModBundledFontRegistrationFailure(
                        bundleFile: entry.bundleFile,
                        message: "bundled resource is missing"
                    )
                )
                continue
            }
            guard let size = resourceResolver.byteCount(at: url) else {
                failures.append(
                    GModBundledFontRegistrationFailure(
                        bundleFile: entry.bundleFile,
                        message: "bundled resource byte count is unavailable"
                    )
                )
                continue
            }
            if size != entry.byteCount {
                failures.append(
                    GModBundledFontRegistrationFailure(
                        bundleFile: entry.bundleFile,
                        message: "byte count does not match the provenance manifest"
                    )
                )
                continue
            }

            switch registrar.registerFont(at: url) {
            case .registered:
                registeredFileCount += 1
            case .alreadyRegistered:
                if registrar.exactPostScriptFaceResolves(entry.fontNames.postScript) {
                    alreadyRegisteredFileCount += 1
                } else {
                    failures.append(
                        GModBundledFontRegistrationFailure(
                            bundleFile: entry.bundleFile,
                            message: "CoreText reported already registered, but the expected " +
                                "PostScript face '\(entry.fontNames.postScript)' did not resolve"
                        )
                    )
                }
            case let .failed(message):
                failures.append(
                    GModBundledFontRegistrationFailure(
                        bundleFile: entry.bundleFile,
                        message: message
                    )
                )
            }
        }

        let report = GModBundledFontRegistrationReport(
            sourceAliasCount: manifest.sourceAliasCount,
            bundledFileCount: manifest.bundledFileCount,
            registeredFileCount: registeredFileCount,
            alreadyRegisteredFileCount: alreadyRegisteredFileCount,
            failures: failures
        )
        cachedRegistrationReport = report
        return report
    }

    public func resolvedPostScriptName(
        requestedName: String,
        weight: Int,
        italic: Bool
    ) -> String? {
        let canonical = Self.canonicalName(requestedName)
        if let exact = directPostScriptNames[canonical] {
            return exact
        }
        // Stock Derma selects the Windows platform face Tahoma on every
        // non-Linux realm. iPadOS does not ship that Microsoft-owned face, so
        // both layout and rasterization deliberately resolve it through the
        // authorized bundled Roboto family instead of allowing CoreText to
        // choose two potentially different platform fallbacks.
        if canonical.hasPrefix("roboto") || canonical == "tahoma" {
            let wantsCondensed = canonical.contains("condensed") || canonical == "robotocn"
            let wantsItalic = italic || canonical.contains("italic")
            let wantedWeight = canonical == "tahoma"
                ? weight
                : (Self.explicitWeight(in: canonical) ?? weight)
            let candidates = faces.filter {
                Self.canonicalName($0.postScript).hasPrefix("roboto")
                    && $0.condensed == wantsCondensed
            }
            if let best = candidates.min(by: { lhs, rhs in
                Self.faceScore(lhs, weight: wantedWeight, italic: wantsItalic)
                    < Self.faceScore(rhs, weight: wantedWeight, italic: wantsItalic)
            }) {
                return best.postScript
            }
        }
        return directPostScriptNames[canonical]
    }

    private static func canonicalName(_ value: String) -> String {
        String(value.unicodeScalars.compactMap { scalar -> Character? in
            switch scalar.value {
            case 48...57:
                return Character(String(scalar))
            case 65...90:
                return Character(UnicodeScalar(scalar.value + 32)!)
            case 97...122:
                return Character(String(scalar))
            default:
                return nil
            }
        })
    }

    private static func weight(of postScriptName: String) -> Int {
        let canonical = canonicalName(postScriptName)
        return explicitWeight(in: canonical) ?? 400
    }

    private static func explicitWeight(in canonicalName: String) -> Int? {
        if canonicalName.contains("thin") { return 100 }
        if canonicalName.contains("light") { return 300 }
        if canonicalName.contains("medium") { return 500 }
        if canonicalName.contains("black") { return 900 }
        if canonicalName.contains("bold") { return 700 }
        if canonicalName.contains("regular") { return 400 }
        return nil
    }

    private static func faceScore(_ face: Face, weight: Int, italic: Bool) -> Int {
        abs(face.weight - min(1_000, max(0, weight)))
            + (face.italic == italic ? 0 : 10_000)
    }

    private struct ManifestError: LocalizedError {
        let errorDescription: String?

        init(_ description: String) {
            errorDescription = description
        }
    }
}

/// CoreText-backed implementation of the engine's text measurement boundary.
/// It resolves copied GMod faces first and retains CoreText's own fallback for
/// platform fonts and glyphs not present in those faces.
public final class GModCoreTextMeasurer: GMLuaTextMeasurer, @unchecked Sendable {
    public let fidelity = GMLuaTextMeasurementFidelity.platformGlyphMetrics
    public let registrationReport: GModBundledFontRegistrationReport

    private let registry: GModBundledFontRegistry

    public init(registry: GModBundledFontRegistry = .shared) {
        self.registry = registry
        registrationReport = registry.registerAllFonts()
    }

    public func measure(
        _ text: LuaString,
        using descriptor: GMLuaFontDescriptor
    ) -> GMLuaTextMeasurement {
        registry.registerAllFonts()
        let font = makeFont(for: descriptor)
        let decoded = String(decoding: text.bytes, as: UTF8.self)
        let lines = decoded.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        let attributes = [
            NSAttributedString.Key(kCTFontAttributeName as String): font
        ]
        var maximumWidth = 0
        for line in lines {
            let attributed = NSAttributedString(
                string: String(line),
                attributes: attributes
            )
            let coreTextLine = CTLineCreateWithAttributedString(attributed)
            maximumWidth = max(
                maximumWidth,
                Self.pixelDimension(CTLineGetTypographicBounds(
                    coreTextLine,
                    nil,
                    nil,
                    nil
                ))
            )
        }

        return GMLuaTextMeasurement(
            width: maximumWidth,
            height: GMLuaSourceFontTallMetrics.exactTextHeight(
                lineCount: lines.count,
                requestedTall: descriptor.size
            )
        )
    }

    private func makeFont(for descriptor: GMLuaFontDescriptor) -> CTFont {
        let requestedName = descriptor.font.utf8String
        let bundledPostScriptName = registry.resolvedPostScriptName(
            requestedName: requestedName,
            weight: descriptor.weight,
            italic: descriptor.italic
        )
        let initialPointSize = CGFloat(max(1, descriptor.size))
        let base = CTFontCreateWithName(
            (bundledPostScriptName ?? requestedName) as CFString,
            initialPointSize,
            nil
        )
        let styled: CTFont
        if bundledPostScriptName != nil {
            styled = base
        } else {
            var traits: CTFontSymbolicTraits = []
            if descriptor.weight >= 700 { traits.insert(.traitBold) }
            if descriptor.italic { traits.insert(.traitItalic) }
            if traits.isEmpty {
                styled = base
            } else {
                styled = CTFontCreateCopyWithSymbolicTraits(
                    base,
                    initialPointSize,
                    nil,
                    traits,
                    traits
                ) ?? base
            }
        }

        let unscaledLineHeight = Double(
            CTFontGetAscent(styled)
                + CTFontGetDescent(styled)
                + CTFontGetLeading(styled)
        )
        let scaledPointSize = GMLuaSourceFontTallMetrics.scaledPointSize(
            unscaledPointSize: Double(initialPointSize),
            unscaledLineHeight: unscaledLineHeight,
            requestedTall: descriptor.size
        )
        let resolvedPostScriptName = CTFontCopyPostScriptName(styled) as String
        return CTFontCreateWithName(
            resolvedPostScriptName as CFString,
            CGFloat(scaledPointSize),
            nil
        )
    }

    private static func pixelDimension(_ value: Double) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        let rounded = ceil(value)
        return rounded >= Double(Int.max) ? Int.max : Int(rounded)
    }
}
