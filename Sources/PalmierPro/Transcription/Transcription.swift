import AVFoundation
import Foundation
import Speech

enum TranscriptionProvider: String, CaseIterable, Sendable, Codable {
    case local
    case cloud

    var label: String {
        switch self {
        case .local: "Local"
        case .cloud: "Cloud"
        }
    }
}

struct TranscriptionWord: Sendable, Codable {
    let text: String
    let start: Double?
    let end: Double?
    let speaker: String?

    init(text: String, start: Double?, end: Double?, speaker: String? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

struct TranscriptionSegment: Sendable, Codable {
    let text: String
    let start: Double
    let end: Double
    let speaker: String?

    init(text: String, start: Double, end: Double, speaker: String? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

struct TranscriptionResult: Sendable, Codable {
    let text: String
    let language: String?
    let words: [TranscriptionWord]
    let segments: [TranscriptionSegment]

    /// Shifts all timestamps back into source time after transcribing an extracted range
    func offsetting(by offset: Double) -> TranscriptionResult {
        guard offset != 0 else { return self }
        return TranscriptionResult(
            text: text,
            language: language,
            words: words.map {
                TranscriptionWord(
                    text: $0.text,
                    start: $0.start.map { $0 + offset },
                    end: $0.end.map { $0 + offset },
                    speaker: $0.speaker
                )
            },
            segments: segments.map {
                TranscriptionSegment(text: $0.text, start: $0.start + offset, end: $0.end + offset, speaker: $0.speaker)
            }
        )
    }
}

enum TranscriptionError: LocalizedError {
    case unsupportedLocale(String)
    case modelInstallFailed(String)
    case decodeFailed
    case audioExtractionFailed(String)
    case analysisFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let id):
            return "On-device transcription is not available for \(id)."
        case .modelInstallFailed(let reason):
            return "Could not install the on-device speech model: \(reason)"
        case .decodeFailed:
            return "Could not parse transcription result."
        case .audioExtractionFailed(let reason):
            return "Audio extraction failed: \(reason)"
        case .analysisFailed(let reason):
            return "Transcription failed: \(reason)"
        }
    }
}

enum Transcription {
    private static let audioExtractionGate = AsyncSemaphore(value: 2)

    static func transcribeVideoAudio(videoURL: URL, censorProfanity: Bool = false, preferredLocale: Locale? = nil, sourceRange: ClosedRange<Double>? = nil) async throws -> TranscriptionResult {
        let tempAudioURL = try await extractAudioTrack(from: videoURL, range: sourceRange)
        defer { try? FileManager.default.removeItem(at: tempAudioURL) }
        let result = try await transcribe(fileURL: tempAudioURL, censorProfanity: censorProfanity, preferredLocale: preferredLocale)
        return result.offsetting(by: sourceRange?.lowerBound ?? 0)
    }

    static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    static func bestSupportedLocale(from supported: [Locale]) -> Locale? {
        let candidates = Locale.preferredLanguages.map(Locale.init(identifier:)) + [Locale.current]
        return matchLocale(candidates: candidates, supported: supported)
    }

    static func matchLocale(candidates: [Locale], supported: [Locale]) -> Locale? {
        for candidate in candidates {
            guard let lang = candidate.language.languageCode?.identifier else { continue }
            let sameLang = supported.filter { $0.language.languageCode?.identifier == lang }
            guard !sameLang.isEmpty else { continue }
            let region = candidate.region?.identifier
            return sameLang.first { $0.region?.identifier == region } ?? sameLang.first
        }
        return nil
    }

