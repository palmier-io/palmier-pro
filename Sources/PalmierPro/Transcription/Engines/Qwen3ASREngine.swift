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

        // Timing track: Whisper runs concurrently on its own actor (CoreML/ANE, so the
        // hardware doesn't contend with Qwen3's CPU decode below). Qwen3's text is
        // authoritative; Whisper's DTW word timestamps only anchor timing. If it fails
        // (e.g. model download offline), words fall back to interpolation.
        let timingTask = Task { try await WhisperKitEngine.shared.transcribe(fileURL: fileURL) }

        let samples = try EngineAudio.loadSamples(fileURL: fileURL)
        var chunks: [(text: String, start: Double, end: Double)] = []
        var chunkStart = 0
        while chunkStart < samples.count {
            let chunkEnd = EngineAudio.chunkBoundary(
                samples: samples, from: chunkStart, targetSeconds: Self.chunkSeconds)
            let chunk = Array(samples[chunkStart..<chunkEnd])
            let start = Double(chunkStart) / Double(EngineAudio.sampleRate)
            let end = Double(chunkEnd) / Double(EngineAudio.sampleRate)
            let text = Self.decodeChunk(recognizer: recognizer, samples: chunk)
            if !text.isEmpty {
                chunks.append((text, start, end))
            }
            chunkStart = chunkEnd
        }

        let timingWords = Self.expandCJKAnchors((try? await timingTask.value)?.words ?? [])
        var words: [TranscriptionWord] = []
        var segments: [TranscriptionSegment] = []
        for chunk in chunks {
            let pieces = Self.splitPieces(text: chunk.text)
            let anchors = timingWords.filter { word in
                guard let start = word.start, let end = word.end else { return false }
                return end > chunk.start - 1.0 && start < chunk.end + 1.0
            }
            let chunkWords = Self.alignWords(
                pieces: pieces, anchors: anchors, chunkStart: chunk.start, chunkEnd: chunk.end)
            words.append(contentsOf: chunkWords)
            segments.append(TranscriptionSegment(
                text: chunk.text,
                start: chunkWords.first?.start ?? chunk.start,
                end: chunkWords.last?.end ?? chunk.end
            ))
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

    // MARK: - Word timing (Whisper anchor alignment)

    /// Split Qwen3 text into display words: CJK characters stand alone, latin runs group.
    private static func splitPieces(text: String) -> [String] {
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
        return pieces
    }

    /// Whisper emits CJK as multi-character words ("小面" with one time range) while our
    /// pieces are single characters; split such anchors into per-char anchors with
    /// linearly divided time so the LCS can match them.
    private static func expandCJKAnchors(_ words: [TranscriptionWord]) -> [TranscriptionWord] {
        var expanded: [TranscriptionWord] = []
        for word in words {
            let cjkScalars = word.text.unicodeScalars.filter { (0x2E80...0x9FFF).contains(Int($0.value)) }
            guard cjkScalars.count > 1, let start = word.start, let end = word.end else {
                expanded.append(word)
                continue
            }
            let step = (end - start) / Double(cjkScalars.count)
            for (index, scalar) in cjkScalars.enumerated() {
                expanded.append(TranscriptionWord(
                    text: String(scalar),
                    start: start + Double(index) * step,
                    end: start + Double(index + 1) * step
                ))
            }
        }
        return expanded
    }

    /// Lowercased, punctuation-free comparison key ("" for punctuation-only pieces).
    private static func matchKey(_ piece: String) -> String {
        String(piece.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || (0x2E80...0x9FFF).contains(Int($0.value))
        })
    }

    /// Pin Qwen3 pieces to Whisper's real timestamps where the transcripts agree
    /// (longest-common-subsequence on normalized text), interpolating between anchors.
    private static func alignWords(
        pieces: [String], anchors: [TranscriptionWord], chunkStart: Double, chunkEnd: Double
    ) -> [TranscriptionWord] {
        guard !pieces.isEmpty else { return [] }
        let pieceKeys = pieces.map(matchKey)
        let anchorKeys = anchors.map { matchKey($0.text) }

        // LCS traceback → (pieceIndex, anchorIndex) matched pairs, in order.
        var matched: [(piece: Int, anchor: Int)] = []
        if !anchors.isEmpty {
            let n = pieces.count, m = anchors.count
            var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    if !pieceKeys[i].isEmpty && pieceKeys[i] == anchorKeys[j] {
                        dp[i][j] = dp[i + 1][j + 1] + 1
                    } else {
                        dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                    }
                }
            }
            var i = 0, j = 0
            while i < n && j < m {
                if !pieceKeys[i].isEmpty && pieceKeys[i] == anchorKeys[j] {
                    matched.append((i, j))
                    i += 1; j += 1
                } else if dp[i + 1][j] >= dp[i][j + 1] {
                    i += 1
                } else {
                    j += 1
                }
            }
        }

        // Assign anchored times, then fill gaps by character-weight interpolation.
        var starts = [Double?](repeating: nil, count: pieces.count)
        var ends = [Double?](repeating: nil, count: pieces.count)
        for (pieceIndex, anchorIndex) in matched {
            starts[pieceIndex] = anchors[anchorIndex].start
            ends[pieceIndex] = anchors[anchorIndex].end
        }

        var result: [TranscriptionWord] = []
        var index = 0
        var lastEnd = chunkStart
        while index < pieces.count {
            if let start = starts[index], let end = ends[index] {
                let clampedStart = max(start, lastEnd)
                result.append(TranscriptionWord(text: pieces[index], start: clampedStart, end: max(end, clampedStart)))
                lastEnd = max(end, clampedStart)
                index += 1
                continue
            }
            // Unanchored run: interpolate between the previous anchor end and the next anchor start.
            var runEnd = index
            while runEnd < pieces.count && starts[runEnd] == nil { runEnd += 1 }
            let windowEnd = runEnd < pieces.count ? (starts[runEnd] ?? chunkEnd) : chunkEnd
            let window = max(0.1, windowEnd - lastEnd)
            let runWeights = (index..<runEnd).map { Double(max(1, pieces[$0].count)) }
            let totalWeight = runWeights.reduce(0, +)
            var cursor = lastEnd
            for (offset, weight) in runWeights.enumerated() {
                let duration = window * weight / totalWeight
                result.append(TranscriptionWord(
                    text: pieces[index + offset], start: cursor, end: cursor + duration))
                cursor += duration
            }
            lastEnd = cursor
            index = runEnd
        }
        return result
    }
}
