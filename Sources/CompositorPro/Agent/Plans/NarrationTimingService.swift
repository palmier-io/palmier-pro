import AVFoundation
import Foundation

actor NarrationTimingService {
    static let shared = NarrationTimingService()
    private let gate = AsyncSemaphore(value: 1)
    private let transcribe: @Sendable (URL, String?) async throws -> TranscriptionResult
    private var cachedTiming: (source: NarrationSource, language: String?, beats: [ScriptBeat], timing: NarrationTiming)?

    init(transcribe: @escaping @Sendable (URL, String?) async throws -> TranscriptionResult = { url, language in
        let locale = language.map(Locale.init(identifier:))
        if let locale {
            let supported = await Transcription.supportedLocales()
            guard Transcription.matchLocale(candidates: [locale], supported: supported) != nil else {
                throw TranscriptionError.unsupportedLocale(locale.identifier)
            }
        }
        return try await Transcription.transcribe(fileURL: url, preferredLocale: locale)
    }) {
        self.transcribe = transcribe
    }

    func measure(url: URL, source: NarrationSource, language: String?, beats: [ScriptBeat], revision: String,
                 previous: NarrationTiming?) async throws -> NarrationTiming {
        try await gate.wait()
        do {
            let result = try await measureAdmitted(url: url, source: source, language: language, beats: beats, revision: revision, previous: previous)
            await gate.signal()
            return result
        } catch {
            await gate.signal()
            throw error
        }
    }

    private func measureAdmitted(url: URL, source: NarrationSource, language: String?, beats: [ScriptBeat], revision: String,
                                 previous: NarrationTiming?) async throws -> NarrationTiming {
        try Task.checkCancellation()
        let before = try await Self.fingerprint(url)
        try Task.checkCancellation()
        if let cachedTiming, cachedTiming.source == source, cachedTiming.language == language, cachedTiming.beats == beats,
           cachedTiming.timing.revision == revision, cachedTiming.timing.sourceFingerprint == before {
            return cachedTiming.timing
        }
        if let previous, previous.revision == revision, previous.sourceFingerprint == before {
            try previous.validated(beats: beats, revision: revision)
            if previous.unresolvedBeatIds.isEmpty { return previous }
        }
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw EditPlanValidationError.invalidReference("Narration media has no audio track.")
        }
        let duration = try await NarrationTime(asset.load(.duration))
        guard duration.cmTime > .zero else { throw EditPlanValidationError.invalidRange }
        let transcript = try await transcribe(url, language)
        let timing = try NarrationAlignment.align(beats: beats, transcript: transcript, duration: duration,
                                                  revision: revision, fingerprint: before)
        try Task.checkCancellation()
        guard try await Self.fingerprint(url) == before else {
            throw EditPlanValidationError.invalidReference("Narration file changed during alignment; retry with the current source.")
        }
        try Task.checkCancellation()
        if timing.unresolvedBeatIds.isEmpty { cachedTiming = (source, language, beats, timing) }
        return timing
    }

    static func fingerprint(_ url: URL) async throws -> String {
        try await MediaInputIdentityService.shared.identify(url, force: true).contentSHA256
    }
}
