import Foundation

enum AudioMixFinisher {
    struct Input: Sendable {
        let timeline: Timeline
        let timelines: [Timeline]
        let urls: [String: URL]
    }

    struct Result: Sendable {
        let timeline: Timeline
        let receipt: AudioMixReceipt
    }

    typealias Measurement = @Sendable (Timeline, [Timeline], [String: URL], Range<Int>?) async throws -> AudioMeasurement
    typealias SpeechAnalysis = @Sendable ([AudioSpeechTiming.Source], Int) async throws -> AudioSpeechTiming.Result

    private static let gate = AsyncSemaphore(value: 1)

    @concurrent
    static func finish(
        _ input: Input, request: AudioMixRequest, replaceAutomation: Bool,
        measure: Measurement = { try await AudioMixAnalyzer.measure(timeline: $0, timelines: $1, urls: $2, range: $3) },
        speech: SpeechAnalysis = { try await AudioSpeechTiming.analyze($0, fps: $1) }
    ) async throws -> Result {
        try Task.checkCancellation()
        try await gate.wait()
        do {
            let result = try await prepare(input, request: request, replaceAutomation: replaceAutomation, measure: measure, speech: speech)
            await gate.signal()
            return result
        } catch {
            await gate.signal()
            throw error
        }
    }

    private static func prepare(
        _ input: Input, request rawRequest: AudioMixRequest, replaceAutomation: Bool,
        measure: Measurement, speech: SpeechAnalysis
    ) async throws -> Result {
        let request = try rawRequest.validated()
        let original = input.timeline
        let locations = try assignedLocations(in: original, roles: request.roles)
        guard Set(input.timelines.map(\.id)).count == input.timelines.count else {
            throw AudioFinishingError(reason: "Nested timeline IDs must be unique.")
        }
        let originalMeasurement = try await measure(original, input.timelines, input.urls, nil)
        let children = Dictionary(uniqueKeysWithValues: input.timelines.map { ($0.id, $0) })
        let resolve: @Sendable (String) -> Timeline? = { children[$0] }
        let audible = PreparedAudio.audibleClips(timeline: original, resolveTimeline: resolve)
        let versions = try await LoudnessAnalyzer.sourceVersions(for: try audible.map { clip in
            guard let url = input.urls[clip.mediaRef] else { throw AudioMixError.sourceUnavailable(clip.mediaRef) }
            return url
        })
        var sourceVersions: [String: LoudnessAnalyzer.SourceVersion] = [:]
        for clip in audible {
            guard let url = input.urls[clip.mediaRef], let version = versions[url], version.size > 0 else {
                throw AudioMixError.sourceUnavailable(clip.mediaRef)
            }
            sourceVersions[clip.mediaRef] = version
        }
        let revision = try await TimelineOutputRevision.make(timeline: original, timelines: input.timelines, sources: sourceVersions)
        let voiceIds = Set(request.roles.filter { $0.role == .voice }.map(\.clipId))
        let voiceTimeline = selecting(voiceIds, in: original)
        let voices = try PreparedAudio.audibleClips(timeline: voiceTimeline, resolveTimeline: resolve).map { clip in
            guard let url = input.urls[clip.mediaRef] else { throw AudioMixError.sourceUnavailable(clip.mediaRef) }
            return AudioSpeechTiming.Source(clip: clip, url: url)
        }
        let timing: AudioSpeechTiming.Result
        if voices.isEmpty {
            guard voiceIds.isEmpty else { throw AudioFinishingError(reason: "Assigned voice nests contain no available audio.") }
            timing = .init(timings: [], sourceVersions: [:])
        } else {
            timing = try await speech(voices, original.fps)
            try validateSpeech(timing, sources: voices)
        }
        try Task.checkCancellation()
        let speechRanges = Dictionary(uniqueKeysWithValues: timing.timings.map { ($0.clipId, $0.ranges) })
        if let state = original.audioMix, state.request == request, state.outputRevision == revision,
           state.sourceVersions == sourceVersions, state.speechRanges == speechRanges,
           request.target.accepts(originalMeasurement) {
            let balance = try await AudioSpeechBalance.measure(timeline: original, timelines: input.timelines, urls: input.urls,
                                                               voiceIds: voiceIds, speechRanges: timing.ranges, measure: measure)
            try await LoudnessAnalyzer.validateSourceVersions(versions)
            try Task.checkCancellation()
            if balance.passes {
                var receiptState = state
                receiptState.measurement = originalMeasurement
                receiptState.speechBalance = balance
                return Result(timeline: original, receipt: .init(timelineId: original.id, changedClipIds: [], changed: false, state: receiptState))
            }
        }

        var candidate = original
        candidate.audioMix = nil
        var warnings: [String] = []
        var ownedTracks: [String: KeyframeTrack<Double>] = [:]
        for stage in stages(timeline: original, request: request) {
            try Task.checkCancellation()
            let assignment = stage[0]
            var duckTracks: [String: KeyframeTrack<Double>] = [:]
            for (index, member) in stage.enumerated() {
                let location = locations[member.clipId]!
                var clip = candidate.tracks[location.trackIndex].clips[location.clipIndex]
                let priorTrack = original.audioMix?.ownedVolumeTracks[clip.id]
                if let priorTrack, clip.volumeTrack == priorTrack { clip.volumeTrack = nil }
                let duck = try DuckingPlan.plan(bedStartFrame: clip.startFrame, bedDurationFrames: clip.durationFrames,
                                                speechSpans: assignment.role == .music ? timing.ranges : [], parameters: request.ducking)
                if !duck.isEmpty, clip.volumeTrack?.isActive == true {
                    guard replaceAutomation else { throw AudioMixError.alreadyHasVolumeAutomation(clipId: clip.id) }
                    clip.volumeTrack = nil
                }
                if !duck.isEmpty { duckTracks[clip.id] = KeyframeTrack(keyframes: duck.keyframes) }
                if assignment.role == .voice, let amount = request.voiceDenoiseAmount {
                    guard clip.sourceClipType != .sequence, !clip.hasEnhanceEnabled else {
                        throw AudioFinishingError(reason: "Independent voice denoise requires a non-nested clip without enhance_voice; preserve existing processing by omitting voiceDenoiseAmount.")
                    }
                    EditorViewModel.setAudioEffect(&clip, type: Clip.denoiseEffectType, enabled: amount > 0, values: ["amount": amount])
                }
                if assignment.role == .music || assignment.role == .ambience {
                    addBedFades(&clip, frames: request.bedFadeFrames, head: index == 0, tail: index == stage.count - 1, warnings: &warnings)
                }
                candidate.tracks[location.trackIndex].clips[location.clipIndex] = clip
            }
            let first = locations[stage[0].clipId]!
            let last = locations[stage[stage.count - 1].clipId]!
            let start = candidate.tracks[first.trackIndex].clips[first.clipIndex].startFrame
            let end = candidate.tracks[last.trackIndex].clips[last.clipIndex].endFrame
            let isolated = selecting(Set(stage.map(\.clipId)), in: candidate)
            let measured = try await measure(isolated, input.timelines, input.urls, start..<end)
            let level: Double?
            if assignment.role == .effects {
                level = measured.samplePeakDBFS
            } else {
                level = measured.loudness.status == .measured ? measured.loudness.integratedLUFS : nil
            }
            for member in stage {
                let location = locations[member.clipId]!
                var clip = candidate.tracks[location.trackIndex].clips[location.clipIndex]
                if let level, level.isFinite {
                    try applyGain(assignment.level(for: request.target) - level, to: &clip)
                } else if assignment.role == .voice {
                    throw AudioFinishingError(reason: "Voice clip '\(clip.id)' is silent or too short to establish loudness.")
                } else {
                    warnings.append("Clip '\(clip.id)' has no measurable \(assignment.role == .effects ? "peak" : "loudness"); its level was preserved.")
                }
                if let track = duckTracks[clip.id] {
                    clip.volumeTrack = track
                    ownedTracks[clip.id] = track
                }
                candidate.tracks[location.trackIndex].clips[location.clipIndex] = clip
            }
        }

        var measured = try await measure(candidate, input.timelines, input.urls, nil)
        for _ in 0..<3 {
            try Task.checkCancellation()
            guard measured.loudness.status == .measured,
                  let loudness = measured.loudness.integratedLUFS, loudness.isFinite,
                  let peak = measured.loudness.truePeakDBFS, peak.isFinite else {
                throw AudioFinishingError(reason: "The combined output has no measurable programme loudness.")
            }
            let loudnessGain = request.target.integratedLUFS - loudness
            let peakGain = request.target.truePeakDBTP - 0.02 - peak
            let gain = min(loudnessGain, peakGain)
            if abs(gain) < 0.01, request.target.accepts(measured) { break }
            guard abs(loudness + gain - request.target.integratedLUFS) <= request.target.toleranceLU else {
                throw AudioFinishingError(reason: "The combined output cannot meet both loudness and true-peak targets with gain alone. Reduce transient peaks or choose a lower loudness target.")
            }
            for location in locations.values {
                try applyGain(gain, to: &candidate.tracks[location.trackIndex].clips[location.clipIndex])
            }
            measured = try await measure(candidate, input.timelines, input.urls, nil)
        }
        guard request.target.accepts(measured) else {
            throw AudioFinishingError(reason: "The measured output did not meet its loudness, true-peak, and clipping targets; no mix was committed.")
        }
        let balance = try await AudioSpeechBalance.measure(timeline: candidate, timelines: input.timelines, urls: input.urls,
                                                           voiceIds: voiceIds, speechRanges: timing.ranges, measure: measure)
        guard balance.passes else {
            let ranges = balance.windows.filter { !$0.passes }.map { "\($0.startFrame)..<\($0.endFrame)" }.joined(separator: ", ")
            throw AudioFinishingError(reason: "Voice has insufficient level contrast against the combined bed in frames \(ranges). Lower music, ambience, or effects; no mix was committed. Level contrast does not replace human audition.")
        }
        try await LoudnessAnalyzer.validateSourceVersions(versions)
        try await LoudnessAnalyzer.validateSourceVersions(timing.sourceVersions)
        let outputRevision = try await TimelineOutputRevision.make(timeline: candidate, timelines: input.timelines, sources: sourceVersions)
        try Task.checkCancellation()
        let state = AudioMixState(request: request, ownedVolumeTracks: ownedTracks, outputRevision: outputRevision,
                                  sourceVersions: sourceVersions, measurement: measured,
                                  speechDetection: Dictionary(uniqueKeysWithValues: timing.timings.map { ($0.clipId, $0.method.rawValue) }),
                                  speechRanges: speechRanges, speechBalance: balance,
                                  warnings: warnings)
        candidate.audioMix = state
        let changedIds = request.roles.compactMap { assignment -> String? in
            let location = locations[assignment.clipId]!
            return original.tracks[location.trackIndex].clips[location.clipIndex] == candidate.tracks[location.trackIndex].clips[location.clipIndex]
                ? nil : assignment.clipId
        }
        return Result(timeline: candidate, receipt: .init(timelineId: original.id, changedClipIds: changedIds, changed: candidate != original, state: state))
    }

