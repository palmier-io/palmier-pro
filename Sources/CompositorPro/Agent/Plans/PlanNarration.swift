import CoreMedia
import Foundation

struct ScriptBeat: Codable, Sendable, Equatable {
    var beatId: String
    var text: String
    var spokenText: String?
    var purpose: String
    var claimIds: [String]?

    var narrationText: String { spokenText ?? text }

    func validated() throws -> Self {
        var beat = self
        beat.beatId = try EditPlan.validatedID(beatId, field: "beatId")
        beat.text = try EditPlan.validatedText(text, field: "script text")
        beat.purpose = try EditPlan.validatedText(purpose, field: "beat purpose")
        if let spokenText { beat.spokenText = try EditPlan.validatedText(spokenText, field: "spokenText") }
        guard !beat.text.isEmpty, !beat.purpose.isEmpty, !NarrationAlignment.tokens(beat.narrationText).isEmpty else {
            throw EditPlanValidationError.invalidReference("Script beats need text, editorial purpose, and speakable words.")
        }
        return beat
    }

    func receipt() -> [String: Any] {
        var row: [String: Any] = ["beatId": beatId, "text": text, "purpose": purpose]
        if let spokenText { row["spokenText"] = spokenText }
        if let claimIds { row["claimIds"] = claimIds }
        return row
    }
}

struct NarrationSource: Codable, Sendable, Equatable {
    var mediaRef: String
    var language: String?
    var startFrame: Int

    func validated() throws -> Self {
        var source = self
        source.mediaRef = try EditPlan.validatedID(mediaRef, field: "narration.mediaRef")
        guard (0...maxFrameArg).contains(startFrame) else { throw EditPlanValidationError.invalidRange }
        if let language { source.language = try EditPlan.validatedName(language) }
        return source
    }
}

struct SceneNarrationLink: Codable, Sendable, Equatable {
    var firstBeatId: String
    var lastBeatId: String
    var minimumHoldSeconds: Double = 1

    private enum CodingKeys: String, CodingKey { case firstBeatId, lastBeatId, minimumHoldSeconds }

    init(firstBeatId: String, lastBeatId: String, minimumHoldSeconds: Double = 1) {
        self.firstBeatId = firstBeatId
        self.lastBeatId = lastBeatId
        self.minimumHoldSeconds = minimumHoldSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        firstBeatId = try container.decode(String.self, forKey: .firstBeatId)
        lastBeatId = try container.decode(String.self, forKey: .lastBeatId)
        minimumHoldSeconds = try container.decodeIfPresent(Double.self, forKey: .minimumHoldSeconds) ?? 1
    }

    func validated(beats: [ScriptBeat]) throws -> Self {
        var link = self
        link.firstBeatId = try EditPlan.validatedID(firstBeatId, field: "firstBeatId")
        link.lastBeatId = try EditPlan.validatedID(lastBeatId, field: "lastBeatId")
        guard let first = beats.firstIndex(where: { $0.beatId == link.firstBeatId }),
              let last = beats.firstIndex(where: { $0.beatId == link.lastBeatId }), first <= last,
              minimumHoldSeconds.isFinite, (1...60).contains(minimumHoldSeconds) else {
            throw EditPlanValidationError.invalidReference("Scene narration links require an ordered script-beat range and a 1–60 second minimum hold.")
        }
        return link
    }
}

struct NarrationTime: Codable, Sendable, Equatable {
    var value: Int64
    var timescale: Int32

    init(_ time: CMTime) throws {
        guard time.isNumeric, time.epoch == 0, time >= .zero, time.seconds <= Double(maxFrameArg) else {
            throw EditPlanValidationError.invalidReference("Narration times must be finite, non-negative, and bounded.")
        }
        value = time.value
        timescale = time.timescale
    }

    var cmTime: CMTime { CMTime(value: value, timescale: timescale) }

    func validated() throws {
        guard timescale > 0, value >= 0 else { throw EditPlanValidationError.invalidRange }
        _ = try Self(cmTime)
    }

    func frame(fps: Int, rounding: CMTimeRoundingMethod = .roundHalfAwayFromZero) throws -> Int {
        try validated()
        guard (1...120).contains(fps) else { throw EditPlanValidationError.invalidRange }
        let converted = CMTimeConvertScale(cmTime, timescale: Int32(fps), method: rounding)
        guard converted.isNumeric, (0...Int64(maxFrameArg)).contains(converted.value) else {
            throw EditPlanValidationError.invalidRange
        }
        return Int(converted.value)
    }
}

struct NarrationTiming: Codable, Sendable, Equatable {
    struct Anchor: Codable, Sendable, Equatable {
        var beatId: String
        var speechStart: NarrationTime
        var speechEnd: NarrationTime
    }

    var revision: String
    var sourceFingerprint: String
    var duration: NarrationTime
    var anchors: [Anchor]
    var unresolvedBeatIds: [String]

