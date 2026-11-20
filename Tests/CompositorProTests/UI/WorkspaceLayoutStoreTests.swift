import Foundation
import Testing
@testable import CompositorPro

@Suite("Workspace layout preference")
@MainActor
struct WorkspaceLayoutStoreTests {
    @Test func presetsHaveUniqueShortcuts() {
        let presets = LayoutPreset.allCases

        #expect(Set(presets.map(\.shortcutKey)).count == presets.count)
        #expect(presets.allSatisfy { $0.shortcutLabel == "⌘\($0.shortcutKey)" })
    }

    @Test func missingOrInvalidPreferenceUsesStudioLayout() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(makeStore(defaults).selection == .studio)

        defaults.set("cinema", forKey: LayoutPreset.defaultsKey)
        #expect(makeStore(defaults).selection == .studio)
    }

    @Test func selectedLayoutPersists() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = makeStore(defaults)

        for preset in LayoutPreset.allCases {
            store.selection = preset
            #expect(makeStore(defaults).selection == preset)
        }
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "WorkspaceLayoutStoreTests-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suiteName)), suiteName)
    }

    private func makeStore(_ defaults: UserDefaults) -> WorkspaceLayoutStore {
        WorkspaceLayoutStore(defaults: defaults)
    }
}
