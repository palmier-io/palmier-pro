import AVFoundation
import Foundation

extension ToolExecutor {
    private struct ReviewTimelineInput: DecodableToolArgs {
        let startFrame: Int?
        let endFrame: Int?
        static let allowedKeys: Set<String> = ["startFrame", "endFrame"]
    }

    func reviewTimeline(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: ReviewTimelineInput = try decodeToolArgs(args, path: "review_timeline")
        let timeline = editor.timeline
        let start = input.startFrame ?? 0
        let end = input.endFrame ?? timeline.totalFrames
        guard (1...120).contains(timeline.fps), start >= 0, end > start,
              end <= timeline.totalFrames, end - start <= 60 * timeline.fps else {
            throw ToolError("review_timeline: select a nonempty range inside the timeline, at most 60 seconds")
        }
        let resolveTimeline = editor.timelineResolver()
        let involved = [timeline] + timeline.reachableTimelines(resolve: resolveTimeline)
        let urls = editor.mediaResolver.expectedURLMap()
        let url = try await TimelineRenderer.render(
            timeline: timeline, resolver: editor.mediaResolver.snapshot(), resolveTimeline: resolveTimeline,
            missingMediaRefs: editor.missingMediaRefs, startFrame: start, frameCount: end - start,
            shortSide: 720, preset: AVAssetExportPresetHighestQuality
        )
        do {
            let review = try await RenderedTimelineReview.inspect(url: url, frameCount: end - start, fps: timeline.fps)
            try Task.checkCancellation()
            guard editor.timeline.id == timeline.id,
                  involved.allSatisfy({ editor.timeline(for: $0.id) == $0 }),
                  editor.mediaResolver.expectedURLMap() == urls else {
                throw ToolError("review_timeline: timeline or sources changed during rendering; review again")
            }
            var metadata: [String: Any] = [
                "timelineId": timeline.id, "startFrame": start, "endFrame": end, "path": url.path,
                "durationSeconds": review.durationSeconds, "hasAudio": review.loudness != nil,
                "sampledFrames": review.frames.map { start + $0 },
                "clippedSamples": review.clippedSamples,
                "reviewScope": "encoded_stills_and_audio_metrics",
            ]
            if let loudness = review.loudness {
                metadata["loudnessStatus"] = loudness.status.rawValue
                metadata["integratedLUFS"] = loudness.integratedLUFS as Any? ?? NSNull()
            }
            metadata["samplePeakDBFS"] = review.peakDBFS as Any? ?? NSNull()
            guard let receipt = Self.jsonString(metadata) else { throw ToolError("review_timeline: metadata encoding failed") }
            return ToolResult(content: review.images.map { .image(base64: $0.base64EncodedString(), mediaType: "image/jpeg") }
                              + [.text(receipt)], isError: false)
        } catch {
            await TimelineRenderer.removeTemporaryRender(url)
            throw error
        }
    }
}
