import Foundation
import Observation
import SwiftUI

@MainActor @Observable
final class AppLocalization {
    static let shared = AppLocalization()

    let activeIdentifier: String
    let activeLocale: Locale
    let availableLanguages: [AppLanguage]

    var selection: AppLanguage {
        didSet {
            guard selection != oldValue else { return }
            defaults.set(selection.id, forKey: AppLanguage.defaultsKey)
        }
    }

    var requiresRestart: Bool {
        (selection.identifier ?? systemIdentifier) != activeIdentifier
    }

    private let defaults: UserDefaults
    private let localizedBundle: Bundle
    private let systemIdentifier: String

    init(
        defaults: UserDefaults = .standard,
        resourceBundle: Bundle = BundledResource.bundle,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) {
        self.defaults = defaults

        let resources = Self.localizationResources(in: resourceBundle)
        let identifiers = resources.map(\.identifier)
        availableLanguages = identifiers.map(AppLanguage.language)
        let resolvedSystemIdentifier = Self.preferredIdentifier(
            in: resources,
            preferredLanguages: preferredLanguages
        )
        systemIdentifier = resolvedSystemIdentifier

        let storedLanguage = AppLanguage.stored(in: defaults)
        let validLanguage: AppLanguage
        if let identifier = storedLanguage.identifier, identifiers.contains(identifier) {
            validLanguage = .language(identifier)
        } else {
            validLanguage = .system
        }
        if defaults.string(forKey: AppLanguage.defaultsKey).map({ $0 != validLanguage.id }) == true {
            defaults.set(validLanguage.id, forKey: AppLanguage.defaultsKey)
        }

        selection = validLanguage
        let resolvedActiveIdentifier = validLanguage.identifier ?? resolvedSystemIdentifier
        activeIdentifier = resolvedActiveIdentifier
        activeLocale = Locale(identifier: resolvedActiveIdentifier)
        let resourceIdentifier = resources.first { $0.identifier == resolvedActiveIdentifier }?.resourceIdentifier
            ?? resolvedActiveIdentifier
        localizedBundle = Self.localizedBundle(
            for: resourceIdentifier,
            resourceBundle: resourceBundle
        )
    }

    func string(_ keyAndValue: String.LocalizationValue) -> String {
        String(
            localized: keyAndValue,
            bundle: localizedBundle,
            locale: activeLocale
        )
    }

    func string(key: String) -> String {
        localizedBundle.localizedString(forKey: key, value: nil, table: nil)
    }

    func displayName(for language: AppLanguage) -> String {
        guard let identifier = language.identifier else {
            return string(key: L10n.key("System Language"))
        }
        let locale = Locale(identifier: identifier)
        return locale.localizedString(forIdentifier: identifier) ?? identifier
    }

    private struct LocalizationResource {
        let identifier: String
        let resourceIdentifier: String
    }

    private static func localizationResources(in bundle: Bundle) -> [LocalizationResource] {
        bundle.localizations
            .filter { $0 != "Base" }
            .map {
                LocalizationResource(
                    identifier: Locale(identifier: $0).identifier,
                    resourceIdentifier: $0
                )
            }
            .sorted { lhs, rhs in
                let lhsName = Locale(identifier: lhs.identifier)
                    .localizedString(forIdentifier: lhs.identifier) ?? lhs.identifier
                let rhsName = Locale(identifier: rhs.identifier)
                    .localizedString(forIdentifier: rhs.identifier) ?? rhs.identifier
                return lhsName.localizedStandardCompare(rhsName) == .orderedAscending
            }
    }

    private static func preferredIdentifier(
        in resources: [LocalizationResource],
        preferredLanguages: [String]
    ) -> String {
        return Bundle.preferredLocalizations(
            from: resources.map(\.resourceIdentifier),
            forPreferences: preferredLanguages
        ).first.map { Locale(identifier: $0).identifier } ?? "en"
    }

    private static func localizedBundle(for identifier: String, resourceBundle: Bundle) -> Bundle {
        guard let url = resourceBundle.url(forResource: identifier, withExtension: "lproj"),
              let bundle = Bundle(url: url) else {
            return resourceBundle
        }
        return bundle
    }
}

extension View {
    func appLocalization() -> some View {
        environment(\.locale, AppLocalization.shared.activeLocale)
    }
}

@MainActor
enum L10n {
    nonisolated static func key(_ value: StaticString) -> String {
        value.description
    }

    static func string(_ keyAndValue: String.LocalizationValue) -> String {
        AppLocalization.shared.string(keyAndValue)
    }

    static func string(key: String) -> String {
        AppLocalization.shared.string(key: key)
    }

}
