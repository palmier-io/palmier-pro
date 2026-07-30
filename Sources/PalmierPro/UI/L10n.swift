import Foundation
import SwiftUI

private final class L10nBundleToken {}

enum L10n {
    /// Release builds flatten localizations into the app bundle, while SwiftPM
    /// leaves them inside PalmierPro_PalmierPro.bundle/Localization.
    static let localizationBundles: [Bundle] = {
        let moduleBundle = Bundle(for: L10nBundleToken.self)
        let roots = [
            Bundle.main.resourceURL,
            moduleBundle.resourceURL,
            Bundle.main.bundleURL,
            moduleBundle.bundleURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
            moduleBundle.bundleURL.deletingLastPathComponent(),
        ].compactMap { $0 }

        var bundles = [Bundle.main]
        var seen = Set([Bundle.main.bundleURL.standardizedFileURL.path])

        func appendBundle(at url: URL) {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted, let bundle = Bundle(url: url) else { return }
            bundles.append(bundle)
        }

        for root in roots {
            appendBundle(at: root.appendingPathComponent("PalmierPro_PalmierPro.bundle"))
        }
        let resourceBundles = Array(bundles.dropFirst())
        for resourceBundle in resourceBundles {
            if let resourceURL = resourceBundle.resourceURL {
                appendBundle(at: resourceURL.appendingPathComponent("Localization"))
            }
        }
        return bundles
    }()

    static func string(_ key: String) -> String {
        for bundle in localizationBundles {
            let value = bundle.localizedString(forKey: key, value: nil, table: nil)
            if value != key { return value }
        }
        return key
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: Locale.current, arguments: arguments)
    }

    static func message(_ key: String, localized: Bool, _ arguments: CVarArg...) -> String {
        let format = localized ? string(key) : key
        let locale = localized ? Locale.current : Locale(identifier: "en_US_POSIX")
        return String(format: format, locale: locale, arguments: arguments)
    }

    static func text(_ key: String) -> Text {
        Text(verbatim: string(key))
    }
}
