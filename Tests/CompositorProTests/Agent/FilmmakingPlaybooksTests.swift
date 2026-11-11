import Foundation
import Testing
@testable import CompositorPro

@Suite("Filmmaking Playbooks and Style Preferences")
@MainActor
struct FilmmakingPlaybooksTests {
    @Test func builtInPlaybooksAreExposedByScan() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SkillTest-\(UUID().uuidString)")
        let scan = SkillStore.scan(directory: tempDir)

        let ids = scan.skills.map(\.id)
        #expect(ids.contains("narrated-broll-playbook"))
        #expect(ids.contains("interview-playbook"))
        #expect(ids.contains("product-playbook"))
        #expect(ids.contains("montage-playbook"))
        #expect(ids.contains("hyperframes-motion-playbook"))

        let brollBody = scan.bodies["narrated-broll-playbook"]
        #expect(brollBody?.contains("Narrated B-Roll Filmmaking Playbook") == true)
        #expect(brollBody?.contains("Dialogue-First Audio Mixing") == true)
        #expect(scan.shas["narrated-broll-playbook"] != nil)

        let hfBody = scan.bodies["hyperframes-motion-playbook"]
        #expect(hfBody?.contains("HyperFrames Motion & Kinetic Typography Playbook") == true)
        #expect(hfBody?.contains("Brand System & Design Alignment") == true)
        #expect(hfBody?.contains("Track Stacking Hierarchy") == true)
        #expect(scan.shas["hyperframes-motion-playbook"] != nil)
    }

    @Test func hyperframesPlaybookCanBeResolvedByAlias() {
        let direct = FilmmakingPlaybooks.playbook(for: "hyperframes-motion-playbook")
        #expect(direct?.name == "HyperFrames Motion & Kinetic Typography Playbook")

        let alias = FilmmakingPlaybooks.playbook(for: "hyperframes")
        #expect(alias?.id == "hyperframes-motion-playbook")

        let slashAlias = FilmmakingPlaybooks.playbook(for: "/hyperframes")
        #expect(slashAlias?.id == "hyperframes-motion-playbook")
    }

    @Test func readSkillToolRetrievesHyperframesSkill() async throws {
        let editor = EditorViewModel()
        let executor = ToolExecutor(editor: editor)

        let directResult = await executor.execute(
            name: "read_skill",
            args: ["id": "hyperframes-motion-playbook"],
            source: "test"
        )
        #expect(!directResult.isError)
        #expect(directResult.text.contains("HyperFrames Motion"))

        let aliasResult = await executor.execute(
            name: "read_skill",
            args: ["id": "hyperframes"],
            source: "test"
        )
        #expect(!aliasResult.isError)
        #expect(aliasResult.text.contains("HyperFrames Motion"))
    }

    @Test func userPreferencesCanBePersistedAndReloaded() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("PrefTest-\(UUID().uuidString)")
        let fileURL = tempDir.appendingPathComponent("prefs.json")

        let prefs = FilmmakingStylePreferences(fileURL: fileURL)
        #expect(prefs.data.pacing.targetShotDurationSeconds == 3.5)

        prefs.updatePacing(.init(targetShotDurationSeconds: 4.0, minShotDurationSeconds: 2.0, maxShotDurationSeconds: 7.0))
        prefs.pinRecipe(id: "cinematic-documentary")
        prefs.setActivePlaybook(id: "interview-playbook")

        // Wait brief instant for async file write
        try await Task.sleep(nanoseconds: 50_000_000)

        let reloaded = FilmmakingStylePreferences(fileURL: fileURL)
        #expect(reloaded.data.pacing.targetShotDurationSeconds == 4.0)
        #expect(reloaded.data.pinnedRecipeIds == ["cinematic-documentary"])
        #expect(reloaded.data.activePlaybookId == "interview-playbook")

        try? FileManager.default.removeItem(at: tempDir)
    }
}

