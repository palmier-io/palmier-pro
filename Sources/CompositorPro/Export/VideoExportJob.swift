import Foundation

/// Shared submission path for a video export.
///
/// The export panel, the agent's export tool, and the production coordinator all
/// deliver the same timeline, so they share one submission contract instead of
/// each enqueueing on its own.
enum VideoExportJob {
    struct Request: Sendable {
        var timeline: Timeline
        var format: ExportFormat
        var resolution: ExportResolution
        var fcpxmlTarget: FCPXMLTarget
        var outputURL: URL
        var source: ExportJobSource
        var warnings: [String] = []
    }

    @MainActor
    static func submit(
        editor: EditorViewModel,
        queue: ExportQueue,
        request: Request
    ) async throws -> ExportQueueSubmission {
        let resolveTimeline = editor.timelineResolver()
        let audibleClips = PreparedAudio.audibleClips(timeline: request.timeline, resolveTimeline: resolveTimeline)
        if !audibleClips.isEmpty {
            try await editor.awaitEnhancementJobsForClips(Set(audibleClips.map(\.id)))
        }
        return try queue.enqueueVideo(
            timeline: request.timeline,
            resolver: editor.mediaResolver,
            resolveTimeline: resolveTimeline,
            format: request.format,
            resolution: request.resolution,
            fcpxmlTarget: request.fcpxmlTarget,
            missingMediaRefs: editor.missingMediaRefs,
            outputURL: request.outputURL,
            source: request.source,
            projectID: editor.exportQueueProjectID,
            analyticsProjectID: editor.projectId,
            warnings: request.warnings,
            prepareProcessing: { [weak editor] in
                try await editor?.awaitEnhancementJobsForTimeline(request.timeline)
            }
        )
    }
}
