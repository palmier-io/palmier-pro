import AVFoundation
import Foundation

/// Local speech synthesis through the Mac's installed system voices. Renders on-device —
/// no server, no account, no credits. The spoken-word counterpart to `DroneSynthesizer`.
enum SpeechSynthesizer {
    /// Upper bound on one utterance handed to the synthesizer. Text is split on sentence
    /// boundaries and rendered a chunk at a time, which bounds how long a single wait can
    /// last and where a cancelled run stops.
    static let maxChunkCharacters = 400

    /// Ceiling on `Spec.text`. Past this a local render stops being interactive, and a
    /// transcript this long is a sign the caller wants several clips, not one.
    static let maxCharacters = 20_000

    struct Spec: Sendable {
        var text: String
        var voiceIdentifier: String?
        var language: String?
        /// Multiplier over the system default speaking rate. 1.0 is normal delivery.
        var rate: Double
        /// 1.0 is the voice's natural pitch.
        var pitch: Double
    }

    struct Voice: Sendable, Hashable, Identifiable {
        var id: String { identifier }
        let identifier: String
        let name: String
        let language: String
        let gender: String
        let isEnhanced: Bool
    }

    enum SpeechError: LocalizedError, Equatable {
        case emptyText
        case textTooLong(Int)
        case unknownVoice(String, [String])
        case unsupportedLanguage(String, [String])
        case noInstalledVoice
        case silentRender

        var errorDescription: String? {
            switch self {
            case .emptyText:
                "Nothing to speak. Pass text, or point at a clip that has a transcript."
            case .textTooLong(let limit):
                "Text is longer than the \(limit)-character limit for one local render. Split it into several calls."
            case .unknownVoice(let name, let candidates):
                "No installed voice matches '\(name)'."
                    + (candidates.isEmpty ? "" : " Closest: \(candidates.joined(separator: ", ")).")
                    + " Call list_speech_voices to see what this Mac has, or omit voice to use the best voice for the language."
            case .unsupportedLanguage(let language, let available):
                "No voice is installed for '\(language)'. Installed languages: \(available.joined(separator: ", "))."
            case .noInstalledVoice:
                "This Mac has no installed speech voices. Add one in System Settings › Accessibility › Spoken Content."
            case .silentRender:
                "The system voice produced no audio. Try a different voice, or a shorter passage."
            }
        }
    }

    // MARK: - Voices

    static func voices() -> [Voice] {
        AVSpeechSynthesisVoice.speechVoices()
            .map {
                Voice(
                    identifier: $0.identifier,
                    name: $0.name,
                    language: $0.language,
                    gender: $0.gender == .unspecified ? "unspecified" : String(describing: $0.gender),
                    isEnhanced: $0.quality == .enhanced
                )
            }
            .sorted { ($0.language, $0.name) < ($1.language, $1.name) }
    }

    static func installedLanguages() -> [String] {
        Set(voices().map(\.language)).sorted()
    }

    /// Voices whose language matches `language` by exact tag or by base language, so `en`,
    /// `en-GB` and `en_US` all reach the English voices.
    static func voices(matchingLanguage language: String?) -> [Voice] {
        let all = voices()
        guard let language, !language.isEmpty else { return all }
        let base = language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? language
        let lowered = language.lowercased()
        return all.filter {
            $0.language.lowercased() == lowered
                || $0.language.lowercased().hasPrefix(base.lowercased() + "_")
                || $0.language.lowercased().hasPrefix(base.lowercased() + "-")
        }
    }

    /// The voices a caller can actually pass to `voice`, named for an error message.
    static func voiceNames(matchingLanguage language: String? = nil, limit: Int = 10) -> (names: [String], total: Int) {
        let matching = voices(matchingLanguage: language)
        let preferred = matching.isEmpty ? voices() : matching
        return (preferred.prefix(limit).map(\.name), preferred.count)
    }

