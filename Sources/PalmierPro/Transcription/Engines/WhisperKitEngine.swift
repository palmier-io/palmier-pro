// Whisper large-v3-turbo on-device ASR via WhisperKit (CoreML/ANE) — multilingual with
// per-window language detection and word-level timestamps; also serves as the timing
// track for the Qwen3 engine's word alignment.
// NOTE: WhisperKit's result types share names with ours and cannot be spelled from here
// (the WhisperKit class shadows its module), so the mapping loop is duplicated in both
// transcribe variants and relies on type inference throughout.
import Foundation
import WhisperKit

actor WhisperKitEngine {
    static let shared = WhisperKitEngine()

    enum EngineError: LocalizedError {
        case loadFailed(String)
        case incompleteResult(covered: Double, expected: Double)

        var errorDescription: String? {
            switch self {
            case .loadFailed(let reason): "Could not load the Whisper model: \(reason)"
            case .incompleteResult(let covered, let expected):
                "Whisper transcript covers only \(Int(covered))s of \(Int(expected))s of speech."
            }
        }
    }

    private static let modelName = "large-v3_turbo"
    private static let downloadBase = ModelDownloader.modelsDir
        .appendingPathComponent("whisperkit", isDirectory: true)

    private var pipe: WhisperKit?

    static var isInstalled: Bool {
        guard let contents = try? FileManager.default.subpathsOfDirectory(atPath: downloadBase.path) else {
            return false
        }
        return contents.contains { $0.hasSuffix("MelSpectrogram.mlmodelc") || $0.contains(modelName) }
    }

    func transcribe(fileURL: URL, language: String? = nil) async throws -> TranscriptionResult {
        let pipe = try await loadedPipe()
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            wordTimestamps: true
        )
        try Task.checkCancellation()
        let resultsPerFile = await pipe.transcribe(audioPaths: [fileURL.path], decodeOptions: options)
        try Task.checkCancellation()
        guard let fileResults = resultsPerFile.first ?? nil else {
            return TranscriptionResult(text: "", language: nil, words: [], segments: [])
        }

        var words: [TranscriptionWord] = []
        var segments: [TranscriptionSegment] = []
        var detectedLanguage: String?
        for result in fileResults {
            if detectedLanguage == nil { detectedLanguage = result.language }
            for segment in result.segments {
                let text = segment.text
                    .replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    segments.append(TranscriptionSegment(
                        text: text, start: Double(segment.start), end: Double(segment.end)))
                }
                for word in segment.words ?? [] {
                    let wordText = word.word.trimmingCharacters(in: .whitespaces)
                    guard !wordText.isEmpty else { continue }
                    words.append(TranscriptionWord(
                        text: wordText, start: Double(word.start), end: Double(word.end)))
                }
            }
        }
        // Guard against an interrupted decode being cached as complete: reject a transcript whose
        // speech ends grossly short of the audio's non-silent end.
        // Fail closed: if the verification reload fails we cannot prove coverage, and returning the
        // transcript unchecked would let a truncated decode be cached as complete.
        let samples = try EngineAudio.loadSamples(fileURL: fileURL)
        if let gap = EngineAudio.coverageShortfall(segments: segments, samples: samples) {
            throw EngineError.incompleteResult(covered: gap.covered, expected: gap.expected)
        }
        return TranscriptionResult(
            text: segments.map(\.text).joined(separator: " "),
            language: detectedLanguage,
            words: words,
            segments: segments
        )
    }

    /// Transcribe raw 16kHz mono samples. Forcing `language` suppresses Whisper's
    /// translate-the-minority-language behavior on code-switched audio.
    func transcribe(samples: [Float], language: String? = nil) async throws -> TranscriptionResult {
        let pipe = try await loadedPipe()
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            wordTimestamps: true
        )
        let resultsPerArray = await pipe.transcribe(audioArrays: [samples], decodeOptions: options)
        guard let arrayResults = resultsPerArray.first ?? nil else {
            return TranscriptionResult(text: "", language: nil, words: [], segments: [])
        }

        var words: [TranscriptionWord] = []
        var segments: [TranscriptionSegment] = []
        var detectedLanguage: String?
        for result in arrayResults {
            if detectedLanguage == nil { detectedLanguage = result.language }
            for segment in result.segments {
                let text = segment.text
                    .replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    segments.append(TranscriptionSegment(
                        text: text, start: Double(segment.start), end: Double(segment.end)))
                }
                for word in segment.words ?? [] {
                    let wordText = word.word.trimmingCharacters(in: .whitespaces)
                    guard !wordText.isEmpty else { continue }
                    words.append(TranscriptionWord(
                        text: wordText, start: Double(word.start), end: Double(word.end)))
                }
            }
        }
        return TranscriptionResult(
            text: segments.map(\.text).joined(separator: " "),
            language: detectedLanguage,
            words: words,
            segments: segments
        )
    }

    private func loadedPipe() async throws -> WhisperKit {
        if let pipe { return pipe }
        do {
            try FileManager.default.createDirectory(at: Self.downloadBase, withIntermediateDirectories: true)
            let loaded = try await WhisperKit(
                model: Self.modelName,
                downloadBase: Self.downloadBase,
                verbose: false,
                logLevel: .error
            )
            pipe = loaded
            return loaded
        } catch {
            throw EngineError.loadFailed(error.localizedDescription)
        }
    }
}
