import Foundation

struct AudioSpeechBalance: Codable, Sendable, Equatable {
    struct Window: Codable, Sendable, Equatable {
        let startFrame: Int
        let endFrame: Int
        let voiceRMSDBFS: Double?
        let backgroundRMSDBFS: Double?

        var marginDB: Double? {
            guard let voiceRMSDBFS, let backgroundRMSDBFS else { return nil }
            return voiceRMSDBFS - backgroundRMSDBFS
        }

        var passes: Bool {
            voiceRMSDBFS?.isFinite == true && (marginDB.map { $0 >= AudioSpeechBalance.minimumMarginDB } ?? true)
        }

        var receipt: [String: Any] {
            ["startFrame": startFrame, "endFrame": endFrame, "voiceRMSDBFS": voiceRMSDBFS as Any? ?? NSNull(),
             "backgroundRMSDBFS": backgroundRMSDBFS as Any? ?? NSNull(), "marginDB": marginDB as Any? ?? NSNull(),
             "passes": passes]
        }
    }

    static let minimumMarginDB = 6.0
    let windows: [Window]
    var passes: Bool { windows.allSatisfy(\.passes) }

    var receipt: [String: Any] {
        ["minimumMarginDB": Self.minimumMarginDB, "passes": passes, "windows": windows.map(\.receipt),
         "scope": "processed_stem_level_contrast_not_audition"]
    }

    @concurrent
    static func measure(
        timeline: Timeline, timelines: [Timeline], urls: [String: URL],
        voiceIds: Set<String>, speechRanges: [Range<Int>],
        measure: AudioMixFinisher.Measurement
    ) async throws -> Self {
        var ranges: [Range<Int>] = []
        for range in speechRanges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= timeline.totalFrames else {
                throw AudioFinishingError(reason: "Speech balance requires current, nonempty timeline ranges.")
            }
            if let last = ranges.last, range.lowerBound <= last.upperBound {
                ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else { ranges.append(range) }
        }
        guard ranges.count <= 512 else {
            throw AudioFinishingError(reason: "Speech balance exceeds 512 phrase ranges; refine speech timing before mixing.")
        }
        var voice = timeline
        var background = timeline
        voice.audioMix = nil
        background.audioMix = nil
        for index in timeline.tracks.indices where timeline.tracks[index].type == .audio {
            voice.tracks[index].muted = timeline.tracks[index].muted
            voice.tracks[index].clips = timeline.tracks[index].clips.filter { voiceIds.contains($0.id) }
            background.tracks[index].clips = timeline.tracks[index].clips.filter { !voiceIds.contains($0.id) }
        }
        var windows: [Window] = []
        for range in ranges {
            try Task.checkCancellation()
            let voiceMeasurement = try await measure(voice, timelines, urls, range)
            let backgroundMeasurement = try await measure(background, timelines, urls, range)
            windows.append(.init(startFrame: range.lowerBound, endFrame: range.upperBound,
                                 voiceRMSDBFS: voiceMeasurement.rmsDBFS,
                                 backgroundRMSDBFS: backgroundMeasurement.rmsDBFS))
        }
        try Task.checkCancellation()
        return Self(windows: windows)
    }
}
