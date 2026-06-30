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

    private var reloadGeneration = 0

    private init() {
        installed = Self.loadLedger()
        Task { await reloadInBackground() }
    }

    func reload() {
        reloadGeneration += 1
        apply(Self.scan())
    }

    func reloadInBackground() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        let scan = await Task.detached(priority: .utility) { Self.scan() }.value
        guard generation == reloadGeneration else { return }
        apply(scan)
    }

    private func apply(_ scan: SkillScan) {
        skills = scan.skills
        bodyCache = scan.bodies
        shaCache = scan.shas
    }

    /// Parsed contents of one SKILL.md when it passes the same checks as `scan`.
    private struct ParsedSkill: Sendable {
        let skill: Skill
        let body: String
        let sha: String
    }

    nonisolated private static func parseSkill(id: String, path: URL, text: String) -> ParsedSkill? {
        let (fields, body) = SkillFrontmatter.parse(text)
        guard let name = fields["name"], let description = fields["description"] else { return nil }
        return ParsedSkill(
            skill: Skill(id: id, name: name, description: description, path: path),
            body: body,
            sha: sha12(Data(text.utf8))
        )
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
                let id = dir.lastPathComponent
                guard let parsed = parseSkill(id: id, path: md, text: text) else { continue }
                found.append(parsed.skill)
                bodies[id] = parsed.body
                shas[id] = parsed.sha
            }
        }
        return SkillScan(skills: found.sorted { $0.id < $1.id }, bodies: bodies, shas: shas)
    }

    // MARK: Catalog install / ledger

    func localSha(_ skill: Skill) -> String? { shaCache[skill.id] }

    @discardableResult
    func install(_ entry: SkillCatalogEntry) async -> Bool {
        guard let url = SkillCatalog.bodyURL(path: entry.path) else { return false }
        guard let dir = Self.skillDirectory(for: entry.id) else {
            Log.agent.error("install skill \(entry.id) rejected: invalid id")
            return false
        }
        do {
            let data = try await SkillCatalog.fetch(url)
            guard let text = String(data: data, encoding: .utf8) else {
                Log.agent.error("install skill \(entry.id) rejected: invalid UTF-8")
                return false
            }
            let md = dir.appendingPathComponent("SKILL.md")
            guard Self.parseSkill(id: entry.id, path: md, text: text) != nil else {
                Log.agent.error("install skill \(entry.id) rejected: missing name or description frontmatter")
                return false
            }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: md)
            reload()
            guard skills.contains(where: { $0.id == entry.id }) else {
                try? FileManager.default.removeItem(at: dir)
                Log.agent.error("install skill \(entry.id) rejected: SKILL.md not recognized after install")
                return false
            }
            installed[entry.id] = entry.sha
            writeLedger()
            return true
        } catch {
            Log.agent.error("install skill \(entry.id) failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Resolves `~/.palmier/skills/<id>/` only when `id` is a single safe path component.
    nonisolated static func skillDirectory(for id: String) -> URL? {
        guard isValidSkillId(id) else { return nil }
        let dir = directory.appendingPathComponent(id, isDirectory: true).standardizedFileURL
        guard isUnderSkillsRoot(dir) else { return nil }
        return dir
    }

    nonisolated private static func isValidSkillId(_ id: String) -> Bool {
        guard !id.isEmpty, id != ".", id != ".." else { return false }
        guard !id.contains("/"), !id.contains("\\") else { return false }
        return true
    }

    nonisolated private static func isUnderSkillsRoot(_ url: URL) -> Bool {
        let root = directory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
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

    /// One-line list of skills; full content loads on demand.
    var skillIndex: String {
        skills.map { "- \($0.id): \($0.description)" }.joined(separator: "\n")
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

    /// Copies under a `palmier-` prefix so we only overwrite our own prior copy
    @discardableResult
    func copy(_ skill: Skill, to agent: SkillExternalAgent) -> URL? {
        let source = skill.path.deletingLastPathComponent()
        let dest = agent.skillsDirectory.appendingPathComponent("palmier-\(skill.id)", isDirectory: true)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: agent.skillsDirectory, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: source, to: dest)
            return dest
        } catch {
            Log.agent.error("copy skill to \(agent.rawValue) failed: \(error.localizedDescription)")
            return nil
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
