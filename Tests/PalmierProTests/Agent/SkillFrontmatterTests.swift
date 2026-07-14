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
}
