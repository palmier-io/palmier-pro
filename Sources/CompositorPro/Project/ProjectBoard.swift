import AVFoundation
import Foundation

/// Read-only derivation of a project's board state — ported from OpenMontage's
/// `backlot/state.py` "never block, never break" principle.
///
/// `ProjectBoard` summarizes a project for library/sidebar surfaces: a stage rail
/// (inferred from timeline content), media discovery (renders and loose assets on
/// disk), last-activity / "live" tracking, and stall detection. It never throws —
/// malformed or missing files degrade the board gracefully instead of crashing.
///
/// All filesystem work reads only; nothing is written. Call from off the main actor
/// when the project URL is on a slow or removable volume.
struct ProjectBoard {

    /// One entry in the project's stage rail.
    struct StageEntry: Sendable, Equatable {
        var name: String
        /// pending / in_progress / completed
        var status: String
        var gated: Bool
        /// Human-readable detail (e.g. clip count, duration, render count).
        var detail: String
    }

    /// Discovered render/output media near the project.
    struct BoardMedia: Sendable, Equatable {
        var renders: [String]       // project-relative paths
        var snapshots: [String]     // project-relative image paths
        var audio: [String]         // project-relative audio paths
        var renderCount: Int { renders.count }
    }

    /// Full board summary for one project.
    struct Summary: Sendable, Equatable {
        var projectId: String
        var name: String
        var url: URL
        var stageRail: [StageEntry]
        var media: BoardMedia
        var lastActivity: Date?
        /// True when some project file changed within the live window.
        var live: Bool
        /// True when the current stage appears stalled (in_progress with no recent activity).
        var stalled: Bool
        var stalledMinutes: Int?
        var clipCount: Int
        var durationSeconds: Double
    }

    /// How long without filesystem activity before a board reads "idle".
    static let liveWindowSeconds: Double = 5 * 60
    /// An in-progress stage with no activity this long is flagged stalled.
    static let stallWindowSeconds: Double = 10 * 60

