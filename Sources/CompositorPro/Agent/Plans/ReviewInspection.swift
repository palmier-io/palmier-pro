import Foundation

/// One recorded `review_timeline` inspection. Inspections are evidence, not edits: they are kept
/// with the plan so export and delivery checks can tell which output was actually reviewed.
struct ReviewInspection: Codable, Sendable, Equatable {
    static let maximumRetained = 32

    var inspectionId: String
    var startFrame: Int
    var endFrame: Int
    /// Output revision of the render that was inspected, so stale evidence is recognizable.
    var outputRevision: String
    var reviewedAt: Date
    var sampledFrames: [Int]
    var qualityWarnings: [String]

    init(startFrame: Int, endFrame: Int, outputRevision: String, reviewedAt: Date = Date(),
         sampledFrames: [Int], qualityWarnings: [String]) {
        self.inspectionId = UUID().uuidString
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.outputRevision = outputRevision
        self.reviewedAt = reviewedAt
        self.sampledFrames = sampledFrames
        self.qualityWarnings = qualityWarnings
    }

    var coversWholeOutput: Bool { true }

    /// Newest-first, deduplicated by range and output revision, capped.
    static func appending(_ inspection: ReviewInspection, to existing: [ReviewInspection]) -> [ReviewInspection] {
        var next = existing.filter {
            !($0.startFrame == inspection.startFrame && $0.endFrame == inspection.endFrame
              && $0.outputRevision == inspection.outputRevision)
        }
        next.insert(inspection, at: 0)
        return Array(next.prefix(maximumRetained))
    }
}