    private static func assignedLocations(in timeline: Timeline, roles: [AudioRoleAssignment]) throws -> [String: ClipLocation] {
        guard (1...120).contains(timeline.fps), timeline.width > 0, timeline.height > 0 else {
            throw AudioFinishingError(reason: "Invalid mixing timeline settings.")
        }
        var ids = Set<String>()
        var audible: [String: ClipLocation] = [:]
        for (trackIndex, track) in timeline.tracks.enumerated() {
            for (clipIndex, clip) in track.clips.enumerated() {
                guard ids.insert(clip.id).inserted else { throw AudioFinishingError(reason: "Clip IDs must be unique before mixing.") }
                if track.type == .audio, !track.muted {
                    guard clip.mediaType == .audio else { throw AudioMixError.notAudio(clip.id) }
                    audible[clip.id] = .init(trackIndex: trackIndex, clipIndex: clipIndex)
                }
            }
        }
        guard Set(roles.map(\.clipId)) == Set(audible.keys) else {
            throw AudioFinishingError(reason: "Assign exactly one role to every clip on an unmuted audio track; muted, missing, and visual clip IDs cannot be assigned.")
        }
        return audible
    }

    private static func selecting(_ ids: Set<String>, in timeline: Timeline) -> Timeline {
        var value = timeline
        value.audioMix = nil
        for index in value.tracks.indices where value.tracks[index].type == .audio {
            value.tracks[index].clips = value.tracks[index].clips.filter { ids.contains($0.id) }
        }
        return value
    }

