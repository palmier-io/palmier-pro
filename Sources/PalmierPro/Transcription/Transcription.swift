import AVFoundation
import Foundation
import Speech

struct TranscriptionWord: Sendable {
    let text: String
    let start: Double?
    let end: Double?
    let type: String
    let speakerId: String?
}

/// One natural utterance the transcriber endpointed on its own (pause/sentence
/// boundary). `text` carries the model's punctuation and casing.
struct TranscriptionSegment: Sendable {
    let text: String
    let start: Double
    let end: Double
}

struct TranscriptionResult: Sendable {
    let text: String
    let language: String?
    let languageProbability: Double?
    let words: [TranscriptionWord]
    let segments: [TranscriptionSegment]
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
    static func transcribeVideoAudio(videoURL: URL, censorProfanity: Bool = false, preferredLocale: Locale? = nil) async throws -> TranscriptionResult {
        let tempAudioURL = try await extractAudioTrack(from: videoURL)
        defer { try? FileManager.default.removeItem(at: tempAudioURL) }
        return try await transcribe(fileURL: tempAudioURL, censorProfanity: censorProfanity, preferredLocale: preferredLocale)
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

    static func transcribe(fileURL: URL, censorProfanity: Bool = false, preferredLocale: Locale? = nil) async throws -> TranscriptionResult {
        let supported = await SpeechTranscriber.supportedLocales
        let locale: Locale
        if let preferredLocale, let match = matchLocale(candidates: [preferredLocale], supported: supported) {
            locale = match
        } else if let auto = bestSupportedLocale(from: supported) {
            locale = auto
        } else {
            throw TranscriptionError.unsupportedLocale((preferredLocale ?? Locale.current).identifier(.bcp47))
        }
        Log.transcription.notice("transcribe locale=\(locale.identifier(.bcp47))")

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: censorProfanity ? [.etiquetteReplacements] : [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange],
        )

        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            Log.transcription.notice("install model start locale=\(locale.identifier)")
            do {
                try await install.downloadAndInstall()
            } catch {
                throw TranscriptionError.modelInstallFailed(error.localizedDescription)
            }
            Log.transcription.notice("install model ok locale=\(locale.identifier)")
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

        Log.transcription.notice("analyze start file=\(fileURL.lastPathComponent)")
        do {
            if let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            resultsTask.cancel()
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
            "ok textChars=\(decoded.text.count) words=\(decoded.words.count) lang=\(decoded.language ?? "?")"
        )
        return decoded
    }

    /// Decode the asset's audio track to a PCM file with AVAssetReader
    private static func extractAudioTrack(from videoURL: URL) async throws -> URL {
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
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else {
            throw TranscriptionError.audioExtractionFailed("Cannot read audio from \(videoURL.lastPathComponent)")
        }
        reader.add(output)

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("palmier-stt-\(UUID().uuidString).caf")
        Log.transcription.notice("extract start video=\(videoURL.lastPathComponent)")

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
        Log.transcription.notice("extract ok bytes=\(bytes) out=\(outURL.lastPathComponent)")
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
                words.append(
                    TranscriptionWord(text: trimmed, start: start, end: end, type: "word", speakerId: nil)
                )
            }
        }

        return TranscriptionResult(
            text: fullText.trimmingCharacters(in: .whitespacesAndNewlines),
            language: locale.identifier(.bcp47),
            languageProbability: nil,
            words: words,
            segments: segments,
        )
    }
}
