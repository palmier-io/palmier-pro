import Foundation
import SwiftUI

enum L10n {
    static func string(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
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
        Text(LocalizedStringKey(key))
    }
}