    private static func stages(timeline: Timeline, request: AudioMixRequest) -> [[AudioRoleAssignment]] {
        let assignments = Dictionary(uniqueKeysWithValues: request.roles.map { ($0.clipId, $0) })
        var result: [[AudioRoleAssignment]] = []
        for track in timeline.tracks where track.type == .audio && !track.muted {
            var previous: Clip?
            for clip in track.clips.sorted(by: { $0.startFrame < $1.startFrame }) {
                let assignment = assignments[clip.id]!
                if let previous, let prior = assignments[previous.id], prior.role == assignment.role,
                   prior.level(for: request.target) == assignment.level(for: request.target),
                   assignment.role == .music || assignment.role == .ambience,
                   previous.endFrame == clip.startFrame, previous.mediaRef == clip.mediaRef,
                   previous.sourceClipType == clip.sourceClipType,
                   abs(Double(previous.trimStartFrame) + previous.timeMap.sourceOffset(atTimelineOffset: previous.durationFrames)
                       - Double(clip.trimStartFrame)) < 0.5 {
                    result[result.count - 1].append(assignment)
                } else { result.append([assignment]) }
                previous = clip
            }
        }
        return result
    }

    private static func applyGain(_ gainDB: Double, to clip: inout Clip) throws {
        guard gainDB.isFinite, (-48 ... 48).contains(gainDB), clip.volume.isFinite, clip.volume > 0 else {
            throw AudioFinishingError(reason: "Clip '\(clip.id)' needs unsupported gain or is intentionally muted; set an audible starting level before mixing.")
        }
        guard abs(gainDB) >= 0.001 else { return }
        let volume = clip.volume * pow(10, gainDB / 20)
        guard volume.isFinite, volume > 0, volume <= pow(10, 48.0 / 20) else {
            throw AudioFinishingError(reason: "Clip '\(clip.id)' exceeds supported gain headroom.")
        }
        clip.volume = volume
    }

