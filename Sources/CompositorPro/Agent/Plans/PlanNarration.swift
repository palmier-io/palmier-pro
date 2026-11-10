import CoreMedia
import CryptoKit
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

    func validated() throws -> Self {
        var source = self
        source.mediaRef = try EditPlan.validatedID(mediaRef, field: "narration.mediaRef")
        return source
    }
}

struct NarrationIntent: Codable, Sendable, Equatable {
    enum Narrator: Codable, Sendable, Equatable {
        case localSpeech(LocalSpeechNarrator)
        case recording(RecordingNarrator)

        private enum CodingKeys: String, CodingKey {
            case kind, engine, voiceIdentifier, rate, pitch, modelIdentity, configurationIdentity, mediaRef, identity
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .kind) {
            case "local_speech": self = .localSpeech(try LocalSpeechNarrator(from: decoder))
            case "recording": self = .recording(try RecordingNarrator(from: decoder))
            default: throw EditPlanValidationError.invalidReference("Narrator kind must be local_speech or recording.")
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .localSpeech(let speech):
                try container.encode("local_speech", forKey: .kind)
                try speech.encode(to: encoder)
            case .recording(let recording):
                try container.encode("recording", forKey: .kind)
                try recording.encode(to: encoder)
            }
        }

        var receipt: [String: Any] {
            switch self {
            case .localSpeech(let speech): speech.receipt
            case .recording(let recording): recording.receipt
            }
        }
    }

    var language: String?
    var startFrame: Int
    var narrator: Narrator?

    func validated() throws -> Self {
        var intent = self
        guard (0...maxFrameArg).contains(startFrame) else { throw EditPlanValidationError.invalidRange }
        if let language { intent.language = try EditPlan.validatedName(language) }
        switch narrator {
        case .localSpeech(let speech): intent.narrator = .localSpeech(try speech.validated())
        case .recording(let recording): intent.narrator = .recording(try recording.validated())
        case nil: break
        }
        return intent
    }

    var receipt: [String: Any] {
        var row: [String: Any] = ["startFrame": startFrame]
        if let language { row["language"] = language }
        if let narrator { row["narrator"] = narrator.receipt }
        return row
    }

    @concurrent
    func verifyAvailableNarrator() async throws {
        try Task.checkCancellation()
        guard let language, !language.isEmpty, let narrator else {
            throw EditPlanValidationError.invalidReference("Managed narration requires language, placement, and an exact narrator.")
        }
        _ = try validated()
        if case .localSpeech(let speech) = narrator {
            try await speech.verifyAvailable(language: language)
        }
        try Task.checkCancellation()
    }
}

struct RecordingNarrator: Codable, Sendable, Equatable {
    var mediaRef: String
    var identity: MediaInputIdentity

    func validated() throws -> Self {
        var recording = self
        recording.mediaRef = try EditPlan.validatedID(mediaRef, field: "narrator.mediaRef")
        guard identity.isValid else {
            throw EditPlanValidationError.invalidReference("Recording narrator requires a measured byte identity.")
        }
        return recording
    }

    var receipt: [String: Any] {
        ["kind": "recording", "mediaRef": mediaRef, "inputId": identity.inputId,
         "identity": ["contentSHA256": identity.contentSHA256, "byteCount": identity.byteCount]]
    }
}

struct LocalSpeechNarrator: Codable, Sendable, Equatable {
    enum Engine: String, Codable, Sendable { case system, piper }

    var engine: Engine
    var voiceIdentifier: String
    var rate: Double
    var pitch: Double
    var modelIdentity: MediaInputIdentity?
    var configurationIdentity: MediaInputIdentity?

    func validated() throws -> Self {
        var speech = self
        speech.voiceIdentifier = try EditPlan.validatedID(voiceIdentifier, field: "narrator.voiceIdentifier")
        guard rate.isFinite, pitch.isFinite, (0.5...2).contains(rate), (0.5...2).contains(pitch) else {
            throw EditPlanValidationError.invalidReference("Narrator rate and pitch must be finite multipliers from 0.5 through 2.")
        }
        switch engine {
        case .system:
            guard modelIdentity == nil, configurationIdentity == nil else {
                throw EditPlanValidationError.invalidReference("System narration does not accept Piper model identities.")
            }
        case .piper:
            guard pitch == 1, modelIdentity?.isValid == true, configurationIdentity?.isValid == true else {
                throw EditPlanValidationError.invalidReference("Piper narration requires measured model/config identities and pitch 1; pitch changes are unsupported.")
            }
        }
        return speech
    }

