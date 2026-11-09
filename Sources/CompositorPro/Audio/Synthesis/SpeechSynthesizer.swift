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

    /// Which synthesizer produced a render.
    enum Engine: String, Sendable, Equatable {
        /// macOS system voices. Always present, every language macOS ships.
        case system
        /// Piper, a local neural model. Far more natural, but only for installed voices.
        case piper

        var label: String { self == .system ? "macOS system voice" : "Piper (neural)" }
    }

    struct Spec: Sendable {
        var text: String
        var voiceIdentifier: String?
        var language: String?
        /// Multiplier over the system default speaking rate. 1.0 is normal delivery.
        var rate: Double
        /// 1.0 is the voice's natural pitch.
        var pitch: Double
        /// nil picks the engine: Piper when a voice exists for the language, system otherwise.
        var engine: Engine?
    }

    /// What actually rendered a spec, so a caller never has to guess what it got.
    struct RenderResult: Sendable, Equatable {
        var url: URL
        var engine: Engine
        /// Piper voice name, or the system voice identifier.
        var voiceName: String
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


    // MARK: - Prosody

    /// One speakable unit with the delivery it needs to sound human. Derived
    /// from punctuation, so callers pass plain text and the pauses land where
    /// a narrator would put them.
    struct ProsodySegment: Sendable, Equatable {
        var text: String
        /// Silence after this segment, seconds.
        var pauseAfter: Double
        /// Multiplier over the caller's rate. 1.0 is the requested delivery.
        var rateMultiplier: Double
        /// Multiplier over the caller's pitch. 1.0 is the voice's natural pitch.
        var pitchMultiplier: Double
    }

    static let sentencePause: Double = 0.45
    static let expressivePause: Double = 0.6
    static let breathPause: Double = 0.8
    static let linePause: Double = 0.3
    static let clausePause: Double = 0.15

    // MARK: - Chunking

    /// Splits text into speakable segments with per-sentence pauses and pacing.
    /// Whitespace is preserved exactly so words never run together. Segments
    /// that are only whitespace are dropped. Deterministic: same text renders
    /// the same delivery.
    static func prosodySegments(of text: String) -> [ProsodySegment] {
        let raws = splitSentences(text)
        var segments: [ProsodySegment] = []
        segments.reserveCapacity(raws.count)
        for (index, raw) in raws.enumerated() {
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            // A blank line is dropped as whitespace, so count the blank raws
            // ahead: two consecutive newlines upgrade the pause to a breath.
            var blanks = 0
            for ahead in raws[(index + 1)...] {
                guard ahead.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
                blanks += 1
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let pause = blanks >= 2 ? breathPause : pauseAfter(trimmed: trimmed, raw: raw)
            segments.append(ProsodySegment(
                text: raw,
                pauseAfter: pause,
                rateMultiplier: rateFor(trimmed),
                pitchMultiplier: pitchFor(trimmed)
            ))
        }
        return segments
    }

    /// Sentence split that keeps the terminator and following space on the
    /// sentence they belong to. A `.` only ends a sentence before whitespace,
    /// a quote, or the end, so `3.14` stays intact.
    private static func splitSentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            current.append(c)
            if c == "\n" {
                out.append(current)
                current = ""
            } else if c == "." || c == "!" || c == "?" {
                if sentenceEnds(at: i, in: chars), !isAbbreviationDot(at: i, in: chars) {
                    i = swallowTerminatorRun(i, in: chars, current: &current)
                    i = keepTrailingSpace(i, in: chars, current: &current)
                    out.append(current)
                    current = ""
                }
            } else if c == "—" {
                out.append(current)
                current = ""
            }
            i += 1
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static func sentenceEnds(at i: Int, in chars: [Character]) -> Bool {
        guard i + 1 < chars.count else { return true }
        let next = chars[i + 1]
        return next == " " || next == "\n" || next == "\t" || next == "\""
            || next == "'" || next == ")" || next == "]" || ".!?".contains(next)
    }

    /// A `.` between letters (`U.S.A.`) or digits (`3.14`) is not a sentence
    /// end, and neither is a `.` followed by a lowercase word (`e.g. noon`):
    /// sentences start uppercase. The final dot still ends the sentence when
    /// the next word starts a new thought.
    private static func isAbbreviationDot(at i: Int, in chars: [Character]) -> Bool {
        guard chars[i] == "." else { return false }
        guard i > 0, i + 1 < chars.count else { return false }
        let prev = chars[i - 1]
        let next = chars[i + 1]
        if prev.isNumber, next.isNumber { return true }
        if prev.isLetter, next.isLetter { return true }
        if next == " ", i + 2 < chars.count, chars[i + 2].isLowercase { return true }
        return false
    }

    private static func swallowTerminatorRun(_ i: Int, in chars: [Character], current: inout String) -> Int {
        var j = i
        while j + 1 < chars.count, ".!?".contains(chars[j + 1]) {
            j += 1
            current.append(chars[j])
        }
        return j
    }

    private static func keepTrailingSpace(_ i: Int, in chars: [Character], current: inout String) -> Int {
        guard i + 1 < chars.count, chars[i + 1] == " " else { return i }
        current.append(" ")
        return i + 1
    }

    private static func pauseAfter(trimmed: String, raw: String) -> Double {
        if trimmed.hasSuffix("...") || trimmed.hasSuffix("…") { return breathPause }
        if trimmed.hasSuffix("!") || trimmed.hasSuffix("?") { return expressivePause }
        if trimmed.hasSuffix(".") { return sentencePause }
        if trimmed.hasSuffix(",") { return clausePause + 0.1 }
        if trimmed.hasSuffix(":") || trimmed.hasSuffix(";") || trimmed.hasSuffix("—") {
            return clausePause + 0.15
        }
        if raw.hasSuffix("\n") { return linePause }
        return clausePause
    }

    /// Longer sentences slow slightly so they stay intelligible; exclamations
    /// pick up the pace. Bounded to ±6% so the caller's rate still dominates.
    private static func rateFor(_ trimmed: String) -> Double {
        if trimmed.hasSuffix("!"), trimmed.count < 40 { return 1.06 }
        if trimmed.hasSuffix("?") { return 1.03 }
        if trimmed.count > 160 { return 0.94 }
        if trimmed.count > 110 { return 0.97 }
        return 1.0
    }

    /// Questions lift, exclamations lift less, statements fall a touch.
    /// Bounded to ±8% so the caller's pitch still dominates.
    private static func pitchFor(_ trimmed: String) -> Double {
        if trimmed.hasSuffix("?") { return 1.08 }
        if trimmed.hasSuffix("!") { return 1.05 }
        if trimmed.hasSuffix(".") { return 0.99 }
        return 1.0
    }

    /// Splits on sentence terminators so each chunk breathes like a sentence, then merges
    /// short pieces and hard-splits run-on text that never terminates. Interior whitespace is
    /// preserved exactly: dropping the space after a full stop makes the voice run the last
    /// word of one sentence into the first word of the next.
    static func chunks(of text: String) -> [String] {
        segmentGroups(of: text).map { $0.map(\.text).joined() }
    }

    /// Groups prosody segments into render chunks that keep each sentence's
    /// pause with its sentence. An oversized sentence with no terminator
    /// splits mid-run at a space; the pause stays on the final piece.
    static func renderChunks(of text: String) -> [(text: String, pauseAfter: Double)] {
        segmentGroups(of: text).map { group in
            (group.map(\.text).joined(), group.last?.pauseAfter ?? clausePause)
        }
    }

    static func segmentGroups(of text: String) -> [[ProsodySegment]] {
        var merged: [[ProsodySegment]] = []
        var pending: [ProsodySegment] = []
        var pendingCount = 0
        for segment in prosodySegments(of: text) {
            if pendingCount + segment.text.count <= maxChunkCharacters {
                pending.append(segment)
                pendingCount += segment.text.count
                continue
            }
            if !pending.isEmpty { merged.append(pending) }
            guard segment.text.count > maxChunkCharacters else {
                pending = [segment]
                pendingCount = segment.text.count
                continue
            }
            let pieces = hardSplit(segment.text)
            for piece in pieces.dropLast() {
                merged.append([ProsodySegment(
                    text: piece, pauseAfter: clausePause,
                    rateMultiplier: segment.rateMultiplier,
                    pitchMultiplier: segment.pitchMultiplier
                )])
            }
            let last = pieces.last ?? ""
            pending = [ProsodySegment(
                text: last, pauseAfter: segment.pauseAfter,
                rateMultiplier: segment.rateMultiplier,
                pitchMultiplier: segment.pitchMultiplier
            )]
            pendingCount = last.count
        }
        if !pending.isEmpty { merged.append(pending) }
        return merged
    }

    private static func hardSplit(_ sentence: String) -> [String] {
        var pieces: [String] = []
        var remainder = sentence
        while remainder.count > maxChunkCharacters {
            let head = String(remainder.prefix(maxChunkCharacters))
            let split = head.lastIndex(of: " ") ?? head.endIndex
            pieces.append(String(head[head.startIndex..<split]))
            remainder = String(remainder[split...])
        }
        pieces.append(remainder)
        return pieces
    }

    // MARK: - Rendering

    /// Renders `spec` to a temporary WAV and returns its URL. The caller owns the file.
    /// Runs off the main actor on a private queue; the file is removed if anything fails.
    static func render(spec: Spec) async throws -> URL {
        try await renderReportingEngine(spec: spec).url
    }

    /// Same render, but reports which engine and voice produced it so a caller never has to
    /// guess what it got.
    static func renderReportingEngine(spec: Spec) async throws -> RenderResult {
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
                        let result = try renderSync(spec: resolved, isCancelled: { gate.isCancelled })
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            gate.cancel()
        }
    }

    /// Resolves the engine for a spec: an explicit choice wins, otherwise Piper is used when it
    /// is installed and has a voice for the language. Never falls back silently past a choice
    /// the caller made — that would render a different voice than the one asked for.
    static func resolveEngine(for spec: Spec) -> (engine: Engine, model: PiperTTS.Model?) {
        // A named voice is a promise about what will be heard, so a name that matches nothing must
        // never quietly resolve to whatever engine happens to be installed. Resolving to `.system`
        // here is deliberate: `resolveVoice` then refuses with its candidate list, instead of
        // substituting a different voice.
        let namedPiperModel = spec.voiceIdentifier.flatMap { PiperTTS.model(named: $0) }
        let explicit = spec.engine
        switch explicit {
        case .system:
            return (.system, nil)
        case .piper:
            return (.piper, namedPiperModel ?? PiperTTS.model(forLanguage: spec.language))
        case nil:
            if let namedPiperModel { return (.piper, namedPiperModel) }
            // A named voice that is not a Piper voice is a system voice name, or a mistake. Either
            // way it belongs to the system engine, so `resolveVoice` can match it or refuse it —
            // falling through to "first Piper voice installed" would answer with a voice nobody
            // asked for.
            if spec.voiceIdentifier != nil { return (.system, nil) }
            guard PiperTTS.isAvailable else { return (.system, nil) }
            guard let model = PiperTTS.model(forLanguage: spec.language) else { return (.system, nil) }
            return (.piper, model)
        }
    }

    /// Retries for a chunk that produced no audio. Concurrency in the suite and a busy machine
    /// can both starve the voice engine for a moment.
    private static let maxChunkAttempts = 3

    private static let renderQueue = DispatchQueue(label: "com.compositorpro.speech.render", qos: .utility)

    private static func renderSync(spec: Spec, isCancelled: () -> Bool) throws -> RenderResult {
        let (engine, model) = resolveEngine(for: spec)
        if engine == .piper, let model {
            return try renderWithPiper(spec: spec, model: model, isCancelled: isCancelled)
        }
        return RenderResult(
            url: try renderWithSystemVoice(spec: spec, isCancelled: isCancelled),
            engine: .system,
            voiceName: try resolveVoice(spec: spec).identifier
        )
    }

    /// Piper renders whole WAVs per chunk, so the chunks are concatenated sample-accurately
    /// rather than byte-concatenated — a WAV header only describes one stream.
    private static func renderWithPiper(
        spec: Spec, model: PiperTTS.Model, isCancelled: () -> Bool
    ) throws -> RenderResult {
        let groups = segmentGroups(of: spec.text)
        guard !groups.isEmpty else { throw SpeechError.emptyText }
        // Piper's length scale is the inverse of a rate multiplier.
        let baseRate = spec.rate.clamped(to: 0.5...2.0)
        let rendered: [URL] = try groups.map { group in
            if isCancelled() { throw CancellationError() }
            // One subprocess per chunk keeps the engine count bounded; its
            // sentences share the group's mean pacing, and the pause lands
            // as silence between chunks.
            let meanRate = group.map(\.rateMultiplier).reduce(0, +) / Double(max(1, group.count))
            let text = group.map(\.text).joined()
            return try PiperTTS.render(
                text: text, model: model, lengthScale: 1 / (baseRate * meanRate),
                isCancelled: isCancelled
            )
        }
        let url = try concatenate(rendered, pauses: groups.map { $0.last?.pauseAfter ?? 0 })
        return RenderResult(url: url, engine: .piper, voiceName: model.fileName)
    }

    /// Joins per-chunk WAVs into one file.
    ///
    /// A WAV header describes exactly one stream, so byte-concatenation would leave the reader
    /// seeing only the first chunk. The first file's format wins and every chunk must match it;
    /// Piper always renders 22050 Hz mono, so a mismatch means something went wrong upstream.
    /// `pauses` holds the silence after each chunk except the last.
    private static func concatenate(_ files: [URL], pauses: [Double] = []) throws -> URL {
        guard let first = files.first else { throw SpeechError.emptyText }
        // One chunk is already a complete WAV, and it is the file being returned, so it must not
        // be swept up with the staging files.
        guard files.count > 1 else { return first }
        defer { for file in files { try? FileManager.default.removeItem(at: file) } }
        let format = try AVAudioFile(forReading: first).processingFormat
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-\(UUID().uuidString).wav")
        // Scoped, because AVAudioFile only writes a WAV header when it is released. Returning
        // the URL while the writer is still alive hands back a file advertising no audio.
        func write() throws {
            let destination = try AVAudioFile(forWriting: output, settings: format.settings)
            for (index, file) in files.enumerated() {
                let source = try AVAudioFile(forReading: file)
                if source.processingFormat.sampleRate != format.sampleRate
                    || source.processingFormat.channelCount != format.channelCount {
                    continue
                }
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: source.processingFormat,
                    frameCapacity: AVAudioFrameCount(source.length)
                ) else { continue }
                try source.read(into: buffer)
                if buffer.frameLength > 0 { try destination.write(from: buffer) }
                if index < files.count - 1, index < pauses.count, pauses[index] > 0 {
                    // Cap the pause so an ellipsis never inserts a full breath per chunk.
                    let pause = min(pauses[index], 0.6)
                    let frames = AVAudioFrameCount(max(1, Int((pause * format.sampleRate).rounded())))
                    if let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) {
                        silence.frameLength = frames
                        try destination.write(from: silence)
                    }
                }
            }
        }
        try write()
        return output
    }

    private static func renderWithSystemVoice(spec: Spec, isCancelled: () -> Bool) throws -> URL {
        let voice = try resolveVoice(spec: spec)
        let groups = segmentGroups(of: spec.text)
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
                let rate = spec.rate.clamped(to: 0.5...2.0)
                let pitch = spec.pitch.clamped(to: 0.5...2.0)
                for (groupIndex, group) in groups.enumerated() {
                    if isCancelled() { throw CancellationError() }
                    for segment in group {
                        if isCancelled() { throw CancellationError() }
                        written += try renderSegment(
                            segment, voice: voice, rate: rate, pitch: pitch,
                            synthesizer: synthesizer, into: file
                        )
                    }
                    let pause = group.last?.pauseAfter ?? 0
                    if groupIndex < groups.count - 1, pause > 0 {
                        written += try appendSilence(pause, into: file)
                    }
                }
            }()
            guard written > 0 else { throw SpeechError.silentRender }
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Renders one sentence with its own pacing and lift, retrying a chunk
    /// that yields no audio. The engine reports an empty render as an immediate
    /// empty buffer, indistinguishable from a normal end of stream unless it is
    /// checked against an actual frame count.
    private static func renderSegment(
        _ segment: ProsodySegment,
        voice: AVSpeechSynthesisVoice,
        rate: Double,
        pitch: Double,
        synthesizer: AVSpeechSynthesizer,
        into file: AVAudioFile
    ) throws -> AVAudioFramePosition {
        var frames: AVAudioFramePosition = 0
        for attempt in 1...maxChunkAttempts {
            let utterance = AVSpeechUtterance(string: segment.text)
            utterance.voice = voice
            utterance.rate = (AVSpeechUtteranceDefaultSpeechRate * Float(rate * segment.rateMultiplier))
                .clamped(to: AVSpeechUtteranceMinimumSpeechRate...AVSpeechUtteranceMaximumSpeechRate)
            utterance.pitchMultiplier = Float(pitch * segment.pitchMultiplier).clamped(to: 0.5...2.0)
            // Pause before a long sentence reads as a breath, not a stall.
            if segment.text.trimmingCharacters(in: .whitespacesAndNewlines).count > 110 {
                utterance.preUtteranceDelay = 0.08
            }
            // Language default is a full second: at chunk scale that inserts a
            // dead second between every few sentences.
            utterance.postUtteranceDelay = 0
            frames = try write(synthesizer, utterance, into: file)
            if frames > 0 { break }
            if attempt == maxChunkAttempts { throw SpeechError.silentRender }
        }
        return frames
    }

    /// Digital silence matching the destination format, so sentence gaps do not
    /// click when two voiced chunks join.
    private static func appendSilence(_ seconds: Double, into file: AVAudioFile) throws -> AVAudioFramePosition {
        let format = file.processingFormat
        let frames = AVAudioFrameCount(max(1, Int((seconds * format.sampleRate).rounded())))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return 0 }
        buffer.frameLength = frames
        try file.write(from: buffer)
        return AVAudioFramePosition(frames)
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
