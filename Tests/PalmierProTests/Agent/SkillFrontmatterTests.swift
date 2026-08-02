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

    @Test func foldsBlockScalarDescriptions() {
        let folded = """
            ---
            name: viral-attention
            description: >-
              Win the first 2 seconds.
              Use for Reels and TikToks.
            ---

            Instructions
            """
        let parsed = SkillFrontmatter.requiredFields(folded)
        #expect(parsed?.description == "Win the first 2 seconds. Use for Reels and TikToks.")
        #expect(parsed?.body == "Instructions")
    }
}
