import Foundation
import Observation

enum LayoutPreset: String, CaseIterable, Identifiable, Sendable {
    case `default`
    case media
    case vertical

    static let defaultsKey = "layoutPreset"

    var id: String { rawValue }

    var shortcutKey: Character {
        switch self {
        case .default: "1"
        case .media: "2"
        case .vertical: "3"
        }
    }

    var shortcutLabel: String { "⌘\(shortcutKey)" }

    var label: String {
        switch self {
        case .default: "Default"
        case .media: "Media"
        case .vertical: "Vertical"
        }
    }

    static func stored(in defaults: UserDefaults) -> LayoutPreset {
        defaults.string(forKey: defaultsKey).flatMap(LayoutPreset.init(rawValue:)) ?? .default
    }
}

@MainActor @Observable
final class WorkspaceLayoutStore {
    static let shared = WorkspaceLayoutStore()

    var selection: LayoutPreset {
        didSet {
            guard selection != oldValue else { return }
            defaults.set(selection.rawValue, forKey: LayoutPreset.defaultsKey)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = LayoutPreset.stored(in: defaults)
    }
}
