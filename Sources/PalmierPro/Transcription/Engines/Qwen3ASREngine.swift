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
        case incompleteResult(covered: Double, expected: Double)

        var errorDescription: String? {
            switch self {
            case .modelDownloadFailed(let reason): "Qwen3-ASR model download failed: \(reason)"
            case .recognizerInitFailed: "Could not initialize the Qwen3-ASR recognizer."
            case .incompleteResult(let covered, let expected):
                "Qwen3-ASR transcript covers only \(Int(covered))s of \(Int(expected))s of speech."
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

    /// In-flight install, so concurrent first callers await one download instead of racing
    /// filesystem extraction (the actor is re-entrant at awaits).
    private var installTask: Task<Void, Error>?

    private func ensureModelOnce() async throws {
        if Self.isInstalled { return }
        if let installTask { return try await installTask.value }
        let task = Task { try await Self.ensureModel() }
        installTask = task
        defer { installTask = nil }
        try await task.value
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
        try await ensureModelOnce()
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
            // Cooperative cancellation: throw between chunks so an interrupted decode never returns a
            // partial transcript that the cache would persist as complete.
            try Task.checkCancellation()
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
            try Task.checkCancellation()
            let pieces = Self.splitPieces(text: chunk.text)
            let anchors = timingWords.filter { word in
                guard let start = word.start, let end = word.end else { return false }
                return end > chunk.start - 1.0 && start < chunk.end + 1.0
            }
            var aligned = Self.alignWords(
                pieces: pieces, anchors: anchors, chunkStart: chunk.start, chunkEnd: chunk.end)

            // Rescue pass: on code-switched audio Whisper's auto-language pass translates
            // CJK speech into English, leaving those runs with no anchors (uniform,
            // fabricated word times). Re-run Whisper on just this chunk with the language
            // forced to suppress translation, and keep whichever alignment anchors more.
            if let language = Self.rescueLanguage(pieces: pieces, alignment: aligned) {
                let sampleStart = max(0, Int(chunk.start * Double(EngineAudio.sampleRate)))
                let sampleEnd = min(samples.count, Int(chunk.end * Double(EngineAudio.sampleRate)))
                if sampleStart < sampleEnd {
                    do {
                        let rescue = try await WhisperKitEngine.shared.transcribe(
                            samples: Array(samples[sampleStart..<sampleEnd]), language: language)
                        let rescueAnchors = Self.expandCJKAnchors(rescue.words).map { word in
                            TranscriptionWord(
                                text: word.text,
                                start: word.start.map { $0 + chunk.start },
                                end: word.end.map { $0 + chunk.start })
                        }
                        let rescued = Self.alignWords(
                            pieces: pieces, anchors: rescueAnchors,
                            chunkStart: chunk.start, chunkEnd: chunk.end)
                        Log.transcription.notice(
                            "qwen3 rescue chunk=\(String(format: "%.1f-%.1f", chunk.start, chunk.end)) lang=\(language) anchors=\(rescueAnchors.count) anchored=\(rescued.anchoredCount) vs \(aligned.anchoredCount)")
                        if rescued.anchoredCount > aligned.anchoredCount {
                            aligned = rescued
                        }
                    } catch {
                        Log.transcription.warning(
                            "qwen3 rescue failed chunk=\(String(format: "%.1f-%.1f", chunk.start, chunk.end)): \(error.localizedDescription)")
                    }
                }
            }

            words.append(contentsOf: aligned.words)
            segments.append(TranscriptionSegment(
                text: chunk.text,
                start: aligned.words.first?.start ?? chunk.start,
                end: aligned.words.last?.end ?? chunk.end
            ))
        }

        // Guard against a partial decode (dropped or empty trailing chunks) being cached as
        // complete — on direct evidence, not tuned thresholds. Whisper heard the same audio
        // independently and decodes speech only: a run of its words AFTER qwen3's last segment is
        // proof of dropped speech (immune to music tails, which have no words). The energy check
        // applies only when Whisper produced nothing to compare against.
        let lastEnd = segments.map(\.end).max() ?? 0
        if !timingWords.isEmpty {
            let missedSpeech = timingWords.filter { ($0.start ?? 0) > lastEnd + 2.0 }
            if missedSpeech.count >= 5, let missedEnd = missedSpeech.compactMap(\.end).max() {
                throw EngineError.incompleteResult(covered: lastEnd, expected: missedEnd)
            }
        } else if let gap = EngineAudio.coverageShortfall(segments: segments, samples: samples) {
            throw EngineError.incompleteResult(covered: gap.covered, expected: gap.expected)
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
            let cjkScalars = word.text.unicodeScalars.filter {
                let value = Int($0.value)
                return (0x2E80...0x9FFF).contains(value) && !(0x3000...0x303F).contains(value)
            }
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
    /// CJK characters normalize to toneless pinyin so homophone disagreements between
    /// Qwen3 and Whisper (的/得, 那/哪) still anchor.
    private static func matchKey(_ piece: String) -> String {
        let filtered = String(piece.lowercased().unicodeScalars.filter {
            let value = Int($0.value)
            if (0x3000...0x303F).contains(value) { return false }  // CJK punctuation (。、「」…)
            return CharacterSet.alphanumerics.contains($0) || (0x2E80...0x9FFF).contains(value)
        })
        let isCJK = filtered.unicodeScalars.contains { (0x2E80...0x9FFF).contains(Int($0.value)) }
        guard isCJK else { return filtered }
        let latin = filtered.applyingTransform(.toLatin, reverse: false) ?? filtered
        return (latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }

    /// A chunk qualifies for a forced-language Whisper rescue when its CJK pieces
    /// specifically are poorly anchored (English anchors in a mixed chunk don't help
    /// a translated-away Mandarin run). Returns the Whisper language code by script.
    private static func rescueLanguage(
        pieces: [String], alignment: (words: [TranscriptionWord], anchoredCount: Int, anchoredPieces: Set<Int>)
    ) -> String? {
        var han = 0, kana = 0, hangul = 0
        var cjkPieceIndices: [Int] = []
        for (index, piece) in pieces.enumerated() {
            var isCJKPiece = false
            for scalar in piece.unicodeScalars {
                switch Int(scalar.value) {
                case 0x4E00...0x9FFF, 0xF900...0xFAFF: han += 1; isCJKPiece = true
                case 0x3040...0x30FF: kana += 1; isCJKPiece = true
                case 0xAC00...0xD7AF: hangul += 1; isCJKPiece = true
                default: break
                }
            }
            if isCJKPiece { cjkPieceIndices.append(index) }
        }
        guard cjkPieceIndices.count >= 5 else { return nil }
        let anchoredCJK = cjkPieceIndices.filter { alignment.anchoredPieces.contains($0) }.count
        let coverage = Double(anchoredCJK) / Double(cjkPieceIndices.count)
        guard coverage < 0.5 else { return nil }
        if kana > han { return "ja" }
        if hangul > han { return "ko" }
        return "zh"
    }

    /// Pin Qwen3 pieces to Whisper's real timestamps where the transcripts agree
    /// (longest-common-subsequence on normalized text), interpolating between anchors.
    /// Punctuation-only pieces get zero duration (a real aligner cannot time silence).
    private static func alignWords(
        pieces: [String], anchors: [TranscriptionWord], chunkStart: Double, chunkEnd: Double
    ) -> (words: [TranscriptionWord], anchoredCount: Int, anchoredPieces: Set<Int>) {
        guard !pieces.isEmpty else { return ([], 0, []) }
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
                result.append(TranscriptionWord(
                    text: pieces[index], start: clampedStart, end: max(end, clampedStart), aligned: true))
                lastEnd = max(end, clampedStart)
                index += 1
                continue
            }
            // Unanchored run: interpolate between the previous anchor end and the next anchor
            // start. Punctuation (empty match key) is silent — zero duration, zero weight.
            var runEnd = index
            while runEnd < pieces.count && starts[runEnd] == nil { runEnd += 1 }
            let windowEnd = runEnd < pieces.count ? (starts[runEnd] ?? chunkEnd) : chunkEnd
            let window = max(0.1, windowEnd - lastEnd)
            let runWeights = (index..<runEnd).map { i in
                pieceKeys[i].isEmpty ? 0.0 : Double(max(1, pieces[i].count))
            }
            let totalWeight = max(runWeights.reduce(0, +), 0.001)
            var cursor = lastEnd
            for (offset, weight) in runWeights.enumerated() {
                let duration = window * weight / totalWeight
                // aligned: false = fabricated timing; callers must not cut on these.
                result.append(TranscriptionWord(
                    text: pieces[index + offset], start: cursor, end: cursor + duration,
                    aligned: pieceKeys[index + offset].isEmpty ? nil : false))
                cursor += duration
            }
            lastEnd = cursor
            index = runEnd
        }
        return (result, matched.count, Set(matched.map(\.piece)))
    }
}
