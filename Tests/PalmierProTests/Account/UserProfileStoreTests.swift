import Foundation
import Testing
@testable import PalmierPro

@Suite("UserProfileStore — onboarding state")
@MainActor
struct UserProfileStoreTests {

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "test-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test func freshInstallIsNotOnboarded() {
        let (defaults, suite) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let store = UserProfileStore(defaults: defaults)
        #expect(!store.isOnboarded)
        #expect(store.editingDomain == nil)
    }

    @Test func markOnboardedPersists() {
        let (defaults, suite) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        UserProfileStore(defaults: defaults).markOnboarded()
        #expect(UserProfileStore(defaults: defaults).isOnboarded)
    }

    @Test func editingDomainPersists() {
        let (defaults, suite) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        UserProfileStore(defaults: defaults).saveEditingDomain("malay_wedding")
        #expect(UserProfileStore(defaults: defaults).editingDomain == "malay_wedding")
    }
}
