import Foundation

@Observable
@MainActor
final class ModelPreferences {
    static let shared = ModelPreferences()

    private static let defaultsKey = "disabledModelIds"

    private(set) var disabledIds: Set<String>

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        disabledIds = Set(stored)
    }

    func isEnabled(_ id: String) -> Bool { !disabledIds.contains(id) }

    func setEnabled(_ id: String, _ enabled: Bool) {
        if enabled {
            disabledIds.remove(id)
        } else {
            disabledIds.insert(id)
        }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(Array(disabledIds), forKey: Self.defaultsKey)
    }
}