    @concurrent
    func verifyAvailable(language: String) async throws {
        try Task.checkCancellation()
        _ = try validated()
        let locale = language.replacingOccurrences(of: "_", with: "-").lowercased()
        switch engine {
        case .system:
            guard let voice = SpeechSynthesizer.voices().first(where: { $0.identifier == voiceIdentifier }),
                  voice.language.replacingOccurrences(of: "_", with: "-").lowercased() == locale else {
                throw EditPlanValidationError.invalidReference("Narration requires the exact installed system voice identifier and its matching language.")
            }
        case .piper:
            guard PiperTTS.isAvailable,
                  let model = PiperTTS.installedModels().first(where: { $0.fileName == voiceIdentifier }),
                  model.languageTag.lowercased() == locale else {
                throw EditPlanValidationError.invalidReference("Narration requires the exact installed Piper model and its matching language.")
            }
            let measuredModel = try await MediaInputIdentityService.shared.identify(model.modelURL, force: true)
            let measuredConfiguration = try await MediaInputIdentityService.shared.identify(model.modelURL.appendingPathExtension("json"), force: true)
            guard measuredModel == modelIdentity, measuredConfiguration == configurationIdentity else {
                throw EditPlanValidationError.invalidReference("Piper model or configuration changed; choose and approve the current narrator.")
            }
        }
        try Task.checkCancellation()
    }

    var receipt: [String: Any] {
        var row: [String: Any] = ["kind": "local_speech", "engine": engine.rawValue,
                                 "voiceIdentifier": voiceIdentifier, "rate": rate, "pitch": pitch]
        if let modelIdentity { row["modelInputId"] = modelIdentity.inputId }
        if let configurationIdentity { row["configurationInputId"] = configurationIdentity.inputId }
        return row
    }
}

