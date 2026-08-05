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

struct SkillLedger: Equatable, Sendable {
    var installed: [String: String] = [:]
    var suppressed: Set<String> = []
}

private struct PersistedSkillLedger: Codable {
    static let currentVersion = 1

    let version: Int
    let installed: [String: String]
    let suppressed: [String]
}

/// Reads skills from `~/.palmier/skills/` — the single source of truth.
@Observable
@MainActor
final class SkillStore {
    static let shared = SkillStore()

    private(set) var skills: [Skill] = []

    private var ledger: SkillLedger?

    /// Catalog-installed skills: id → the sha installed.
    var installed: [String: String] { ledger?.installed ?? [:] }

    // Filled by a scan so body and content hash are cache lookups, not per-render disk reads.
    private var bodyCache: [String: String] = [:]
    private var shaCache: [String: String] = [:]

    nonisolated static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".palmier/skills", isDirectory: true)
    }

    nonisolated private static var ledgerURL: URL { directory.appendingPathComponent(".installed.json") }

    private var reloadGeneration = 0
    private var syncTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?

    private init() {
        Task { await reloadSkills() }
    }

    private func reloadInBackground() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        let result = await Task.detached(priority: .utility) {
            (Self.scan(), Self.loadLedger())
        }.value
        guard generation == reloadGeneration else { return }
        apply(result.0)
        if let loadedLedger = result.1 {
            ledger = loadedLedger
        } else {
            Log.agent.error("load skill ledger failed")
        }
    }

    func reloadSkills() async {
        _ = await serializeMutation("reload skills") { [self] in
            await reloadInBackground()
        }
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
        guard let parsed = SkillFrontmatter.requiredFields(text) else { return nil }
        return ParsedSkill(
            skill: Skill(id: id, name: parsed.name, description: parsed.description, path: path),
            body: parsed.body,
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

    func startSkillSync() {
        guard syncTask == nil else { return }
        syncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performSkillSync()
            self.syncTask = nil
        }
    }

    func syncSkills() async {
        startSkillSync()
        await syncTask?.value
    }

    func waitForSkillSync() async {
        await syncTask?.value
    }

    func prepareForTermination() async {
        syncTask?.cancel()
        await syncTask?.value
        await mutationTask?.value
    }

    private func performSkillSync() async {
        await reloadSkills()
        guard let ledger, !Task.isCancelled else { return }
        guard await SkillCatalog.shared.refresh() else { return }
        guard !Task.isCancelled else { return }

        for entry in SkillCatalog.shared.entries {
            guard !Task.isCancelled else { return }
            guard automaticallyInstalls(entry, ledger: ledger) else { continue }
            _ = await install(entry, automatically: true)
        }
    }

    private func automaticallyInstalls(_ entry: SkillCatalogEntry, ledger: SkillLedger) -> Bool {
        let skill = skills.first { $0.id == entry.id }
        return Self.shouldAutomaticallyInstall(
            localSHA: skill.flatMap(localSha),
            installedSHA: ledger.installed[entry.id],
            catalogSHA: entry.sha,
            isSuppressed: ledger.suppressed.contains(entry.id)
        )
    }

    nonisolated static func shouldAutomaticallyInstall(
        localSHA: String?,
        installedSHA: String?,
        catalogSHA: String,
        isSuppressed: Bool
    ) -> Bool {
        guard !isSuppressed else { return false }
        guard let localSHA else { return installedSHA == nil }
        guard let installedSHA else { return false }
        return localSHA == installedSHA && installedSHA != catalogSHA
    }

    @discardableResult
    func install(_ entry: SkillCatalogEntry, automatically: Bool = false) async -> Bool {
        guard ledger != nil else { return false }
        guard let url = SkillCatalog.bodyURL(path: entry.path) else { return false }
        guard let dir = Self.skillDirectory(for: entry.id) else {
            Log.agent.error("install skill \(entry.id) rejected: invalid id")
            return false
        }
        do {
            let data = try await SkillCatalog.fetch(url)
            try Task.checkCancellation()
            guard Self.sha12(data) == entry.sha else {
                Log.agent.error("install skill \(entry.id) rejected: catalog hash mismatch")
                return false
            }
            guard let text = String(data: data, encoding: .utf8) else {
                Log.agent.error("install skill \(entry.id) rejected: invalid UTF-8")
                return false
            }
            let md = dir.appendingPathComponent("SKILL.md")
            guard Self.parseSkill(id: entry.id, path: md, text: text) != nil else {
                Log.agent.error("install skill \(entry.id) rejected: missing name or description frontmatter")
                return false
            }
            return await serializeMutation("install skill \(entry.id)") { [self] in
                if automatically {
                    await reloadInBackground()
                }
                guard var ledger else { return false }
                if automatically {
                    guard !Task.isCancelled,
                          automaticallyInstalls(entry, ledger: ledger)
                    else { return false }
                }
                try await Self.performFileOperation {
                    try FileManager.default.createDirectory(
                        at: dir, withIntermediateDirectories: true
                    )
                    try data.write(to: md, options: .atomic)
                }
                await reloadInBackground()
                guard skills.contains(where: { $0.id == entry.id }) else {
                    try? await Self.performFileOperation { try FileManager.default.removeItem(at: dir) }
                    Log.agent.error("install skill \(entry.id) rejected: SKILL.md not recognized after install")
                    return false
                }
                ledger.installed[entry.id] = entry.sha
                ledger.suppressed.remove(entry.id)
                try await Self.persistLedger(ledger)
                self.ledger = ledger
                return true
            } ?? false
        } catch {
            Log.agent.error("install skill \(entry.id) failed: \(error.localizedDescription)")
            return false
        }
    }

    private func serializeMutation<T: Sendable>(
        _ failureContext: String,
        _ operation: @escaping @MainActor @Sendable () async throws -> T
    ) async -> T? {
        let previous = mutationTask
        let task = Task { @MainActor in
            await previous?.value
            return try await operation()
        }
        mutationTask = Task { @MainActor in _ = try? await task.value }
        do {
            return try await task.value
        } catch {
            Log.agent.error("\(failureContext) failed: \(error.localizedDescription)")
            return nil
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

    @concurrent
    private static func performFileOperation<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async rethrows -> T {
        try operation()
    }

    nonisolated private static func loadLedger() -> SkillLedger? {
        guard FileManager.default.fileExists(atPath: ledgerURL.path) else { return SkillLedger() }
        guard let data = try? Data(contentsOf: ledgerURL) else { return nil }
        return decodeLedger(data)
    }

    nonisolated static func decodeLedger(_ data: Data) -> SkillLedger? {
        if let persisted = try? JSONDecoder().decode(PersistedSkillLedger.self, from: data),
           persisted.version == PersistedSkillLedger.currentVersion {
            return SkillLedger(
                installed: persisted.installed,
                suppressed: Set(persisted.suppressed)
            )
        }
        guard let installed = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }
        return SkillLedger(installed: installed)
    }

    @concurrent
    private static func persistLedger(_ ledger: SkillLedger) async throws {
        let persisted = PersistedSkillLedger(
            version: PersistedSkillLedger.currentVersion,
            installed: ledger.installed,
            suppressed: ledger.suppressed.sorted()
        )
        let data = try JSONEncoder().encode(persisted)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: ledgerURL, options: .atomic)
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

    @discardableResult
    func save(_ skill: Skill, raw: String) async -> Bool {
        guard Self.parseSkill(id: skill.id, path: skill.path, text: raw) != nil else { return false }
        return await serializeMutation("save skill \(skill.id)") { [self] in
            try await Self.performFileOperation {
                try Data(raw.utf8).write(to: skill.path, options: .atomic)
            }
            await reloadInBackground()
            return true
        } ?? false
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

    @discardableResult
    func delete(_ skill: Skill) async -> Bool {
        await serializeMutation("delete skill \(skill.id)") { [self] in
            guard var ledger else { return false }
            try await Self.performFileOperation {
                try FileManager.default.removeItem(at: skill.path.deletingLastPathComponent())
            }
            if ledger.installed.removeValue(forKey: skill.id) != nil {
                ledger.suppressed.insert(skill.id)
                try await Self.persistLedger(ledger)
                self.ledger = ledger
            }
            await reloadInBackground()
            return true
        } ?? false
    }

    @discardableResult
    func newSkill() async -> String? {
        await serializeMutation("create skill") { [self] in
            let id = try await Self.performFileOperation { try Self.createSkillFile() }
            await reloadInBackground()
            return id
        }
    }

    nonisolated private static func createSkillFile() throws -> String {
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
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try template.write(to: md, atomically: true, encoding: .utf8)
        return id
    }

    /// Updates only the `name` frontmatter field, leaving the rest of the SKILL.md intact.
    func rename(_ skill: Skill, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != skill.name else { return }
        await serializeMutation("rename skill \(skill.id)") { [self] in
            try await Self.performFileOperation { try Self.renameSkillFile(skill, to: trimmed) }
            await reloadInBackground()
        }
    }

    nonisolated private static func renameSkillFile(_ skill: Skill, to name: String) throws {
        let text = try String(contentsOf: skill.path, encoding: .utf8)
        let updated = SkillFrontmatter.replacingName(text, name: name)
        try updated.write(to: skill.path, atomically: true, encoding: .utf8)
    }
}
