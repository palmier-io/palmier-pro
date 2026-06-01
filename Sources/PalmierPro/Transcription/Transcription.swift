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

struct TranscriptionResult: Sendable {
    let text: String
    let language: String?
    let languageProbability: Double?
    let words: [TranscriptionWord]
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
    static func transcribeVideoAudio(videoURL: URL) async throws -> TranscriptionResult {
        let tempAudioURL = try await extractAudioTrack(from: videoURL)
        defer { try? FileManager.default.removeItem(at: tempAudioURL) }
        return try await transcribe(fileURL: tempAudioURL)
    }

    static func bestSupportedLocale(from supported: [Locale]) -> Locale? {
        let candidates = Locale.preferredLanguages.map(Locale.init(identifier:)) + [Locale.current]
        return matchLocale(candidates: candidates, supported: supported)
    }

    /// Match by language code — `Locale.current` carries region overrides (`en_US@rg=frzzzz`)
    /// that `supportedLocales` never has. Prefer exact region, else any region for that language.
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

    static func transcribe(fileURL: URL) async throws -> TranscriptionResult {
        let supported = await SpeechTranscriber.supportedLocales
        guard let locale = bestSupportedLocale(from: supported) else {
            throw TranscriptionError.unsupportedLocale(Locale.current.identifier(.bcp47))
        }
        Log.transcription.notice("transcribe locale=\(locale.identifier(.bcp47))")

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
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

    private static func extractAudioTrack(from videoURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError.audioExtractionFailed(
                "Could not create export session for \(videoURL.lastPathComponent)"
            )
        }
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("palmier-stt-\(UUID().uuidString).m4a")
        Log.transcription.notice("extract start video=\(videoURL.lastPathComponent)")
        do {
            try await export.export(to: outURL, as: .m4a)
        } catch {
            throw TranscriptionError.audioExtractionFailed(error.localizedDescription)
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
        Log.transcription.notice("extract ok bytes=\(bytes) out=\(outURL.lastPathComponent)")
        return outURL
    }

    /// Walks each result's AttributedString runs and emits one
    /// TranscriptionWord per non-whitespace token.
    private static func decodeResults(
        _ results: [SpeechTranscriber.Result],
        locale: Locale,
    ) -> TranscriptionResult {
        var words: [TranscriptionWord] = []
        var fullText = ""

        for result in results {
            let attributed = result.text
            fullText += String(attributed.characters)

            for run in attributed.runs {
                let runText = String(attributed[run.range].characters)
                let trimmed = runText.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                let range = run.audioTimeRange
                let start = range.map(\.start.seconds)
                let end = range.map { ($0.start + $0.duration).seconds }
                words.append(
                    TranscriptionWord(
                        text: trimmed,
                        start: start,
                        end: end,
                        type: "word",
                        speakerId: nil,
                    ),
                )
            }
        }

        return TranscriptionResult(
            text: fullText.trimmingCharacters(in: .whitespacesAndNewlines),
            language: locale.identifier(.bcp47),
            languageProbability: nil,
            words: words,
        )
    }
}
