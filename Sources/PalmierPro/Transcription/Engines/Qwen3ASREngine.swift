// Qwen3-ASR 0.6B on-device via sherpa-onnx — Alibaba's newest open ASR (30+ languages,
// 20+ Chinese dialects, native code-switching). The sherpa port emits no token timestamps,
// so segments carry chunk-accurate times (audio is split at quiet points every ~12s) and
// word times are interpolated inside each chunk by character weight.
import CSherpaOnnx
import Foundation

actor Qwen3ASREngine {
    static let shared = Qwen3ASREngine()

    enum EngineError: LocalizedError {
        case modelDownloadFailed(String)
        case recognizerInitFailed

        var errorDescription: String? {
            switch self {
            case .modelDownloadFailed(let reason): "Qwen3-ASR model download failed: \(reason)"
            case .recognizerInitFailed: "Could not initialize the Qwen3-ASR recognizer."
            }
        }
    }

    private static let modelArchiveName = "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25"
    private static let modelArchiveURL = URL(string:
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/\(modelArchiveName).tar.bz2")!
    private static let installDir = ModelDownloader.modelsDir
        .appendingPathComponent("qwen3-asr-0.6B-int8", isDirectory: true)

    /// 12s chunks: dense Mandarin stays well inside the decoder's 128-new-token budget.
    private static let chunkSeconds = 12.0

    private var recognizer: OpaquePointer?

    static var isInstalled: Bool {
        installedFiles != nil
    }

    /// Model archives name their ONNX files with version suffixes; resolve by pattern.
    private static var installedFiles: (convFrontend: String, encoder: String, decoder: String, tokenizer: String)? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: installDir.path) else { return nil }
        func find(_ needle: String, ext: String = "onnx") -> String? {
            entries.first { $0.localizedCaseInsensitiveContains(needle) && $0.hasSuffix(".\(ext)") }
                .map { installDir.appendingPathComponent($0).path }
        }
        guard let conv = find("conv") ?? find("frontend"),
              let encoder = find("encoder"),
              let decoder = find("decoder") else { return nil }
        // Tokenizer is a directory containing vocab.json (or the install dir itself holds it).
        let tokenizerDir: String
        if fm.fileExists(atPath: installDir.appendingPathComponent("vocab.json").path) {
            tokenizerDir = installDir.path
        } else if let sub = entries.first(where: {
            fm.fileExists(atPath: installDir.appendingPathComponent($0).appendingPathComponent("vocab.json").path)
        }) {
            tokenizerDir = installDir.appendingPathComponent(sub).path
        } else {
            return nil
        }
        return (conv, encoder, decoder, tokenizerDir)
    }

    static func ensureModel() async throws {
        if isInstalled { return }
        Log.transcription.notice("qwen3-asr model download start (~840MB)", telemetry: "Qwen3 model download started")
        let (temp, response) = try await URLSession.shared.download(from: modelArchiveURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: temp)
            throw EngineError.modelDownloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen3-\(UUID().uuidString)", isDirectory: true)
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
        try FileManager.default.createDirectory(
            at: installDir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: installDir)
        try FileManager.default.moveItem(at: extracted, to: installDir)
        guard isInstalled else { throw EngineError.modelDownloadFailed("archive missing expected model files") }
        Log.transcription.notice("qwen3-asr model installed", telemetry: "Qwen3 model installed")
    }

    func transcribe(fileURL: URL) async throws -> TranscriptionResult {
        try await Self.ensureModel()
        let recognizer = try loadedRecognizer()

        let samples = try EngineAudio.loadSamples(fileURL: fileURL)
        var words: [TranscriptionWord] = []
        var segments: [TranscriptionSegment] = []
        var chunkStart = 0
        while chunkStart < samples.count {
            let chunkEnd = EngineAudio.chunkBoundary(
                samples: samples, from: chunkStart, targetSeconds: Self.chunkSeconds)
            let chunk = Array(samples[chunkStart..<chunkEnd])
            let start = Double(chunkStart) / Double(EngineAudio.sampleRate)
            let end = Double(chunkEnd) / Double(EngineAudio.sampleRate)
            let text = Self.decodeChunk(recognizer: recognizer, samples: chunk)
            if !text.isEmpty {
                segments.append(TranscriptionSegment(text: text, start: start, end: end))
                words.append(contentsOf: Self.interpolatedWords(text: text, start: start, end: end))
            }
            chunkStart = chunkEnd
        }

        return TranscriptionResult(
            text: segments.map(\.text).joined(separator: " "),
            language: "multi",
            words: words,
            segments: segments
        )
    }

    private func loadedRecognizer() throws -> OpaquePointer {
        if let recognizer { return recognizer }
        guard let files = Self.installedFiles else { throw EngineError.recognizerInitFailed }

        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = 16_000
        config.feat_config.feature_dim = 80
        var created: OpaquePointer?
        files.convFrontend.withCString { convPtr in
            files.encoder.withCString { encPtr in
                files.decoder.withCString { decPtr in
                    files.tokenizer.withCString { tokPtr in
                        "greedy_search".withCString { decodePtr in
                            "cpu".withCString { providerPtr in
                                config.model_config.qwen3_asr.conv_frontend = convPtr
                                config.model_config.qwen3_asr.encoder = encPtr
                                config.model_config.qwen3_asr.decoder = decPtr
                                config.model_config.qwen3_asr.tokenizer = tokPtr
                                config.model_config.qwen3_asr.max_total_len = 512
                                config.model_config.qwen3_asr.max_new_tokens = 128
                                config.model_config.qwen3_asr.temperature = 1e-6
                                config.model_config.qwen3_asr.top_p = 0.8
                                config.model_config.qwen3_asr.seed = 42
                                config.model_config.num_threads = 4
                                config.model_config.provider = providerPtr
                                config.decoding_method = decodePtr
                                created = SherpaOnnxCreateOfflineRecognizer(&config)
                            }
                        }
                    }
                }
            }
        }
        guard let created else { throw EngineError.recognizerInitFailed }
        recognizer = created
        return created
    }

    private static func decodeChunk(recognizer: OpaquePointer, samples: [Float]) -> String {
        guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else { return "" }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        samples.withUnsafeBufferPointer {
            SherpaOnnxAcceptWaveformOffline(stream, Int32(EngineAudio.sampleRate), $0.baseAddress, Int32(samples.count))
        }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { return "" }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
        guard let textPtr = result.pointee.text else { return "" }
        return String(cString: textPtr).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The sherpa Qwen3 port has no token timestamps; distribute word times across the
    /// chunk proportionally by character count (CJK chars count as words on their own).
    private static func interpolatedWords(text: String, start: Double, end: Double) -> [TranscriptionWord] {
        var pieces: [String] = []
        for token in text.split(separator: " ") {
            var latin = ""
            for scalar in token.unicodeScalars {
                if (0x2E80...0x9FFF).contains(Int(scalar.value)) || (0xF900...0xFAFF).contains(Int(scalar.value)) {
                    if !latin.isEmpty { pieces.append(latin); latin = "" }
                    pieces.append(String(scalar))
                } else {
                    latin.unicodeScalars.append(scalar)
                }
            }
            if !latin.isEmpty { pieces.append(latin) }
        }
        guard !pieces.isEmpty else { return [] }
        let totalWeight = pieces.reduce(0) { $0 + max(1, $1.count) }
        let duration = max(0.1, end - start)
        var cursor = start
        return pieces.map { piece in
            let weight = Double(max(1, piece.count)) / Double(totalWeight)
            let wordStart = cursor
            cursor += weight * duration
            return TranscriptionWord(text: piece, start: wordStart, end: cursor)
        }
    }
}