/// The exact speech the approved script asks a renderer to speak, in beat order.
enum NarrationSpokenText {
    static func digest(beats: [ScriptBeat]) -> String {
        let spoken = beats.map(\.narrationText).joined(separator: " ")
        return Self.digest(spoken)
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The request a pinned synthesis render is bound to. Digests cover plan, run, approved
/// revision, final narration revision, and the exact approved speech controls, so a proof
/// cannot survive a material authoring change.
struct NarrationSynthesisRequest: Sendable, Equatable {
    var planId: String
    var timelineId: String
    var runId: String?
    var approvedRevision: String
    var narrationRevision: String
    var engine: LocalSpeechNarrator.Engine
    var voiceIdentifier: String
    var language: String
    var rate: Double
    var pitch: Double
    var spokenTextDigest: String

    var digest: String {
        let parts = [planId, timelineId, runId ?? "", approvedRevision, narrationRevision,
                     engine.rawValue, voiceIdentifier, language,
                     String(rate), String(pitch), spokenTextDigest]
        let json = try? JSONSerialization.data(withJSONObject: parts, options: [.sortedKeys])
        return SHA256.hash(data: json ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
}

/// App-owned provenance for narration the app synthesized from an approved script. The
/// renderer supplies the execution evidence; the domain binds the installed bytes. This is
/// execution provenance — it proves the installed audio came from the approved narrator
/// controls — not acoustic certification and not protection against deliberately edited
/// project JSON.
struct NarrationSynthesisProof: Codable, Sendable, Equatable {
    static let deliveryVersion = 1

    var requestDigest: String
    var planId: String
    var timelineId: String
    var runId: String?
    var approvedRevision: String
    var narrationRevision: String

    var engine: LocalSpeechNarrator.Engine
    var voiceIdentifier: String
    var language: String
    var rate: Double
    var pitch: Double
    var spokenTextDigest: String

    var modelIdentity: MediaInputIdentity?
    var configurationIdentity: MediaInputIdentity?

    var writtenFrames: Int64
    var insertedSilenceSeconds: Double

    var mediaRef: String
    var installedIdentity: MediaInputIdentity

    var deliveryVersion: Int { Self.deliveryVersion }

    /// Evidence the renderer must have applied the approved controls exactly.
    func matches(narrator: LocalSpeechNarrator, language: String, spokenTextDigest: String,
                 narrationRevision: String?) -> Bool {
        engine == narrator.engine && voiceIdentifier == narrator.voiceIdentifier
            && rate == narrator.rate && pitch == narrator.pitch
            && modelIdentity == narrator.modelIdentity && configurationIdentity == narrator.configurationIdentity
            && self.language == language && self.spokenTextDigest == spokenTextDigest
            && self.narrationRevision == narrationRevision
    }

    func validated(plan: EditPlan) throws {
        guard plan.id == planId, plan.timelineId == timelineId,
              let beats = plan.scriptBeats, let intent = plan.narrationIntent,
              let language = intent.language,
              case .localSpeech(let narrator) = intent.narrator,
              let narration = plan.narration else {
            throw EditPlanValidationError.invalidReference("Synthesis proof does not match this plan's script, intent, or attachment.")
        }
        guard matches(narrator: narrator, language: language,
                      spokenTextDigest: NarrationSpokenText.digest(beats: beats),
                      narrationRevision: plan.narrationRevision) else {
            throw EditPlanValidationError.invalidReference("Synthesis proof does not match the approved narrator and script revision.")
        }
        guard narration.mediaRef == mediaRef, installedIdentity.isValid,
              requestDigest.count == 64 else {
            throw EditPlanValidationError.invalidReference("Synthesis proof must name the attached media and carry a valid request digest.")
        }
        if let timing = plan.narrationTiming, timing.sourceFingerprint != installedIdentity.contentSHA256 {
            throw EditPlanValidationError.invalidReference("Measured timing must match the synthesized audio bytes.")
        }
    }

    var receipt: [String: Any] {
        var row: [String: Any] = [
            "kind": "synthesized", "deliveryVersion": deliveryVersion,
            "engine": engine.rawValue, "voiceIdentifier": voiceIdentifier,
            "language": language, "rate": rate, "pitch": pitch,
            "spokenTextDigest": spokenTextDigest, "requestDigest": requestDigest,
            "narrationRevision": narrationRevision,
            "writtenFrames": writtenFrames, "insertedSilenceSeconds": insertedSilenceSeconds,
            "mediaRef": mediaRef, "inputId": installedIdentity.inputId,
        ]
        if let runId { row["runId"] = runId }
        if !approvedRevision.isEmpty { row["approvedRevision"] = approvedRevision }
        if let modelIdentity { row["modelInputId"] = modelIdentity.inputId }
        if let configurationIdentity { row["configurationInputId"] = configurationIdentity.inputId }
        return row
    }
}

struct NarrationIntentRequest: Decodable, Sendable {
    struct Narrator: Decodable, Sendable {
        var kind: String
        var mediaRef: String?
        var engine: LocalSpeechNarrator.Engine?
        var voiceIdentifier: String?
        var rate: Double?
        var pitch: Double?
    }

    var language: String?
    var startFrame: Int
    var narrator: Narrator?

    @concurrent
    func resolveLocalSpeech() async throws -> LocalSpeechNarrator {
        guard let narrator, narrator.kind == "local_speech", narrator.mediaRef == nil,
              let engine = narrator.engine, let voice = narrator.voiceIdentifier,
              let rate = narrator.rate, let pitch = narrator.pitch, let language,
              rate.isFinite, pitch.isFinite, (0.5...2).contains(rate), (0.5...2).contains(pitch) else {
            throw EditPlanValidationError.invalidReference("Local narration requires engine, canonical voiceIdentifier, language, rate, and pitch; recording mediaRef is not allowed.")
        }
        var speech = LocalSpeechNarrator(engine: engine, voiceIdentifier: voice, rate: rate, pitch: pitch)
        if engine == .piper {
            guard pitch == 1, PiperTTS.isAvailable,
                  let model = PiperTTS.installedModels().first(where: { $0.fileName == voice }) else {
                throw EditPlanValidationError.invalidReference("Choose an exact installed Piper model with pitch 1; no model or engine substitution is allowed.")
            }
            speech.modelIdentity = try await MediaInputIdentityService.shared.identify(model.modelURL, force: true)
            speech.configurationIdentity = try await MediaInputIdentityService.shared.identify(model.modelURL.appendingPathExtension("json"), force: true)
        }
        try await speech.verifyAvailable(language: language)
        return speech
    }
}

extension EditPlan {
    func validateNarrationAttachment(identity: MediaInputIdentity) throws {
        guard productionRun != nil else { return }
        guard let narrator = narrationIntent?.narrator else {
            throw EditPlanValidationError.invalidReference("Managed narration requires an approved narrator intent.")
        }
        switch narrator {
        case .recording(let recording):
            guard identity.isValid, identity == recording.identity else {
                throw EditPlanValidationError.invalidReference("Narration attachment does not match the chosen recording byte identity.")
            }
        case .localSpeech(let speech):
            guard let proof = narrationSynthesisProof, identity.isValid, identity == proof.installedIdentity,
                  proof.mediaRef == narration?.mediaRef,
                  proof.matches(narrator: speech, language: narrationIntent?.language ?? "",
                                spokenTextDigest: NarrationSpokenText.digest(beats: scriptBeats ?? []),
                                narrationRevision: narrationRevision) else {
                throw EditPlanValidationError.invalidReference("Synthesized narration must be produced by Prepare Approved Narration; generic speech output cannot verify the approved narrator.")
            }
        }
    }

    func narrationProductionBlockers(entries: [String: MediaManifestEntry], unavailable: Set<String>) -> [String] {
        var blockers: [String] = []
        if case .localSpeech(let speech) = narrationIntent?.narrator {
            let verified = narrationSynthesisProof?.matches(
                narrator: speech, language: narrationIntent?.language ?? "",
                spokenTextDigest: NarrationSpokenText.digest(beats: scriptBeats ?? []),
                narrationRevision: narrationRevision) == true
            if !verified { blockers.append("unverified_synthesized_narration") }
        }
        guard let source = narration else { return blockers + ["missing_narration_attachment"] }
        if let proof = narrationSynthesisProof {
            if proof.mediaRef != source.mediaRef { blockers.append("narration_proof_media_mismatch") }
            else if let identity = entries[proof.mediaRef]?.inputIdentity,
                    identity.isValid, identity != proof.installedIdentity {
                blockers.append("narration_proof_media_mismatch")
            }
        }
        guard let entry = entries[source.mediaRef], entry.type == .audio, entry.generationStatus == nil,
              entry.duration.isFinite, entry.duration > 0, !unavailable.contains(source.mediaRef) else {
            return blockers + ["narration_media_not_ready"]
        }
        if let identity = entry.inputIdentity, identity.isValid {
            if case .recording(let recording) = narrationIntent?.narrator, identity != recording.identity {
                blockers.append("narration_recording_identity_mismatch")
            }
            if let timing = narrationTiming, timing.sourceFingerprint != identity.contentSHA256 {
                blockers.append("narration_timing_source_mismatch")
            }
        } else { blockers.append("unresolved_narration_identity") }
        if narrationTiming == nil || narrationTiming?.unresolvedBeatIds.isEmpty == false {
            blockers.append("narration_timing_unresolved")
        }
        return blockers
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
        guard narration != nil, let intent = narrationIntent, let timing = narrationTiming, timing.unresolvedBeatIds.isEmpty else {
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
              intent.startFrame <= maxFrameArg - end else {
            throw EditPlanValidationError.invalidReference("Scene narration range is too short for its minimum hold or exceeds supported timeline bounds.")
        }
        return (intent.startFrame + start)..<(intent.startFrame + end)
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

    /// Non-throwing variant for post-commit receipts: a shot whose narration
    /// range cannot resolve is reported unresolved instead of failing the
    /// already-committed assembly receipt.
    func resolvedShotsSafe() -> [EditPlanShot] {
        shots.map { original in
            var shot = original
            if let link = shot.narrationLink,
               let range = try? resolvedNarrationRange(link) {
                shot.startFrame = range.lowerBound
                shot.endFrame = range.upperBound
            }
            return shot
        }
    }
}