    static func transcribe(fileURL: URL, censorProfanity: Bool = false, preferredLocale: Locale? = nil, sourceRange: ClosedRange<Double>? = nil) async throws -> TranscriptionResult {
        if let sourceRange {
            let tempURL = try await extractAudioTrack(from: fileURL, range: sourceRange)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            let result = try await transcribe(fileURL: tempURL, censorProfanity: censorProfanity, preferredLocale: preferredLocale)
            return result.offsetting(by: sourceRange.lowerBound)
        }

        let supported = await SpeechTranscriber.supportedLocales
        let locale: Locale
        if let preferredLocale, let match = matchLocale(candidates: [preferredLocale], supported: supported) {
            locale = match
        } else if let auto = bestSupportedLocale(from: supported) {
            locale = auto
        } else {
            throw TranscriptionError.unsupportedLocale((preferredLocale ?? Locale.current).identifier(.bcp47))
        }
        Log.transcription.notice(
            "transcribe locale=\(locale.identifier(.bcp47))",
            telemetry: "Transcription started",
            data: [
                "locale": locale.identifier(.bcp47),
                "censorProfanity": censorProfanity,
                "hasPreferredLocale": preferredLocale != nil
            ]
        )

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: censorProfanity ? [.etiquetteReplacements] : [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange],
        )

        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            Log.transcription.notice(
                "install model start locale=\(locale.identifier)",
                telemetry: "Transcription model install started",
                data: ["locale": locale.identifier(.bcp47)]
            )
            do {
                try await install.downloadAndInstall()
            } catch {
                Log.transcription.warning(
                    "install model failed locale=\(locale.identifier) error=\(error.localizedDescription)",
                    telemetry: "Transcription model install failed",
                    data: ["locale": locale.identifier(.bcp47), "error": error.localizedDescription]
                )
                throw TranscriptionError.modelInstallFailed(error.localizedDescription)
            }
            Log.transcription.notice(
                "install model ok locale=\(locale.identifier)",
                telemetry: "Transcription model install finished",
                data: ["locale": locale.identifier(.bcp47)]
            )
        }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: fileURL)
        } catch {
            throw TranscriptionError.audioExtractionFailed(error.localizedDescription)
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let resultsTask = Task { () throws -> [SpeechTranscriber.Result] in
            var acc: [SpeechTranscriber.Result] = []
            for try await result in transcriber.results { acc.append(result) }
            return acc
        }

        Log.transcription.notice("analyze start file=\(fileURL.lastPathComponent)", telemetry: "Transcription analysis started")
        do {
            if let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            resultsTask.cancel()
            Log.transcription.warning(
                "analyze failed error=\(error.localizedDescription)",
                telemetry: "Transcription analysis failed",
                data: ["error": error.localizedDescription]
            )
            throw TranscriptionError.analysisFailed(error.localizedDescription)
        }

        let collected: [SpeechTranscriber.Result]
        do {
            collected = try await resultsTask.value
        } catch {
            throw TranscriptionError.analysisFailed(error.localizedDescription)
        }

        let decoded = decodeResults(collected, locale: locale)
        Log.transcription.notice(
            "ok textChars=\(decoded.text.count) words=\(decoded.words.count) lang=\(decoded.language ?? "?")",
            telemetry: "Transcription finished",
            data: [
                "textChars": decoded.text.count,
                "words": decoded.words.count,
                "segments": decoded.segments.count,
                "language": decoded.language ?? "unknown"
            ]
        )
        return decoded
    }

    /// Decode the asset's audio track to a PCM file with AVAssetReader
    static func extractAudioTrack(
        from videoURL: URL,
        range: ClosedRange<Double>? = nil,
        fileExtension: String = "caf"
    ) async throws -> URL {
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("palmier-stt-\(UUID().uuidString).\(fileExtension)")
        try await audioExtractionGate.wait()
        defer { Task { await audioExtractionGate.signal() } }

        Log.transcription.notice(
            "extract start video=\(videoURL.lastPathComponent)",
            telemetry: "Transcription audio extraction started",
            data: ["hasRange": range != nil, "rangeSeconds": range.map { $0.upperBound - $0.lowerBound } ?? 0]
        )

        var audioFile: AVAudioFile?
        do {
            try await AudioTrackReader.read(from: videoURL, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ], range: range) { pcm in
                if audioFile == nil {
                    audioFile = try AVAudioFile(
                        forWriting: outURL,
                        settings: pcm.format.settings,
                        commonFormat: pcm.format.commonFormat,
                        interleaved: pcm.format.isInterleaved
                    )
                }
                try audioFile?.write(from: pcm)
            }
        } catch let error as AudioTrackReader.ReadError {
            throw TranscriptionError.audioExtractionFailed(error.message)
        }

        guard audioFile != nil else {
            throw TranscriptionError.audioExtractionFailed("No audio samples in \(videoURL.lastPathComponent)")
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
        Log.transcription.notice(
            "extract ok bytes=\(bytes) out=\(outURL.lastPathComponent)",
            telemetry: "Transcription audio extraction finished",
            data: ["bytes": bytes, "hasRange": range != nil]
        )
        return outURL
    }

    /// Each `Result` is one endpointed segment; emit it as a TranscriptionSegment
    /// (text + time range) and walk its runs into per-token TranscriptionWords.
    private static func decodeResults(
        _ results: [SpeechTranscriber.Result],
        locale: Locale,
    ) -> TranscriptionResult {
        var words: [TranscriptionWord] = []
        var segments: [TranscriptionSegment] = []
        var fullText = ""

        for result in results {
            let attributed = result.text
            fullText += String(attributed.characters)

            let segmentText = String(attributed.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if !segmentText.isEmpty {
                segments.append(TranscriptionSegment(
                    text: segmentText,
                    start: result.range.start.seconds,
                    end: result.range.end.seconds,
                    speaker: nil
                ))
            }

            for run in attributed.runs {
                let runText = String(attributed[run.range].characters)
                let trimmed = runText.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                let range = run.audioTimeRange
                let start = range.map(\.start.seconds)
                let end = range.map { ($0.start + $0.duration).seconds }
                words.append(TranscriptionWord(text: trimmed, start: start, end: end, speaker: nil))
            }
        }

        return TranscriptionResult(
            text: fullText.trimmingCharacters(in: .whitespacesAndNewlines),
            language: locale.identifier(.bcp47),
            words: words,
            segments: segments,
        )
    }
}