    static func resolveVoice(spec: Spec) throws -> AVSpeechSynthesisVoice {
        let installed = voices()
        guard !installed.isEmpty else { throw SpeechError.noInstalledVoice }

        if let wanted = spec.voiceIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !wanted.isEmpty {
            if let exact = installed.first(where: { $0.identifier == wanted }) {
                guard let voice = AVSpeechSynthesisVoice(identifier: exact.identifier) else {
                    throw SpeechError.unknownVoice(wanted, [])
                }
                return voice
            }
            let lowered = wanted.lowercased()
            let named = installed.filter { $0.name.lowercased() == lowered || $0.identifier.lowercased() == lowered }
            guard let match = named.first,
                  let voice = AVSpeechSynthesisVoice(identifier: match.identifier) else {
                throw SpeechError.unknownVoice(wanted, nearMatches(installed, wanted))
            }
            return voice
        }

        if let language = spec.language?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty {
            let base = language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? language
            let matching = installed.filter { $0.language == language || $0.language.hasPrefix(base + "_") || $0.language.hasPrefix(base + "-") }
            guard !matching.isEmpty else {
                throw SpeechError.unsupportedLanguage(language, installedLanguages())
            }
            guard let voice = AVSpeechSynthesisVoice(identifier: matching[0].identifier) ?? AVSpeechSynthesisVoice(language: language) else {
                throw SpeechError.unsupportedLanguage(language, installedLanguages())
            }
            return voice
        }

        let preferred = Locale.current.identifier
        if let voice = AVSpeechSynthesisVoice(language: preferred)
            ?? installed.first.flatMap({ AVSpeechSynthesisVoice(identifier: $0.identifier) }) {
            return voice
        }
        throw SpeechError.noInstalledVoice
    }

    private static func nearMatches(_ installed: [Voice], _ wanted: String) -> [String] {
        let needle = wanted.lowercased()
        let close = installed
            .filter { $0.name.lowercased().contains(needle) || needle.contains($0.name.lowercased()) }
            .prefix(5)
            .map { "\($0.name) (\($0.language))" }
        if !close.isEmpty { return Array(close) }
        // Nothing resembles the name, so name real voices instead — guessing is how a caller
        // ends up asking for a voice this Mac never had.
        let (names, _) = voiceNames()
        return Array(names.prefix(8))
    }


    // MARK: - Chunking

    /// Splits on sentence terminators so each chunk breathes like a sentence, then merges
    /// short pieces and hard-splits run-on text that never terminates. Interior whitespace is
    /// preserved exactly: dropping the space after a full stop makes the voice run the last
    /// word of one sentence into the first word of the next.
    static func chunks(of text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if ".!?\n".contains(character) {
                sentences.append(current)
                current = ""
            }
        }
        if !current.isEmpty { sentences.append(current) }

