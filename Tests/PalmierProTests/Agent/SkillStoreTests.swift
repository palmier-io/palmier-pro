import Foundation
import Testing
@testable import PalmierPro

@Suite("SkillStore")
struct SkillStoreTests {
    @Test func installsBundledSkillIntoEmptyDirectory() throws {
        let root = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("bundle", isDirectory: true)
        let skills = root.appendingPathComponent("skills", isDirectory: true)
        let ledger = root.appendingPathComponent(".bundled.json")
        try writeSkill(source, id: "caption-readability", body: "Use maxCharacters for readable captions.")

        let installed = SkillStore.installBundledSkillsIfNeeded(from: source, skillsRoot: skills, ledgerURL: ledger)

        let copied = try String(contentsOf: skills.appendingPathComponent("caption-readability/SKILL.md"), encoding: .utf8)
        #expect(installed)
        #expect(copied.contains("maxCharacters"))
    }

    @Test func bundledSkillDoesNotOverwriteUserEdit() throws {
        let root = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("bundle", isDirectory: true)
        let skills = root.appendingPathComponent("skills", isDirectory: true)
        let ledger = root.appendingPathComponent(".bundled.json")
        try writeSkill(source, id: "caption-readability", body: "Bundled text.")
        try writeSkill(skills, id: "caption-readability", body: "User edited text.")

        let installed = SkillStore.installBundledSkillsIfNeeded(from: source, skillsRoot: skills, ledgerURL: ledger)

        let kept = try String(contentsOf: skills.appendingPathComponent("caption-readability/SKILL.md"), encoding: .utf8)
        #expect(!installed)
        #expect(kept.contains("User edited text."))
    }

    @Test func bundledSkillUpdatesUnmodifiedPriorBundle() throws {
        let root = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("bundle", isDirectory: true)
        let skills = root.appendingPathComponent("skills", isDirectory: true)
        let ledger = root.appendingPathComponent(".bundled.json")
        try writeSkill(source, id: "caption-readability", body: "Bundled v1.")
        #expect(SkillStore.installBundledSkillsIfNeeded(from: source, skillsRoot: skills, ledgerURL: ledger))

        try writeSkill(source, id: "caption-readability", body: "Bundled v2.")
        let updated = SkillStore.installBundledSkillsIfNeeded(from: source, skillsRoot: skills, ledgerURL: ledger)

        let copied = try String(contentsOf: skills.appendingPathComponent("caption-readability/SKILL.md"), encoding: .utf8)
        #expect(updated)
        #expect(copied.contains("Bundled v2."))
    }

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PalmierProTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSkill(_ root: URL, id: String, body: String) throws {
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let text = """
            ---
            name: Caption readability
            description: Use when generating captions.
            ---

            \(body)
            """
        try text.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }
}
