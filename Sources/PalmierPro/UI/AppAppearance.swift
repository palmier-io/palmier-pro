import AppKit
import Foundation
import Observation

enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    static let defaultsKey = "appAppearance"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: L10n.key("System")
        case .light: L10n.key("Light")
        case .dark: L10n.key("Dark")
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    static func stored(in defaults: UserDefaults) -> AppAppearance {
        defaults.string(forKey: defaultsKey).flatMap(AppAppearance.init(rawValue:)) ?? .dark
    }
}

@MainActor @Observable
final class AppAppearanceStore {
    static let shared = AppAppearanceStore()

    var selection: AppAppearance {
        didSet {
            guard selection != oldValue else { return }
            defaults.set(selection.rawValue, forKey: AppAppearance.defaultsKey)
            apply()
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = AppAppearance.stored(in: defaults)
    }

    func apply() {
        NSApp.appearance = selection.nsAppearance
    }
}
