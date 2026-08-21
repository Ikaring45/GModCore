import Foundation
import GModGameSession

enum GModBundledAppLocalization {
    static func load(
        diagnostic: (String) -> Void = { _ in }
    ) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        for code in GModMenuLocalizationCatalog.supportedLanguageCodes {
            guard let url = Bundle.module.url(
                forResource: "garryspad",
                withExtension: "properties",
                subdirectory: "Localization/\(code)"
            ) else {
                diagnostic("bundled app localization is missing for \(code)")
                continue
            }
            do {
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                result[code] = try GModJavaPropertiesParser.parse(data: data)
            } catch {
                diagnostic("bundled app localization failed for \(code): \(error)")
            }
        }
        return result
    }
}

extension GModMenuLanguageSnapshot {
    func loadingStageText(_ stage: GModPlayableSessionLoadingStage) -> String {
        phrase("garryspad.loading.\(stage.taskIdentifier)")
    }
}
