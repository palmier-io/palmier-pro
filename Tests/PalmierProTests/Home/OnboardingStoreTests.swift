import Foundation
import Testing
@testable import PalmierPro

@Suite("Onboarding store")
@MainActor
struct OnboardingStoreTests {
    @Test func newUserStartsAtWelcome() throws {
        try withDefaults { defaults in
            let store = OnboardingStore(defaults: defaults)

            #expect(!store.isComplete)
            #expect(store.step == .welcome)
        }
    }

    @Test func existingWelcomeCompletionSkipsOnboarding() throws {
        try withDefaults { defaults in
            defaults.set(true, forKey: OnboardingStore.completionKey)

            let store = OnboardingStore(defaults: defaults)

            #expect(store.isComplete)
        }
    }

    @Test func discoveryAdvancesToProfile() throws {
        try withDefaults { defaults in
            let store = OnboardingStore(defaults: defaults)
            store.advance()
            store.advance()

            #expect(store.step == .profile)
        }
    }

    @Test func submittingSurveyAdvancesToAccount() throws {
        try withDefaults { defaults in
            let store = OnboardingStore(defaults: defaults)
            store.advance()
            store.advance()
            store.submitSurvey()

            #expect(store.step == .account)
        }
    }

    @Test func stepsClampAtBothEnds() throws {
        try withDefaults { defaults in
            let store = OnboardingStore(defaults: defaults)
            store.goBack()

            #expect(store.step == .welcome)

            store.advance()
            store.advance()
            store.advance()
            store.advance()

            #expect(store.step == .account)
        }
    }

    @Test func completionPersists() throws {
        try withDefaults { defaults in
            let store = OnboardingStore(defaults: defaults)
            store.advance()

            store.complete()

            #expect(store.isComplete)
            #expect(defaults.bool(forKey: OnboardingStore.completionKey))
            #expect(OnboardingStore(defaults: defaults).isComplete)
        }
    }

    @Test func selectingAnOptionAgainDeselectsIt() throws {
        try withDefaults { defaults in
            let store = OnboardingStore(defaults: defaults)
            store.toggle(.other, for: .videoTypes)
            store.toggle(.other, for: .videoTypes)

            #expect(store.selection(for: .videoTypes).isEmpty)
        }
    }

    @Test func acquisitionSourceIsSingleSelect() throws {
        try withDefaults { defaults in
            let store = OnboardingStore(defaults: defaults)
            let google = try #require(OnboardingQuestion.acquisitionSource.options.first { $0.id == "google" })
            let github = try #require(OnboardingQuestion.acquisitionSource.options.first { $0.id == "github" })

            store.toggle(google, for: .acquisitionSource)
            store.toggle(github, for: .acquisitionSource)

            #expect(store.selection(for: .acquisitionSource) == ["github"])
        }
    }

    @Test func noPreviousEditorIsExclusive() throws {
        try withDefaults { defaults in
            let store = OnboardingStore(defaults: defaults)
            let premiere = try #require(OnboardingQuestion.previousEditors.options.first { $0.id == "premiere_pro" })
            let none = try #require(OnboardingQuestion.previousEditors.options.first { $0.id == "none" })
            let capcut = try #require(OnboardingQuestion.previousEditors.options.first { $0.id == "capcut" })

            store.toggle(premiere, for: .previousEditors)
            store.toggle(none, for: .previousEditors)
            #expect(store.selection(for: .previousEditors) == ["none"])

            store.toggle(capcut, for: .previousEditors)
            #expect(store.selection(for: .previousEditors) == ["capcut"])
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "OnboardingStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
