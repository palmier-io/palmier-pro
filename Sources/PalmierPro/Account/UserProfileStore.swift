import Foundation

/// Local profile (onboarding answers). Stored in UserDefaults; no account required.
@MainActor
@Observable
final class UserProfileStore {
    static let shared = UserProfileStore()

    private static let onboardedKey = "onboarding-completed"
    private static let domainKey = "editing-domain"

    private let defaults: UserDefaults
    private(set) var editingDomain: String?
    private(set) var isOnboarded: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        editingDomain = defaults.string(forKey: Self.domainKey)
        isOnboarded = defaults.bool(forKey: Self.onboardedKey)
    }

    func saveEditingDomain(_ domain: String) {
        editingDomain = domain
        defaults.set(domain, forKey: Self.domainKey)
    }

    func markOnboarded() {
        isOnboarded = true
        defaults.set(true, forKey: Self.onboardedKey)
    }
}
