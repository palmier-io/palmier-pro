import Foundation
import Testing
@testable import PalmierPro

@Suite("App localization")
@MainActor
struct AppLocalizationTests {
    @Test func bundledEnglishLocalizationIsAvailable() throws {
        try withDefaults { defaults in
            let localization = AppLocalization(defaults: defaults)

            #expect(localization.availableLanguages.contains(.language("en")))
            #expect(localization.string("System Language") == "System Language")
            #expect(localization.string(key: "System Language") == "System Language")
            #expect(localization.string(key: "Export Queue") == "Export Queue")
            #expect(localization.string(key: "Moments") == "Moments")
            #expect(localization.string(key: "Spoken") == "Spoken")
            #expect(localization.string(key: "Files") == "Files")
            #expect(localization.string("\(1234) credits") == "1,234 credits")
            #expect(
                BundledResource.bundle.localizedString(
                    forKey: "CFBundleTypeName",
                    value: nil,
                    table: "InfoPlist"
                ) == "Palmier Project"
            )
        }
    }

    @Test(arguments: ["en", "EN"])
    func storedLanguageBecomesActiveAndCanonical(identifier: String) throws {
        try withDefaults { defaults in
            defaults.set(identifier, forKey: AppLanguage.defaultsKey)

            let localization = AppLocalization(defaults: defaults)

            #expect(localization.activeIdentifier == "en")
            #expect(localization.selection == .language("en"))
            #expect(defaults.string(forKey: AppLanguage.defaultsKey) == "en")
            #expect(!localization.requiresRestart)
        }
    }

    @Test(arguments: [
        ("zh-Hans", "导出"),
        ("zh-Hant", "匯出"),
    ])
    func bundledChineseLocalizationCanBeSelected(identifier: String, export: String) throws {
        try withDefaults { defaults in
            defaults.set(identifier, forKey: AppLanguage.defaultsKey)

            let localization = AppLocalization(defaults: defaults)

            #expect(localization.availableLanguages.contains(.language(identifier)))
            #expect(localization.activeIdentifier == identifier)
            #expect(localization.string("Export") == export)
        }
    }

    @Test func unsupportedStoredLanguageFallsBackToSystem() throws {
        try withDefaults { defaults in
            defaults.set("not-a-bundled-language", forKey: AppLanguage.defaultsKey)

            let localization = AppLocalization(defaults: defaults, preferredLanguages: ["en"])

            #expect(localization.activeIdentifier == "en")
            #expect(localization.selection == .system)
            #expect(defaults.string(forKey: AppLanguage.defaultsKey) == "system")
        }
    }

    @Test(arguments: [
        (AppLanguage.language("en"), false),
        (AppLanguage.language("fr"), true),
    ])
    func languageSelectionPersistsAndReportsRestart(
        language: AppLanguage,
        requiresRestart: Bool
    ) throws {
        try withDefaults { defaults in
            let localization = AppLocalization(defaults: defaults, preferredLanguages: ["en"])

            localization.selection = language

            #expect(defaults.string(forKey: AppLanguage.defaultsKey) == language.id)
            #expect(localization.requiresRestart == requiresRestart)
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "AppLocalizationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