    /// Extensions treated as renders/snapshots/audio during media discovery.
    private static let renderExtensions: Set<String> = ["mp4", "mov", "m4v", "webm"]
    private static let snapshotExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "gif"]
    private static let audioExtensions: Set<String> = ["mp3", "wav", "m4a", "aac", "ogg"]

    /// Derives a read-only board summary from a project URL and its timeline.
    /// Never throws; unreadable files degrade to empty/nil values.
    static func summary(projectURL: URL, timeline: Timeline) -> Summary {
        let projectId = projectURL.deletingPathExtension().lastPathComponent
        let name = projectURL.deletingPathExtension().lastPathComponent
        let stageRail = stageRail(for: timeline)
        let media = scanMedia(projectURL: projectURL)
        let lastActivity = lastActivity(projectURL: projectURL, media: media)
        let now = Date()
        let live = lastActivity.map { now.timeIntervalSince($0) < Self.liveWindowSeconds } ?? false
        let current = stageRail.first { $0.status != "completed" }
        let stalled = current.map { stage in
            stage.status == "in_progress"
                && (lastActivity.map { now.timeIntervalSince($0) > Self.stallWindowSeconds } ?? false)
        } ?? false
        let stalledMinutes = stalled ? lastActivity.map { Int(now.timeIntervalSince($0) / 60) } : nil
        let clipCount = timeline.tracks.reduce(0) { $0 + $1.clips.count }
        let durationSeconds = timeline.totalDurationSeconds

        return Summary(
            projectId: projectId,
            name: name,
            url: projectURL,
            stageRail: stageRail,
            media: media,
            lastActivity: lastActivity,
            live: live,
            stalled: stalled,
            stalledMinutes: stalledMinutes,
            clipCount: clipCount,
            durationSeconds: durationSeconds
        )
    }

    // MARK: - Stage rail (inferred from timeline content)

    private static func stageRail(for timeline: Timeline) -> [StageEntry] {
        let hasClips = timeline.tracks.contains { !$0.clips.isEmpty }
        let hasAudio = timeline.tracks.contains { $0.type == .audio && !$0.clips.isEmpty }
        let hasText = timeline.tracks.contains {
            ($0.type == .text || $0.type == .subtitle) && !$0.clips.isEmpty
        }
        let totalDuration = timeline.totalDurationSeconds > 0

        let imported = StageEntry(
            name: "Media imported",
            status: hasClips ? "completed" : "pending",
            gated: false,
            detail: "\(timeline.tracks.count) track(s), \(hasClips ? "clips present" : "no clips yet")"
        )
        let arranged = StageEntry(
            name: "Timeline arranged",
            status: totalDuration ? "completed" : "pending",
            gated: false,
            detail: durationString(timeline.totalDurationSeconds)
        )
        let mixed = StageEntry(
            name: "Audio mixed",
            status: hasAudio ? "completed" : "pending",
            gated: false,
            detail: hasAudio ? "audio clips present" : "no audio clips"
        )
        let captioned = StageEntry(
            name: "Captions added",
            status: hasText ? "completed" : "pending",
            gated: false,
            detail: hasText ? "text/subtitle clips present" : "no text or subtitle clips"
        )
        return [imported, arranged, mixed, captioned]
    }

    private static func durationString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let m = total / 60, s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Media discovery (read-only)

    private static func scanMedia(projectURL: URL) -> BoardMedia {
        var renders: [String] = []
        var snapshots: [String] = []
        var audio: [String] = []

        var candidates = [projectURL]
        let parent = projectURL.deletingLastPathComponent()
        if parent != projectURL {
            for sub in ["exports", "renders", "output", "Media"] {
                let d = parent.appendingPathComponent(sub)
                if FileManager.default.fileExists(atPath: d.path) { candidates.append(d) }
            }
        }

        for candidate in candidates {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: candidate, includingPropertiesForKeys: [.contentModificationDateKey])
            else { continue }
            for url in urls where url.hasDirectoryPath == false {
                let ext = url.pathExtension.lowercased()
                let rel = relativePath(from: projectURL, to: url)
                if renderExtensions.contains(ext) {
                    renders.append(rel)
                } else if snapshotExtensions.contains(ext) {
                    snapshots.append(rel)
                } else if audioExtensions.contains(ext) {
                    audio.append(rel)
                }
            }
        }

        renders.sort(); snapshots.sort(); audio.sort()
        return BoardMedia(renders: renders, snapshots: snapshots, audio: audio)
    }

    private static func relativePath(from base: URL, to url: URL) -> String {
        let basePath = base.standardizedFileURL.path
        let urlPath = url.standardizedFileURL.path
        guard urlPath.hasPrefix(basePath + "/") else { return url.lastPathComponent }
        return String(urlPath.dropFirst(basePath.count + 1))
    }

    // MARK: - Last activity

    private static func lastActivity(projectURL: URL, media: BoardMedia) -> Date? {
        var latest: Date?
        let files: [URL] = [projectURL.appendingPathComponent("project.json")]
        for f in files where FileManager.default.fileExists(atPath: f.path) {
            latest = maxOpt(latest, mtime(of: f))
        }
        // Renders' mtimes count as activity too (they're derived from the project).
        for rel in media.renders {
            let url = projectURL.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: url.path) {
                latest = maxOpt(latest, mtime(of: url))
            }
        }
        return latest
    }

    private static func mtime(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func maxOpt(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case (nil, let b?): return b
        case (let a?, nil): return a
        case (let a?, let b?): return max(a, b)
        case (nil, nil): return nil
        }
    }
}

private extension Timeline {
    /// Total timeline duration in seconds (longest track end).
    var totalDurationSeconds: Double {
        guard fps > 0 else { return 0 }
        let maxFrame = tracks.reduce(0) { max($0, $1.endFrame) }
        return Double(maxFrame) / Double(fps)
    }
}
