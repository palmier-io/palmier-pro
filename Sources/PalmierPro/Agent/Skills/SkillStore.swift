import Foundation
import AppKit

/// External coding agents that read the same SKILL.md format from their own folders.
enum SkillExternalAgent: String, CaseIterable, Sendable {
    case claude, codex, cursor

    var label: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }

    var skillsDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claude: return home.appendingPathComponent(".claude/skills", isDirectory: true)
        case .codex: return home.appendingPathComponent(".codex/skills", isDirectory: true)
        case .cursor: return home.appendingPathComponent(".cursor/skills", isDirectory: true)
        }
    }
}

/// Reads skills from `~/.palmier/skills/` (the single source of truth)
@Observable
@MainActor
final class SkillStore {
    static let shared = SkillStore()

    private(set) var skills: [Skill] = []

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".palmier/skills", isDirectory: true)
    }

    private init() { reload() }

    /// Rescans the skills folder
    func reload() {
        let fm = FileManager.default
        var found: [Skill] = []
        if let entries = try? fm.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil) {
            for dir in entries {
                let md = dir.appendingPathComponent("SKILL.md")
                guard let text = try? String(contentsOf: md, encoding: .utf8) else { continue }
                let (fields, _) = SkillFrontmatter.parse(text)
                guard let name = fields["name"], let description = fields["description"] else { continue }
                found.append(Skill(id: dir.lastPathComponent, name: name, description: description, path: md))
            }
        }
        skills = found.sorted { $0.id < $1.id }
    }

    func body(for id: String) -> String? {
        guard let skill = skills.first(where: { $0.id == id }),
              let text = try? String(contentsOf: skill.path, encoding: .utf8)
        else { return nil }
        return SkillFrontmatter.parse(text).body
    }

    /// The always-on index appended to the in-app assistant's system prompt: one line
    /// per skill so the model knows what's available; full bodies load via read_skill.
    var promptIndex: String {
        guard !skills.isEmpty else { return "" }
        let lines = skills.map { "- \($0.id): \($0.description)" }.joined(separator: "\n")
        return """


            # Skills
            Playbooks for specific tasks. Before a task that matches one, call read_skill(id) \
            to load its full procedure, then follow it.
            \(lines)
            """
    }

    func openFolder() {
        try? FileManager.default.createDirectory(
            at: Self.directory, withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(Self.directory)
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func save(_ skill: Skill, raw: String) {
        try? raw.write(to: skill.path, atomically: true, encoding: .utf8)
        reload()
    }

    /// Copies the skill's folder into an external agent's skills directory under a
    /// `palmier-` prefix, so we only ever overwrite our own prior copy — never a
    /// skill the user authored there.
    func copy(_ skill: Skill, to agent: SkillExternalAgent) {
        let source = skill.path.deletingLastPathComponent()
        let dest = agent.skillsDirectory.appendingPathComponent("palmier-\(skill.id)", isDirectory: true)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: agent.skillsDirectory, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: source, to: dest)
            reveal(dest)
        } catch {
            Log.agent.error("copy skill to \(agent.rawValue) failed: \(error.localizedDescription)")
        }
    }

    /// Removes a skill's folder from `~/.palmier/skills/`.
    func delete(_ skill: Skill) {
        try? FileManager.default.removeItem(at: skill.path.deletingLastPathComponent())
        reload()
    }

    /// Scaffolds a new skill folder with a template SKILL.md
    @discardableResult
    func newSkill() -> String? {
        let fm = FileManager.default
        var id = "new-skill"
        var n = 2
        while fm.fileExists(atPath: Self.directory.appendingPathComponent(id).path) {
            id = "new-skill-\(n)"; n += 1
        }
        let dir = Self.directory.appendingPathComponent(id, isDirectory: true)
        let md = dir.appendingPathComponent("SKILL.md")
        let template = """
            ---
            name: New skill
            description: Describe in one line when the assistant should use this skill.
            ---

            ## Workflow
            1. First step.
            2. Second step.
            """
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try template.write(to: md, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        reload()
        reveal(md)
        return id
    }
}
