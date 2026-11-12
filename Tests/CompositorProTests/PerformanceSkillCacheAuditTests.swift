import Foundation
import Testing
@testable import CompositorPro

@Suite("Performance skill-cache audit", .serialized)
@MainActor
struct PerformanceSkillCacheAuditTests {
    private nonisolated static let initialSkill = "---\nname: Audit Skill\ndescription: Audit reload.\n---\nVersion alpha."

    @Test func reloadObservesContentReplacementWithPreservedSizeAndModificationDate() async throws {
        try await withStore { store, directory in
            let path = directory.appendingPathComponent("audit-skill/SKILL.md")
            let replacement = Self.initialSkill.replacingOccurrences(of: "alpha", with: "bravo")
            try await Task.detached {
                let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
                guard let modificationDate = attributes[.modificationDate] as? Date else {
                    throw CocoaError(.fileReadUnknown)
                }
                try Data(replacement.utf8).write(to: path, options: .atomic)
                try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: path.path)
            }.value
            await store.reloadSkills()
            let onDisk = try await Task.detached { try String(contentsOf: path, encoding: .utf8) }.value
            #expect(onDisk.contains("Version bravo."))
            #expect(store.body(for: "audit-skill") == "Version bravo.")
        }
    }

    @Test func reloadObservesLedgerChangesWithoutSkillChanges() async throws {
        try await withStore { store, directory in
            #expect(store.installed["audit-skill"] == "old")
            let path = directory.appendingPathComponent(".installed.json")
            try await Task.detached {
                try Data(#"{"version":1,"installed":{"audit-skill":"new"},"suppressed":[]}"#.utf8)
                    .write(to: path, options: .atomic)
            }.value
            await store.reloadSkills()
            let onDisk = try await Task.detached { try Data(contentsOf: path) }.value
            #expect(SkillStore.decodeLedger(onDisk)?.installed["audit-skill"] == "new")
            #expect(store.installed["audit-skill"] == "new")
        }
    }

    @Test func reloadObservesContentWithChangedSize() async throws {
        try await withStore { store, directory in
            let path = directory.appendingPathComponent("audit-skill/SKILL.md")
            let replacement = Self.initialSkill.replacingOccurrences(of: "alpha", with: "much longer")
            try await Task.detached { try Data(replacement.utf8).write(to: path, options: .atomic) }.value
            await store.reloadSkills()
            #expect(store.body(for: "audit-skill") == "Version much longer.")
        }
    }

    private func withStore(_ body: @MainActor (SkillStore, URL) async throws -> Void) async throws {
        let directory = try await Task.detached {
            let directory = URL(fileURLWithPath: "/private/var/folders/3v/qg3xv_lj5wz8_83qnp3zz6yc0000gn/T/opencode")
                .appendingPathComponent("performance-skill-cache-\(UUID().uuidString)", isDirectory: true)
            let skillDirectory = directory.appendingPathComponent("audit-skill", isDirectory: true)
            try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
            try Data(Self.initialSkill.utf8).write(to: skillDirectory.appendingPathComponent("SKILL.md"))
            try Data(#"{"version":1,"installed":{"audit-skill":"old"},"suppressed":[]}"#.utf8)
                .write(to: directory.appendingPathComponent(".installed.json"))
            return directory
        }.value
        let store = SkillStore(directory: directory, includeBuiltins: false)
        do {
            await store.reloadSkills()
            try await body(store, directory)
            await store.prepareForTermination()
            try await Task.detached { try FileManager.default.removeItem(at: directory) }.value
        } catch {
            await store.prepareForTermination()
            try await Task.detached { try FileManager.default.removeItem(at: directory) }.value
            throw error
        }
    }
}
