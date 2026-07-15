// SenseVoice on-device multilingual ASR via sherpa-onnx — transcribes code-switched
// zh/en/ja/ko/yue speech that the single-locale Apple Speech path drops silently.
// Model: sense-voice int8 (~160MB), downloaded on first use into Application Support.
import AVFoundation
import CSherpaOnnx
import Foundation

actor SenseVoiceEngine {
    static let shared = SenseVoiceEngine()

    enum EngineError: LocalizedError {
        case modelDownloadFailed(String)
        case recognizerInitFailed
        case audioReadFailed(String)

        var errorDescription: String? {
            switch self {
            case .modelDownloadFailed(let reason): "SenseVoice model download failed: \(reason)"
            case .recognizerInitFailed: "Could not initialize the SenseVoice recognizer."
            case .audioReadFailed(let reason): "Could not read audio for transcription: \(reason)"
            }
        }
    }

    private static let modelArchiveName = "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09"
    private static let modelArchiveURL = URL(string:
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/\(modelArchiveName).tar.bz2")!
    private static let installDir = ModelDownloader.modelsDir
        .appendingPathComponent("sense-voice-int8-2025-09-09", isDirectory: true)

    /// Chunk long audio near this length, cutting at the quietest sample around the boundary.
    private static let chunkSeconds = 28.0
    private static let chunkSearchSpanSeconds = 2.5
    private static let sampleRate = 16_000

    private var recognizer: OpaquePointer?

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installDir.appendingPathComponent("model.int8.onnx").path)
            && FileManager.default.fileExists(atPath: installDir.appendingPathComponent("tokens.txt").path)
    }

    /// Idempotent download + extract of the model archive.
    static func ensureModel() async throws {
        if isInstalled { return }
        Log.transcription.notice("sensevoice model download start", telemetry: "SenseVoice model download started")
        let (temp, response) = try await URLSession.shared.download(from: modelArchiveURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: temp)
            throw EngineError.modelDownloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensevoice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: temp)
        }
        let untar = Process()
        untar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        untar.arguments = ["-xjf", temp.path, "-C", staging.path]
        try untar.run()
        untar.waitUntilExit()
        guard untar.terminationStatus == 0 else { throw EngineError.modelDownloadFailed("archive extraction failed") }

        let extracted = staging.appendingPathComponent(modelArchiveName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: extracted.appendingPathComponent("model.int8.onnx").path) else {
            throw EngineError.modelDownloadFailed("archive missing model.int8.onnx")
        }
        try FileManager.default.createDirectory(
            at: installDir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: installDir)
        try FileManager.default.moveItem(at: extracted, to: installDir)
        Log.transcription.notice("sensevoice model installed", telemetry: "SenseVoice model installed")
    }

    /// Transcribe a 16kHz-mono-decodable audio file. `language` is a SenseVoice hint
    /// ("zh", "en", "ja", "ko", "yue") or empty for auto — code-switched audio should use auto.
    func transcribe(fileURL: URL, language: String = "") async throws -> TranscriptionResult {
        try await Self.ensureModel()
        let recognizer = try recognizer(language: language)

        let samples = try EngineAudio.loadSamples(fileURL: fileURL)
        var words: [TranscriptionWord] = []
        var chunkStart = 0
        while chunkStart < samples.count {
            let chunkEnd = EngineAudio.chunkBoundary(
                samples: samples, from: chunkStart, targetSeconds: Self.chunkSeconds)
            let chunk = Array(samples[chunkStart..<chunkEnd])
            let offset = Double(chunkStart) / Double(Self.sampleRate)
            words.append(contentsOf: Self.decodeChunk(recognizer: recognizer, samples: chunk, offset: offset))
            chunkStart = chunkEnd
        }

        let segments = Self.buildSegments(from: words)
        return TranscriptionResult(
            text: segments.map(\.text).joined(separator: " "),
            language: "multi",
            words: words,
            segments: segments
        )
    }

    // MARK: - Recognizer lifecycle

    private func recognizer(language: String) throws -> OpaquePointer {
        // Language hint is baked into the config; recreate when it changes (rare — auto is the norm).
        if let recognizer, language == configuredLanguage { return recognizer }
        if let recognizer { SherpaOnnxDestroyOfflineRecognizer(recognizer); self.recognizer = nil }

        let model = Self.installDir.appendingPathComponent("model.int8.onnx").path
        let tokens = Self.installDir.appendingPathComponent("tokens.txt").path

        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = 16_000
        config.feat_config.feature_dim = 80
        var created: OpaquePointer?
        model.withCString { modelPtr in
            tokens.withCString { tokensPtr in
                language.withCString { langPtr in
                    "greedy_search".withCString { decodePtr in
                        "cpu".withCString { providerPtr in
                            config.model_config.sense_voice.model = modelPtr
                            config.model_config.sense_voice.language = langPtr
                            config.model_config.sense_voice.use_itn = 0
                            config.model_config.tokens = tokensPtr
                            config.model_config.num_threads = 4
                            config.model_config.provider = providerPtr
                            config.decoding_method = decodePtr
                            created = SherpaOnnxCreateOfflineRecognizer(&config)
                        }
                    }
                }
            }
        }
        guard let created else { throw EngineError.recognizerInitFailed }
        recognizer = created
        configuredLanguage = language
        return created
    }

    // No deinit: the shared recognizer lives for the app's lifetime, and Swift 6
    // forbids touching non-Sendable actor state from deinit.
    private var configuredLanguage = ""

    // MARK: - Decoding

    private static func decodeChunk(
        recognizer: OpaquePointer, samples: [Float], offset: Double
    ) -> [TranscriptionWord] {
        guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else { return [] }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        samples.withUnsafeBufferPointer {
            SherpaOnnxAcceptWaveformOffline(stream, Int32(sampleRate), $0.baseAddress, Int32(samples.count))
        }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { return [] }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }

        let count = Int(result.pointee.count)
        guard count > 0, let tokensArr = result.pointee.tokens_arr, let timestamps = result.pointee.timestamps else {
            return []
        }
        var tokens: [(text: String, start: Double)] = []
        for i in 0..<count {
            guard let tokenPtr = tokensArr[i] else { continue }
            let text = String(cString: tokenPtr)
            guard !text.isEmpty else { continue }
            tokens.append((text, Double(timestamps[i]) + offset))
        }
        return mergeTokensIntoWords(tokens)
    }

    /// SenseVoice emits CJK characters as single tokens and English as BPE pieces
    /// ("▁" marks a word start). Merge pieces into words; CJK chars stand alone.
    private static func mergeTokensIntoWords(_ tokens: [(text: String, start: Double)]) -> [TranscriptionWord] {
        var words: [TranscriptionWord] = []
        var pendingText = ""
        var pendingStart = 0.0
        var pendingEnd = 0.0

        func flush() {
            let trimmed = pendingText.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                words.append(TranscriptionWord(text: trimmed, start: pendingStart, end: pendingEnd))
            }
            pendingText = ""
        }

        for (index, token) in tokens.enumerated() {
            let isWordStart = token.text.hasPrefix("▁")
            let cleaned = token.text.replacingOccurrences(of: "▁", with: "")
            guard !cleaned.isEmpty else { continue }
            let isCJK = cleaned.unicodeScalars.first.map { (0x2E80...0x9FFF).contains(Int($0.value)) || (0xF900...0xFAFF).contains(Int($0.value)) } ?? false
            let nextStart = index + 1 < tokens.count ? tokens[index + 1].start : token.start + 0.2
            let end = min(nextStart, token.start + 1.0)

            if isCJK || isWordStart || pendingText.isEmpty {
                flush()
                pendingText = cleaned
                pendingStart = token.start
                pendingEnd = end
            } else {
                pendingText += cleaned
                pendingEnd = end
            }
            if isCJK { flush() }
        }
        flush()
        return words
    }

    /// Group words into caption-sized segments, breaking on pauses.
    private static func buildSegments(from words: [TranscriptionWord]) -> [TranscriptionSegment] {
        guard !words.isEmpty else { return [] }
        var segments: [TranscriptionSegment] = []
        var run: [TranscriptionWord] = []

        func flush() {
            guard !run.isEmpty, let first = run.first?.start, let last = run.last?.end else { run = []; return }
            let text = run.map(\.text).joined(separator: " ")
                .replacingOccurrences(of: " ", with: "", options: [], range: nil)
                .isEmpty ? run.map(\.text).joined() : joinForDisplay(run.map(\.text))
            segments.append(TranscriptionSegment(text: text, start: first, end: last))
            run = []
        }

        for word in words {
            if let last = run.last, let lastEnd = last.end, let start = word.start,
               start - lastEnd > 0.8 || run.count >= 28 {
                flush()
            }
            run.append(word)
        }
        flush()
        return segments
    }

    /// Join with spaces between Latin words but not between CJK characters.
    private static func joinForDisplay(_ pieces: [String]) -> String {
        var out = ""
        for piece in pieces {
            let isCJK = piece.unicodeScalars.first.map { (0x2E80...0x9FFF).contains(Int($0.value)) } ?? false
            let prevIsCJK = out.unicodeScalars.last.map { (0x2E80...0x9FFF).contains(Int($0.value)) } ?? true
            if !out.isEmpty && !(isCJK && prevIsCJK) && !isCJK != !prevIsCJK {
                out += " "
            } else if !out.isEmpty && !isCJK && !prevIsCJK {
                out += " "
            }
            out += piece
        }
        return out
    }
}
