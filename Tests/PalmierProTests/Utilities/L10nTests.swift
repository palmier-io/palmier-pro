import Testing
@testable import PalmierPro

@Suite("L10n")
struct L10nTests {

    @Test func discoversSwiftPMResourceBundleLocalization() {
        #expect(
            L10n.localizationBundles.contains {
                $0.bundleURL.lastPathComponent == "Localization"
                    && $0.localizations.contains("zh-Hans")
            }
        )
    }

    @Test func protocolMessageBypassesBundleLocalization() {
        #expect(
            L10n.message("Downloading %d%%", localized: false, 25)
                == "Downloading 25%"
        )
    }

    @Test func sharedValidationDefaultsToProtocolEnglish() {
        #expect(
            unsupportedValue(
                model: "Example Model",
                field: "duration",
                value: "7s",
                allowed: ["5s", "10s"]
            )
                == "Example Model does not support duration '7s'. Valid: 5s, 10s."
        )
    }
}
