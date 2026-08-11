import Foundation

enum AppLanguage: Hashable, Identifiable, Sendable {
    case system
    case language(String)

    static let defaultsKey = "appLanguage"

    var id: String {
        switch self {
        case .system: "system"
        case .language(let identifier): Locale(identifier: identifier).identifier
        }
    }

    var identifier: String? {
        switch self {
        case .system: nil
        case .language: id
        }
    }

    static func stored(in defaults: UserDefaults) -> AppLanguage {
        guard let identifier = defaults.string(forKey: defaultsKey), identifier != "system" else {
            return .system
        }
        return .language(Locale(identifier: identifier).identifier)
    }
}