    func validated(beats: [ScriptBeat], revision: String?) throws {
        guard self.revision == revision, sourceFingerprint.count == 64,
              sourceFingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw EditPlanValidationError.invalidReference("Narration timing does not match its script/source revision.")
        }
        try duration.validated()
        guard duration.cmTime > .zero else { throw EditPlanValidationError.invalidRange }
        let ids = anchors.map(\.beatId) + unresolvedBeatIds
        guard ids.count == beats.count, Set(ids).count == ids.count, Set(ids) == Set(beats.map(\.beatId)) else {
            throw EditPlanValidationError.invalidReference("Narration timing must account for every script beat exactly once.")
        }
        var end = CMTime.zero
        var previousIndex = -1
        for anchor in anchors {
            try anchor.speechStart.validated()
            try anchor.speechEnd.validated()
            guard let index = beats.firstIndex(where: { $0.beatId == anchor.beatId }), index > previousIndex,
                  anchor.speechStart.cmTime >= end, anchor.speechEnd.cmTime > anchor.speechStart.cmTime,
                  anchor.speechEnd.cmTime <= duration.cmTime else {
                throw EditPlanValidationError.invalidReference("Narration anchors must follow script order and stay inside measured audio.")
            }
            previousIndex = index
            end = anchor.speechEnd.cmTime
        }
    }
}

enum NarrationAlignment {
    static func tokens(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: \.isWhitespace).map {
            String($0).trimmingCharacters(in: .punctuationCharacters)
        }.filter { !$0.isEmpty }
    }

    static func align(beats: [ScriptBeat], transcript: TranscriptionResult, duration: NarrationTime,
                      revision: String, fingerprint: String) throws -> NarrationTiming {
        try Task.checkCancellation()
        guard transcript.words.count <= 20_000 else {
            throw EditPlanValidationError.invalidReference("Narration alignment accepts at most 20,000 word records.")
        }
        let expected = beats.flatMap { tokens($0.narrationText) }
        let actual = transcript.words.flatMap { tokens($0.text) }
        var timing = NarrationTiming(revision: revision, sourceFingerprint: fingerprint, duration: duration,
                                     anchors: [], unresolvedBeatIds: beats.map(\.beatId))
        guard !expected.isEmpty, expected == actual, transcript.words.allSatisfy({ !tokens($0.text).isEmpty }) else { return timing }
        var anchors: [NarrationTiming.Anchor] = []
        var wordIndex = 0
        var previousEnd = CMTime.zero
        for beat in beats {
            try Task.checkCancellation()
            var remaining = tokens(beat.narrationText).count
            let first = wordIndex
            while remaining > 0, wordIndex < transcript.words.count {
                remaining -= tokens(transcript.words[wordIndex].text).count
                wordIndex += 1
            }
            guard remaining == 0, wordIndex > first,
                  let start = transcript.words[first].start, let end = transcript.words[wordIndex - 1].end,
                  start.isFinite, end.isFinite, start >= 0, end > start, end <= duration.cmTime.seconds else { return timing }
            for word in transcript.words[first..<wordIndex] {
                guard let s = word.start, let e = word.end, s.isFinite, e.isFinite, s >= 0, e > s,
                      e <= duration.cmTime.seconds else { return timing }
                let wordStart = CMTime(seconds: s, preferredTimescale: 1_000_000)
                let wordEnd = CMTime(seconds: e, preferredTimescale: 1_000_000)
                guard wordStart >= previousEnd else { return timing }
                previousEnd = wordEnd
            }
            anchors.append(.init(beatId: beat.beatId,
                                        speechStart: try NarrationTime(CMTime(seconds: start, preferredTimescale: 1_000_000)),
                                        speechEnd: try NarrationTime(CMTime(seconds: end, preferredTimescale: 1_000_000))))
        }
        timing.anchors = anchors
        timing.unresolvedBeatIds = []
        return timing
    }
}

extension EditPlan {
    func resolvedNarrationRange(_ link: SceneNarrationLink) throws -> Range<Int> {
        guard let source = narration, let timing = narrationTiming, timing.unresolvedBeatIds.isEmpty else {
            throw EditPlanValidationError.invalidReference("Narration alignment is unresolved; measure the current script and audio before assembly.")
        }
        try timing.validated(beats: scriptBeats ?? [], revision: narrationRevision)
        let link = try link.validated(beats: scriptBeats ?? [])
        guard let first = timing.anchors.firstIndex(where: { $0.beatId == link.firstBeatId }),
              let last = timing.anchors.firstIndex(where: { $0.beatId == link.lastBeatId }) else {
            throw EditPlanValidationError.invalidReference("Scene narration anchors are missing.")
        }
        let start = first == 0 ? 0 : try timing.anchors[first].speechStart.frame(fps: fps)
        let end = last + 1 < timing.anchors.count
            ? try timing.anchors[last + 1].speechStart.frame(fps: fps)
            : try timing.duration.frame(fps: fps, rounding: .roundTowardZero)
        guard end > start, end - start >= Int(ceil(link.minimumHoldSeconds * Double(fps))),
              source.startFrame <= maxFrameArg - end else {
            throw EditPlanValidationError.invalidReference("Scene narration range is too short for its minimum hold or exceeds supported timeline bounds.")
        }
        return (source.startFrame + start)..<(source.startFrame + end)
    }

    func resolvedShots() throws -> [EditPlanShot] {
        try shots.map { original in
            var shot = original
            if let link = shot.narrationLink {
                let range = try resolvedNarrationRange(link)
                shot.startFrame = range.lowerBound
                shot.endFrame = range.upperBound
            }
            return shot
        }
    }
}
