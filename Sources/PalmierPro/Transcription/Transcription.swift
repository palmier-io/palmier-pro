import AVFoundation
import Foundation
import Speech

struct TranscriptionWord: Sendable, Codable {
    let text: String
    let start: Double?
    let end: Double?
}

/// One natural utterance the transcriber endpointed on its own (pause/sentence
/// boundary). `text` carries the model's punctuation and casing.
struct TranscriptionSegment: Sendable, Codable {
    let text: String
    let start: Double
    let end: Double
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
                TranscriptionWord(text: $0.text, start: $0.start.map { $0 + offset }, end: $0.end.map { $0 + offset })
            },
            segments: segments.map {
                TranscriptionSegment(text: $0.text, start: $0.start + offset, end: $0.end + offset)
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
    private static func extractAudioTrack(from videoURL: URL, range: ClosedRange<Double>? = nil) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw TranscriptionError.audioExtractionFailed("No audio track in \(videoURL.lastPathComponent)")
        }

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch {
            throw TranscriptionError.audioExtractionFailed(error.localizedDescription)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else {
            throw TranscriptionError.audioExtractionFailed("Cannot read audio from \(videoURL.lastPathComponent)")
        }
        reader.add(output)
        if let range {
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                end: CMTime(seconds: range.upperBound, preferredTimescale: 600)
            )
        }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("palmier-stt-\(UUID().uuidString).caf")
        Log.transcription.notice(
            "extract start video=\(videoURL.lastPathComponent)",
            telemetry: "Transcription audio extraction started",
            data: ["hasRange": range != nil, "rangeSeconds": range.map { $0.upperBound - $0.lowerBound } ?? 0]
        )

        guard reader.startReading() else {
            throw TranscriptionError.audioExtractionFailed(reader.error?.localizedDescription ?? "Reader could not start")
        }

        var audioFile: AVAudioFile?
        while let sample = output.copyNextSampleBuffer() {
            guard let desc = CMSampleBufferGetFormatDescription(sample),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
                  let format = AVAudioFormat(streamDescription: asbd) else { continue }
            let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
            guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { continue }
            pcm.frameLength = frames
            CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sample, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList
            )
            if audioFile == nil {
                audioFile = try AVAudioFile(
                    forWriting: outURL,
                    settings: format.settings,
                    commonFormat: format.commonFormat,
                    interleaved: format.isInterleaved
                )
            }
            try audioFile?.write(from: pcm)
        }

        if reader.status == .failed {
            throw TranscriptionError.audioExtractionFailed(reader.error?.localizedDescription ?? "Read failed")
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
                    end: result.range.end.seconds
                ))
            }

            for run in attributed.runs {
                let runText = String(attributed[run.range].characters)
                let trimmed = runText.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                let range = run.audioTimeRange
                let start = range.map(\.start.seconds)
                let end = range.map { ($0.start + $0.duration).seconds }
                words.append(TranscriptionWord(text: trimmed, start: start, end: end))
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