        var merged: [String] = []
        var pending = ""
        for sentence in sentences where !sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if pending.count + sentence.count <= maxChunkCharacters {
                pending += sentence
                continue
            }
            if !pending.isEmpty { merged.append(pending) }
            guard sentence.count > maxChunkCharacters else {
                pending = sentence
                continue
            }
            var remainder = sentence
            while remainder.count > maxChunkCharacters {
                let head = String(remainder.prefix(maxChunkCharacters))
                let split = head.lastIndex(of: " ") ?? head.endIndex
                merged.append(String(head[head.startIndex..<split]))
                remainder = String(remainder[split...])
            }
            pending = remainder
        }
        if !pending.isEmpty { merged.append(pending) }
        return merged
    }

    // MARK: - Rendering

    /// Renders `spec` to a temporary WAV and returns its URL. The caller owns the file.
    /// Runs off the main actor on a private queue; the file is removed if anything fails.
    static func render(spec: Spec) async throws -> URL {
        let trimmed = spec.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SpeechError.emptyText }
        guard trimmed.count <= maxCharacters else { throw SpeechError.textTooLong(maxCharacters) }
        guard !chunks(of: trimmed).isEmpty else { throw SpeechError.emptyText }

        var resolved = spec
        resolved.text = trimmed

        let gate = CancellationGate()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                renderQueue.async {
                    do {
                        continuation.resume(returning: try renderSync(spec: resolved, isCancelled: { gate.isCancelled }))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            gate.cancel()
        }
    }

    /// Retries for a chunk that produced no audio. Concurrency in the suite and a busy machine
    /// can both starve the voice engine for a moment.
    private static let maxChunkAttempts = 3

    private static let renderQueue = DispatchQueue(label: "com.compositorpro.speech.render", qos: .utility)

    private static func renderSync(spec: Spec, isCancelled: () -> Bool) throws -> URL {
        let voice = try resolveVoice(spec: spec)
        let parts = chunks(of: spec.text)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-\(UUID().uuidString).wav")

        do {
            // The voice's own file settings are what `write(_:toBufferCallback:)` emits, so the
            // file format and the buffer format are the same by construction.
            var written: AVAudioFramePosition = 0
            // Scoped so the file is released — and its header finalised — before the caller
            // is handed a URL to read.
            try {
                let file = try AVAudioFile(forWriting: url, settings: voice.audioFileSettings)
                let synthesizer = AVSpeechSynthesizer()
                for part in parts {
                    if isCancelled() { throw CancellationError() }
                    // A chunk that yields no audio did not render. The engine reports this as an
                    // immediate empty buffer, which is indistinguishable from a normal end of
                    // stream unless it is checked against an actual frame count — so it is
                    // retried rather than accepted as silence.
                    var frames: AVAudioFramePosition = 0
                    for attempt in 1...maxChunkAttempts {
                        let utterance = AVSpeechUtterance(string: part)
                        utterance.voice = voice
                        utterance.rate = (AVSpeechUtteranceDefaultSpeechRate * Float(spec.rate))
                            .clamped(to: AVSpeechUtteranceMinimumSpeechRate...AVSpeechUtteranceMaximumSpeechRate)
                        utterance.pitchMultiplier = Float(spec.pitch).clamped(to: 0.5...2.0)
                        frames = try write(synthesizer, utterance, into: file)
                        if frames > 0 { break }
                        if isCancelled() { throw CancellationError() }
                        if attempt == maxChunkAttempts { throw SpeechError.silentRender }
                    }
                    written += frames
                }
            }()
            guard written > 0 else { throw SpeechError.silentRender }
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private static func write(_ synthesizer: AVSpeechSynthesizer, _ utterance: AVSpeechUtterance, into file: AVAudioFile) throws -> AVAudioFramePosition {
        let sink = BufferSink(file: file)
        synthesizer.write(utterance) { buffer in sink.consume(buffer) }
        let frames = try sink.wait()
        // The synthesizer keeps the callback alive after it returns, so the sink — and through
        // it the output file — outlives this scope. AVAudioFile only finalises the WAV header
        // when it is released, so a reader can see a complete file advertised as zero-length.
        // Releasing it here makes the finished file readable the moment this returns.
        sink.detach()
        return frames
    }

    /// Serializes every touch of the output file and releases the waiter exactly once. The
    /// synthesizer keeps emitting after a write failure, so a plain `leave()` per callback
    /// would over-release; `done` makes the terminal callback the only one that finishes it.
    private final class BufferSink: @unchecked Sendable {
        private let lock = NSLock()
        private let group = DispatchGroup()
        private var file: AVAudioFile?
        private var done = false
        private var failure: Error?
        private var frames: AVAudioFramePosition = 0

        init(file: AVAudioFile) {
            self.file = file
            group.enter()
        }

        func consume(_ buffer: AVAudioBuffer) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            // The stream ends with an empty buffer, and anything that is not PCM has no frames
            // to write; both are terminal.
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                done = true
                group.leave()
                return
            }
            do {
                try file?.write(from: pcm)
                frames += AVAudioFramePosition(pcm.frameLength)
            } catch {
                done = true
                failure = error
                group.leave()
            }
        }

        /// Releases the output file. Callers must not feed this sink afterwards.
        func detach() {
            lock.lock()
            defer { lock.unlock() }
            file = nil
        }

        func wait() throws -> AVAudioFramePosition {
            group.wait()
            lock.lock()
            defer { lock.unlock() }
            if let failure { throw failure }
            return frames
        }
    }
}

/// Cooperative cancellation for work that owns its own queue: the caller's cancellation
/// handler sets the flag and the render loop checks it between chunks.
private final class CancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
