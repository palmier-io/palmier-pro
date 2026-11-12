import AVFoundation

enum AudioMixAnalyzer {
    private static let gate = AsyncSemaphore(value: 1)

    @concurrent
    static func measure(
        timeline: Timeline, timelines: [Timeline], urls: [String: URL], range: Range<Int>? = nil
    ) async throws -> AudioMeasurement {
        try Task.checkCancellation()
        try await gate.wait()
        do {
            let result = try await read(timeline: timeline, timelines: timelines, urls: urls, range: range)
            await gate.signal()
            return result
        } catch {
            await gate.signal()
            throw error
        }
    }

    private static func read(
        timeline: Timeline, timelines: [Timeline], urls: [String: URL], range: Range<Int>?
    ) async throws -> AudioMeasurement {
        guard Set(timelines.map(\.id)).count == timelines.count else {
            throw AudioFinishingError(reason: "Nested timeline IDs must be unique.")
        }
        let children = Dictionary(uniqueKeysWithValues: timelines.map { ($0.id, $0) })
        let resolve: @Sendable (String) -> Timeline? = { children[$0] }
        var visiting = Set<String>()
        var validated = Set<String>()
        func validate(_ value: Timeline, depth: Int) throws {
            guard !visiting.contains(value.id), depth <= NestFlattener.maxDepth else {
                throw AudioFinishingError(reason: "Audio nesting contains a cycle or exceeds the depth limit.")
            }
            if validated.contains(value.id) { return }
            visiting.insert(value.id)
            defer { visiting.remove(value.id) }
            guard (1...120).contains(value.fps), value.width > 0, value.height > 0 else {
                throw AudioFinishingError(reason: "Invalid audio timeline settings.")
            }
            for track in value.tracks {
                var end = 0
                for clip in track.clips.sorted(by: { $0.startFrame < $1.startFrame }) {
                    guard clip.startFrame >= 0, clip.durationFrames > 0, clip.durationFrames < maxFrameArg,
                          !clip.startFrame.addingReportingOverflow(clip.durationFrames).overflow,
                          clip.endFrame < maxFrameArg else { throw AudioFinishingError(reason: "Invalid audio clip range.") }
                    if track.type == .audio, !track.muted {
                        guard clip.startFrame >= end else {
                            throw AudioFinishingError(reason: "Audio clips overlap on track '\(track.id)'; place overlaps on separate tracks.")
                        }
                        end = clip.endFrame
                        guard clip.volume.isFinite, clip.volume >= 0 else {
                            throw AudioFinishingError(reason: "Invalid volume on clip '\(clip.id)'.")
                        }
                        try PreparedAudio.validateProcessing(clip)
                        _ = try LoudnessAnalyzer.sourceRange(for: clip, fps: value.fps)
                        guard clip.trimEndFrame >= 0, clip.fadeInFrames >= 0, clip.fadeOutFrames >= 0,
                              clip.fadeInFrames <= clip.durationFrames,
                              clip.fadeOutFrames <= clip.durationFrames - clip.fadeInFrames,
                              (clip.volumeTrack?.keyframes ?? []).allSatisfy({
                                  $0.frame >= 0 && $0.frame <= clip.durationFrames && $0.value.isFinite
                              }) else { throw AudioFinishingError(reason: "Invalid audio envelope on clip '\(clip.id)'.") }
                        if clip.sourceClipType == .sequence {
                            guard clip.speed == 1, clip.speedTrack == nil, clip.freezeFrames == 0,
                                  let child = children[clip.mediaRef], child.fps == value.fps else {
                                throw AudioFinishingError(reason: "Audio nest '\(clip.id)' is missing or has unsupported timing.")
                            }
                            try validate(child, depth: depth + 1)
                        }
                    }
                }
            }
            validated.insert(value.id)
        }
        try validate(timeline, depth: 0)
        let window = range ?? 0..<timeline.totalFrames
        guard window.lowerBound >= 0, window.upperBound < maxFrameArg, !window.isEmpty else {
            throw AudioFinishingError(reason: "Select a nonempty, bounded audio range.")
        }
        let clips = PreparedAudio.audibleClips(timeline: timeline, resolveTimeline: resolve)
        let versions = try await LoudnessAnalyzer.sourceVersions(for: try clips.map { clip in
            guard let url = urls[clip.mediaRef] else { throw AudioMixError.sourceUnavailable(clip.mediaRef) }
            return url
        })
        for clip in clips {
            try Task.checkCancellation()
            guard let url = urls[clip.mediaRef] else { throw AudioMixError.sourceUnavailable(clip.mediaRef) }
            let sourceRange = try LoudnessAnalyzer.sourceRange(for: clip, fps: timeline.fps)
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                throw AudioMixError.sourceUnavailable(clip.mediaRef)
            }
            let available = try await track.load(.timeRange)
            let sourceTimescale = try await track.load(.naturalTimeScale)
            guard sourceTimescale > 0 else { throw AudioMixError.sourceUnavailable(clip.mediaRef) }
            let tolerance = CMTime(value: 1, timescale: sourceTimescale)
            guard sourceRange.start >= available.start, sourceRange.end <= available.end + tolerance else {
                throw AudioFinishingError(reason: "Clip '\(clip.id)' requests audio outside its source duration.")
            }
        }
        let result = try await CompositionBuilder.buildAudio(timeline: timeline, resolveURL: { urls[$0] }, resolveTimeline: resolve)
        guard result.offlineMediaRefs.isEmpty, result.unprocessableMediaRefs.isEmpty else {
            throw AudioFinishingError(reason: "Audio composition contains missing or unreadable media.")
        }
        var accumulator = AudioMeasurementAccumulator()
        try await AudioTrackReader.readMix(
            from: result.composition, audioMix: result.audioMix,
            timeRange: CMTimeRange(start: CMTime(value: Int64(window.lowerBound), timescale: Int32(timeline.fps)),
                                   end: CMTime(value: Int64(window.upperBound), timescale: Int32(timeline.fps))),
            contentRanges: result.audioContentRanges
        ) { try accumulator.consume($0) }
        try AudioGainTap.validate(result.audioMix)
        let measurement = accumulator.measurement
        let expected = Double(window.count) / Double(timeline.fps)
        guard abs(measurement.loudness.durationSeconds - expected) <= 1 / LoudnessMeter.sampleRate else {
            throw AudioFinishingError(reason: "Mixed audio did not cover the requested duration.")
        }
        try Task.checkCancellation()
        try await LoudnessAnalyzer.validateSourceVersions(versions)
        return measurement
    }
}
