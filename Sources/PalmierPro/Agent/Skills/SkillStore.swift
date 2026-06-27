import Foundation
import AppKit
import CryptoKit

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

/// Result of scanning the skills folder, computed off the main actor.
struct SkillScan: Sendable {
    let skills: [Skill]
    let bodies: [String: String]
    let shas: [String: String]
}

/// Reads skills from `~/.palmier/skills/` — the single source of truth.
@Observable
@MainActor
final class SkillStore {
    static let shared = SkillStore()

    private(set) var skills: [Skill] = []

    /// Catalog-installed skills: id → the sha installed. A skill here is "community"; one
    /// in the folder but not here is the user's own.
    private(set) var installed: [String: String] = [:]

    // Filled by a scan so body and content hash are cache lookups, not per-render disk reads.
    private var bodyCache: [String: String] = [:]
    private var shaCache: [String: String] = [:]

    nonisolated static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".palmier/skills", isDirectory: true)
    }

    private static var ledgerURL: URL { directory.appendingPathComponent(".installed.json") }

    private init() { Task { await reloadInBackground() } }

    func reload() { apply(Self.scan()) }

    func reloadInBackground() async {
        let scan = await Task.detached(priority: .utility) { Self.scan() }.value
        apply(scan)
    }

    private func apply(_ scan: SkillScan) {
        skills = scan.skills
        bodyCache = scan.bodies
        shaCache = scan.shas
        installed = Self.loadLedger()
    }

    nonisolated static func scan() -> SkillScan {
        let fm = FileManager.default
        var found: [Skill] = []
        var bodies: [String: String] = [:]
        var shas: [String: String] = [:]
        if let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for dir in entries {
                let md = dir.appendingPathComponent("SKILL.md")
                guard let text = try? String(contentsOf: md, encoding: .utf8) else { continue }
                let (fields, body) = SkillFrontmatter.parse(text)
                guard let name = fields["name"], let description = fields["description"] else { continue }
                let id = dir.lastPathComponent
                found.append(Skill(id: id, name: name, description: description, path: md))
                bodies[id] = body
                shas[id] = sha12(Data(text.utf8))
            }
        }
        return SkillScan(skills: found.sorted { $0.id < $1.id }, bodies: bodies, shas: shas)
    }

    // MARK: Catalog install / ledger

    func localSha(_ skill: Skill) -> String? { shaCache[skill.id] }

    /// Downloads a catalog skill into the folder; also used to apply an update.
    func install(_ entry: SkillCatalogEntry) async {
        guard let url = SkillCatalog.bodyURL(path: entry.path) else { return }
        do {
            let data = try await SkillCatalog.fetch(url)
            let dir = Self.directory.appendingPathComponent(entry.id, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent("SKILL.md"))
            installed[entry.id] = entry.sha
            writeLedger()
            reload()
        } catch {
            Log.agent.error("install skill \(entry.id) failed: \(error.localizedDescription)")
        }
    }

    nonisolated private static func sha12(_ data: Data) -> String {
        String(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    private static func loadLedger() -> [String: String] {
        guard let data = try? Data(contentsOf: ledgerURL),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return map
    }

    private func writeLedger() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(installed) { try? data.write(to: Self.ledgerURL) }
    }

    func body(for id: String) -> String? { bodyCache[id] }

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

    /// Copies under a `palmier-` prefix so we only overwrite our own prior copy, never a
    /// skill the user authored in the target agent's folder.
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

    func delete(_ skill: Skill) {
        try? FileManager.default.removeItem(at: skill.path.deletingLastPathComponent())
        installed[skill.id] = nil
        writeLedger()
        reload()
    }

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
        return id
    }

    /// Updates only the `name` frontmatter field, leaving the rest of the SKILL.md intact.
    func rename(_ skill: Skill, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != skill.name,
              let text = try? String(contentsOf: skill.path, encoding: .utf8) else { return }
        let updated = SkillFrontmatter.replacingName(text, name: trimmed)
        try? updated.write(to: skill.path, atomically: true, encoding: .utf8)
        reload()
    }
}
