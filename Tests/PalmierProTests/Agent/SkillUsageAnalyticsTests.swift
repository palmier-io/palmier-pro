import Foundation
import Testing
@testable import PalmierPro

@Suite("Skill usage analytics")
struct SkillUsageAnalyticsTests {
    @Test func skillReadPropertiesIdentifyTheSkillRevisionAndOrigin() {
        let origin = Analytics.Origin(source: "mcp", sessionID: "session-1")

        let properties = Analytics.$origin.withValue(origin) {
            Analytics.skillReadProperties(
                skillID: "color-grade",
                skillSHA: "a1b2c3d4e5f6",
                skillOrigin: SkillOrigin.community.rawValue
            )
        }

        #expect(properties["skill_id"] as? String == "color-grade")
        #expect(properties["skill_sha"] as? String == "a1b2c3d4e5f6")
        #expect(properties["skill_origin"] as? String == "community")
        #expect(properties["source"] as? String == "mcp")
        #expect(properties["session_id"] as? String == "session-1")
        #expect(Set(properties.keys) == ["skill_id", "skill_sha", "skill_origin", "source", "session_id"])
    }

    @Test func skillCreatedPropertiesAttributeTheCreator() {
        let origin = Analytics.Origin(source: "agent", sessionID: "session-1")

        let properties = Analytics.$origin.withValue(origin) {
            Analytics.skillCreatedProperties(skillName: "Custom workflow")
        }

        #expect(Analytics.Event.skillCreated.rawValue == "skill created")
        #expect(properties["skill_name"] as? String == "Custom workflow")
        #expect(properties["source"] as? String == "agent")
        #expect(properties["session_id"] as? String == "session-1")
        #expect(Set(properties.keys) == ["skill_name", "source", "session_id"])
    }

    @Test func skillOriginDistinguishesCommunityLocalAndModifiedSkills() {
        #expect(SkillStore.skillOrigin(installedSHA: "catalog", localSHA: "catalog") == .community)
        #expect(SkillStore.skillOrigin(installedSHA: "catalog", localSHA: "local") == .communityModified)
        #expect(SkillStore.skillOrigin(installedSHA: nil, localSHA: "local") == .local)
    }

    @Test @MainActor func unknownSkillReadIsRejectedBeforeItCanBeTracked() {
        let editor = EditorViewModel()
        let executor = ToolExecutor(editor: editor)

        let result = executor.readSkill(["id": UUID().uuidString])

        #expect(result.isError)
    }
}
