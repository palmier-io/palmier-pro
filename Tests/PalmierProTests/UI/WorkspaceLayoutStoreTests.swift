import Foundation
import Testing
@testable import PalmierPro

@Suite("Workspace layout preference")
@MainActor
struct WorkspaceLayoutStoreTests {
    @Test func presetsHaveUniqueShortcuts() {
        let presets = LayoutPreset.allCases

        #expect(Set(presets.map(\.shortcutKey)).count == presets.count)
        #expect(presets.allSatisfy { $0.shortcutLabel == "⌘\($0.shortcutKey)" })
    }

    @Test func missingOrInvalidPreferenceUsesDefaultLayout() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(makeStore(defaults).selection == .default)

        defaults.set("cinema", forKey: LayoutPreset.defaultsKey)
        #expect(makeStore(defaults).selection == .default)
    }

    @Test func selectedLayoutPersists() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = makeStore(defaults)

        store.selection = .media
        #expect(makeStore(defaults).selection == .media)

        store.selection = .vertical
        #expect(makeStore(defaults).selection == .vertical)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "WorkspaceLayoutStoreTests-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suiteName)), suiteName)
    }

    private func makeStore(_ defaults: UserDefaults) -> WorkspaceLayoutStore {
        WorkspaceLayoutStore(defaults: defaults)
    }
}