    private static func addBedFades(_ clip: inout Clip, frames: Int, head: Bool, tail: Bool, warnings: inout [String]) {
        guard frames > 0, (head && clip.fadeInFrames == 0) || (tail && clip.fadeOutFrames == 0) else { return }
        let available = min(clip.durationFrames / 2, clip.durationFrames - clip.fadeInFrames - clip.fadeOutFrames)
        let actual = min(frames, available)
        if actual < frames { warnings.append("Bed fades on '\(clip.id)' were limited to \(actual) frames by its existing fades and duration.") }
        guard actual > 0 else { return }
        if head, clip.fadeInFrames == 0 { clip.setFade(.left, frames: actual); clip.setFadeInterpolation(.left, .smooth) }
        if tail, clip.fadeOutFrames == 0 { clip.setFade(.right, frames: actual); clip.setFadeInterpolation(.right, .smooth) }
    }

    private static func validateSpeech(_ timing: AudioSpeechTiming.Result, sources: [AudioSpeechTiming.Source]) throws {
        let sourceIds = Set(sources.map { $0.clip.id })
        guard sourceIds.count == sources.count, Set(timing.timings.map(\.clipId)) == sourceIds,
              timing.timings.count == sources.count, !timing.usedWholeClipFallback, !timing.ranges.isEmpty else {
            throw AudioFinishingError(reason: "Mixing requires measured speech timing for every voice source; whole-clip approximations cannot certify a mix.")
        }
        let clips = Dictionary(uniqueKeysWithValues: sources.map { ($0.clip.id, $0.clip) })
        for value in timing.timings {
            guard let clip = clips[value.clipId], value.ranges.allSatisfy({
                !$0.isEmpty && $0.lowerBound >= clip.startFrame && $0.upperBound <= clip.endFrame
            }) else { throw AudioSpeechTiming.Failure.invalidTiming(value.clipId) }
        }
    }
}
