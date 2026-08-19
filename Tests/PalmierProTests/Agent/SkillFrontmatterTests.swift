import Foundation
import Testing
@testable import PalmierPro

@Suite("Skill frontmatter")
struct SkillFrontmatterTests {
    @Test func requiresNonemptyNameAndDescription() {
        let valid = "---\nname: Editing\ndescription: Edit clips.\n---\n\nInstructions"
        let missingName = "---\ndescription: Edit clips.\n---\n\nInstructions"
        let emptyDescription = "---\nname: Editing\ndescription:   \n---\n\nInstructions"

        #expect(SkillFrontmatter.requiredFields(valid) != nil)
        #expect(SkillFrontmatter.requiredFields(missingName) == nil)
        #expect(SkillFrontmatter.requiredFields(emptyDescription) == nil)
    }

    @Test func replacingOnlyNameKeepsTheDraftInstructions() {
        let draft = "---\nname: New skill\ndescription: Edit clips.\n---\n\n## Workflow\n1. First step."

        let updated = SkillFrontmatter.replacingFields(draft, name: "Editing")

        #expect(updated == "---\nname: Editing\ndescription: Edit clips.\n---\n\n## Workflow\n1. First step.")
    }

    @Test func replacingFieldsPreservesUnchangedFrontmatter() {
        let draft = "---\nname: Editing\ndescription: Edit clips.\nsource: local\n---\n\nOld instructions"

        let updated = SkillFrontmatter.replacingFields(
            draft,
            description: "Tighten interview edits.",
            instructions: "## Workflow\nRemove pauses."
        )

        #expect(
            updated
                == "---\nname: Editing\ndescription: Tighten interview edits.\nsource: local\n---\n\n## Workflow\nRemove pauses."
        )
    }

    @Test func suggestedSkillIDIsStableAndFilesystemSafe() {
        #expect(SkillStore.suggestedID(for: "  Interview Cleanup & Pacing  ") == "interview-cleanup-pacing")
        #expect(SkillStore.suggestedID(for: "///") == "new-skill")
    }

    @Test @MainActor func newSkillTemplateIsValidBeforeItIsSaved() {
        let parsed = SkillFrontmatter.requiredFields(SkillStore.newSkillTemplate)

        #expect(parsed?.name == "New skill")
        #expect(parsed?.description.isEmpty == false)
    }

    @Test func displayPathUsesTheHomeDirectoryAbbreviation() {
        let path = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".palmier/skills/captions/SKILL.md")
        let skill = Skill(id: "captions", name: "Captions", description: "Create captions.", path: path)

        #expect(skill.displayPath == "~/.palmier/skills/captions")
    }
}
