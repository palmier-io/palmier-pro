import Foundation

/// Action to execute in the EditPilot planner workflow.
enum EditPilotAction: String, Codable, Sendable {
    case propose
    case read
    case review
    case approveAll = "approve_all"
    case apply
}

/// Editorial pacing profile inferred from creative direction or specified explicitly.
enum EditPilotPacing: String, Codable, Sendable, CaseIterable {
    case fast
    case upbeat
    case cinematic
    case relaxed
    case montage

    /// Target clip cut duration range in seconds for this pacing.
    var targetDurationRange: ClosedRange<Double> {
        switch self {
        case .fast: 1.0...2.2
        case .upbeat: 1.8...3.2
        case .cinematic: 3.0...5.5
        case .relaxed: 4.0...7.0
        case .montage: 0.8...1.8
        }
    }

    /// Default cut duration in seconds when no beat sync point is available.
    var defaultCutDurationSeconds: Double {
        switch self {
        case .fast: 1.6
        case .upbeat: 2.2
        case .cinematic: 4.0
        case .relaxed: 5.0
        case .montage: 1.2
        }
    }

    /// Infers pacing from creative direction text.
    static func infer(from direction: String) -> EditPilotPacing {
        let lower = direction.lowercased()
        if lower.contains("montage") || lower.contains("snappy") { return .montage }
        if lower.contains("fast") || lower.contains("speed") || lower.contains("quick") { return .fast }
        if lower.contains("cinematic") || lower.contains("film") || lower.contains("epic") { return .cinematic }
        if lower.contains("relax") || lower.contains("slow") || lower.contains("calm") { return .relaxed }
        return .upbeat
    }
}

/// Lifecycle status of an EditPilot arrangement.
enum EditPilotStatus: String, Codable, Sendable {
    case proposed
    case partiallyApproved = "partially_approved"
    case approved
    case applied
}

/// A suggested edit block in an EditPilot arrangement.
struct EditPilotBlock: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var index: Int
    var mediaRef: String
    var mediaName: String
    var mediaType: ClipType
    var sourceStartSeconds: Double
    var sourceEndSeconds: Double
    var durationSeconds: Double
    var timelineStartFrame: Int
    var timelineEndFrame: Int
    var durationFrames: Int
    var pacing: EditPilotPacing
    var musicSyncBeatIndex: Int?
    var caption: String?
    var captionRole: String?
    var isApproved: Bool
    var notes: String?
}

/// Suggested background music bed and rhythm sync configuration.
struct EditPilotMusicTrack: Codable, Sendable, Equatable {
    var mediaRef: String
    var mediaName: String
    var bpm: Double?
    var startFrame: Int
    var durationFrames: Int
    var volumeDb: Double?
    var beatCount: Int?
}

/// Complete proposed timeline arrangement produced by EditPilot.
struct EditPilotArrangement: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var direction: String
    var timelineId: String
    var fps: Int
    var pacing: EditPilotPacing
    var targetDurationSeconds: Double?
    var totalDurationFrames: Int
    var status: EditPilotStatus
    var blocks: [EditPilotBlock]
    var musicTrack: EditPilotMusicTrack?
    var summary: String
    var appliedClipIds: [String]?

    var canApply: Bool {
        status == .approved || blocks.contains { $0.isApproved }
    }
}

/// Execution receipt returned when an arrangement is applied to the timeline.
struct EditPilotReceipt: Codable, Sendable, Equatable {
    var arrangementId: String
    var status: String
    var action: String
    var blockCount: Int
    var approvedBlockCount: Int
    var totalDurationSeconds: Double
    var totalDurationFrames: Int
    var createdVideoClipIds: [String]
    var createdAudioClipIds: [String]
    var createdTextClipIds: [String]
    var trackIds: [String]
    var undoable: Bool
}

/// Errors raised during EditPilot arrangement planning, review, or application.
enum EditPilotError: Error, LocalizedError, Equatable {
    case arrangementNotFound(String)
    case blockNotFound(String, arrangementId: String)
    case noVisualMediaAvailable
    case duplicateVisualMedia(String)
    case noApprovedBlocks(String)
    case alreadyApplied(String)
    case invalidTrim(start: Double, end: Double)

    var errorDescription: String? {
        switch self {
        case .arrangementNotFound(let id):
            return "EditPilot arrangement '\(id)' not found."
        case .blockNotFound(let blockId, let arrangementId):
            return "Block '\(blockId)' not found in arrangement '\(arrangementId)'."
        case .noVisualMediaAvailable:
            return "No visual media (videos or images) found in the library. Import media into the project before running EditPilot."
        case .duplicateVisualMedia(let mediaRef):
            return "Visual uniqueness violation: mediaRef '\(mediaRef)' is repeated in the arrangement."
        case .noApprovedBlocks(let id):
            return "No approved blocks in arrangement '\(id)'. Review and approve at least one block before applying."
        case .alreadyApplied(let id):
            return "Arrangement '\(id)' has already been applied to the timeline."
        case .invalidTrim(let start, let end):
            return "Invalid source trim range: start \(start) must be less than end \(end)."
        }
    }
}
