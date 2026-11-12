import Foundation

/// A compact, machine-readable snapshot of editing progress stored alongside chat sessions.
/// A new chat loads this instead of replaying full history, so the agent can resume
/// editing with minimal context. Kept small on purpose — only what another agent needs
/// to continue the edit.
struct EditingProgressSummary: Codable, Sendable, Equatable {
    /// Timeline shape.
    struct Timeline: Codable, Sendable, Equatable {
        var durationSeconds: Double
        var trackCount: Int
        var clipCount: Int
        var fps: Int
        var resolution: String
    }

    /// Current selection by stable clip id.
    var selection: [String] = []

    /// Timeline shape snapshot.
    var timeline: Timeline = .init(durationSeconds: 0, trackCount: 0, clipCount: 0, fps: 30, resolution: "1920x1080")

    /// Playhead position in project seconds.
    var playheadSeconds: Double = 0

    /// Editorial phase (free-form, not localized — it is a machine contract).
    var phase: String = "idle"

    /// Completed work items.
    var completed: [String] = []

    /// Work currently in progress.
    var inProgress: String = ""

    /// Blockers, if any.
    var blocked: [String] = []

    /// Planned next steps.
    var next: [String] = []

    /// Recent edits, most recent first, capped. Each entry: tool, target id, note.
    var recentEdits: [EditEntry] = []

    /// Human-readable handoff note for the next agent turn (not localized).
    var handoffNote: String = ""

    var updatedAt: Date = Date()

    struct EditEntry: Codable, Sendable, Equatable {
        var tool: String
        var target: String?
        var note: String?
        var at: Date
    }
}

/// Persists EditingProgressSummary to the project package `chat/` directory.
/// All file I/O happens off the main actor via Task.detached. Single owner of this file.
enum EditingProgressStore {
    static let fileName = "editing-progress.json"

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Load the summary for a project, or return an empty one when none exists.
    /// Runs off the main actor.
    static func load(from projectURL: URL?) async -> EditingProgressSummary {
        guard let projectURL else { return EditingProgressSummary() }
        let file = projectURL.appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
        return await withCheckedContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                let summary: EditingProgressSummary
                if let data = try? Data(contentsOf: file),
                   let decoded = try? decoder.decode(EditingProgressSummary.self, from: data) {
                    summary = decoded
                } else {
                    summary = EditingProgressSummary()
                }
                continuation.resume(returning: summary)
            }
        }
    }

    /// Save the summary off the main actor. Use `Task.detached` from a MainActor context.
    static func save(_ summary: EditingProgressSummary, to projectURL: URL?) async {
        guard let projectURL else { return }
        let dir = projectURL.appendingPathComponent("chat", isDirectory: true)
        let file = dir.appendingPathComponent(fileName, isDirectory: false)
        guard let data = try? encoder.encode(summary) else { return }
        await withCheckedContinuation { continuation in
            Task.detached(priority: .utility) {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
                continuation.resume(returning: ())
            }
        }
    }
}
