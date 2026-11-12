import Foundation

enum VisualUniquenessValidationError: Error, LocalizedError {
    case staleSnapshot

    var errorDescription: String? {
        "Timeline or media changed during visual identity review; retry against current state."
    }
}

struct VisualReviewRevision: Sendable, Equatable {
    let timelineId: String
    let timelineRevision: Int
    let manifestRevision: UInt64
    let projectURL: URL?
}

extension EditorViewModel {
    var visualReviewRevision: VisualReviewRevision {
        VisualReviewRevision(timelineId: activeTimelineId, timelineRevision: timelineRenderRevision,
                             manifestRevision: mediaManifestRevision, projectURL: projectURL)
    }

    func visualUniquenessReport(
        audit: @Sendable (Timeline, [Timeline], MediaManifest) async throws -> VisualUniquenessReport = {
            try await VisualUniqueness.audit(timeline: $0, timelines: $1, manifest: $2)
        }
    ) async throws -> VisualUniquenessReport {
        let timeline = timeline
        let timelines = timelines
        let manifest = mediaManifest
        let revision = visualReviewRevision
        let report = try await audit(timeline, timelines, manifest)
        try Task.checkCancellation()
        guard visualReviewRevision == revision else {
            throw VisualUniquenessValidationError.staleSnapshot
        }
        return report
    }
}
