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
        let audibleClips = involved.flatMap { PreparedAudio.audibleClips(timeline: $0, resolveTimeline: resolveTimeline) }
        if !audibleClips.isEmpty {
            try await editor.awaitEnhancementJobsForClips(Set(audibleClips.map(\.id)))
        }
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
            let versions = try await LoudnessAnalyzer.sourceVersions(for: involved.flatMap { t in
                t.tracks.flatMap(\.clips).compactMap { urls[$0.mediaRef] }
            })
            let stringVersions = Dictionary(uniqueKeysWithValues: versions.map { ($0.key.absoluteString, $0.value) })
            let outputRevision = try await TimelineOutputRevision.make(timeline: timeline, timelines: involved, sources: stringVersions)

            var warnings: [String] = []
            if review.clippedSamples > 0 || (review.peakDBFS ?? -99) >= 0.0 {
                warnings.append("audioClipping")
            }

            // Check if loud background music/ambience masks voice
            let allAudible = involved.flatMap { PreparedAudio.audibleClips(timeline: $0, resolveTimeline: resolveTimeline) }
            let voiceClips = allAudible.filter { $0.mediaRef.contains("voice") || $0.mediaRef.contains("narrat") || $0.id.hasPrefix("narration") }
            let backgroundClips = allAudible.filter { $0.mediaRef.contains("music") || $0.mediaRef.contains("bed") || $0.mediaRef.contains("ambien") }
            if !voiceClips.isEmpty && !backgroundClips.isEmpty {
                let maxVoiceVol = voiceClips.map(\.volume).max() ?? 1.0
                let maxBgVol = backgroundClips.map(\.volume).max() ?? 0.0
                if maxBgVol > maxVoiceVol * 0.7 {
                    warnings.append("musicMaskingNarration")
                }
            }

            var metadata: [String: Any] = [
                "timelineId": timeline.id, "startFrame": start, "endFrame": end, "path": url.path,
                "outputRevision": outputRevision,
                "durationSeconds": review.durationSeconds, "hasAudio": review.loudness != nil,
                "sampledFrames": review.frames.map { start + $0 },
                "clippedSamples": review.clippedSamples,
                "qualityWarnings": warnings,
                "reviewScope": "encoded_stills_and_audio_metrics",
            ]
            if let loudness = review.loudness {
                metadata["loudnessStatus"] = loudness.status.rawValue
                metadata["integratedLUFS"] = loudness.integratedLUFS as Any? ?? NSNull()
                metadata["truePeakDBTP"] = loudness.truePeakDBFS as Any? ?? NSNull()
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
