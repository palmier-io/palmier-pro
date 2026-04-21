import AVFoundation
import Foundation
@preconcurrency import FalClient

extension GenerationService {
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
        case noApiKey
        case decodeFailed
        case audioExtractionFailed(String)

        var errorDescription: String? {
            switch self {
            case .noApiKey: return "No FAL API key configured."
            case .decodeFailed: return "Could not parse transcription response."
            case .audioExtractionFailed(let reason): return "Audio extraction failed: \(reason)"
            }
        }
    }

    func transcribeVideoAudio(videoURL: URL) async throws -> TranscriptionResult {
        guard hasApiKey else { throw TranscriptionError.noApiKey }
        let tempAudioURL = try await Self.extractAudioTrack(from: videoURL)
        defer { try? FileManager.default.removeItem(at: tempAudioURL) }
        return try await transcribe(fileURL: tempAudioURL)
    }

    private static func extractAudioTrack(from videoURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError.audioExtractionFailed("Could not create export session for \(videoURL.lastPathComponent)")
        }
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("palmier-stt-\(UUID().uuidString).m4a")
        Log.generation.notice("transcribe extract start video=\(videoURL.lastPathComponent)")
        do {
            try await export.export(to: outURL, as: .m4a)
        } catch {
            throw TranscriptionError.audioExtractionFailed(error.localizedDescription)
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
        Log.generation.notice("transcribe extract ok bytes=\(bytes) out=\(outURL.lastPathComponent)")
        return outURL
    }

    func transcribe(fileURL: URL) async throws -> TranscriptionResult {
        guard hasApiKey else { throw TranscriptionError.noApiKey }
        let key = apiKey
        let endpoint = "fal-ai/elevenlabs/speech-to-text/scribe-v2"
        let fileName = fileURL.lastPathComponent

        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch {
            Log.generation.error("transcribe read failed file=\(fileName) error=\(error.localizedDescription)")
            throw error
        }
        Log.generation.notice("transcribe upload start file=\(fileName) bytes=\(data.count)")

        let client = FalClient.withCredentials(.keyPair(key))
        let uploaded: String
        do {
            uploaded = try await client.storage.upload(data: data, ofType: .inferred(from: fileURL))
        } catch {
            Log.generation.error("transcribe upload failed file=\(fileName) error=\(error.localizedDescription)")
            throw error
        }
        Log.generation.notice("transcribe upload ok url=\(uploaded)")

        let input: Payload = ["audio_url": .string(uploaded)]
        Log.generation.notice("transcribe subscribe start endpoint=\(endpoint)")

        let result: Payload
        do {
            result = try await client.subscribe(
                to: endpoint,
                input: input,
                pollInterval: .seconds(2),
                timeout: .seconds(Self.subscribeTimeoutSeconds),
                includeLogs: true,
                onQueueUpdate: { @Sendable status in
                    switch status {
                    case .inQueue(let position, _):
                        Log.generation.notice("fal queue endpoint=\(endpoint) position=\(position)")
                    case .inProgress(let logs):
                        for line in logs { Log.generation.notice("fal[\(line.level.rawValue)] \(line.message)") }
                    case .completed(let logs, _):
                        for line in logs { Log.generation.notice("fal[\(line.level.rawValue)] \(line.message)") }
                        Log.generation.notice("fal queue endpoint=\(endpoint) completed")
                    }
                }
            )
        } catch {
            Log.generation.error("transcribe subscribe failed endpoint=\(endpoint) error=\(error.localizedDescription)")
            throw error
        }

        let decoded = try Self.decodeElevenLabsSTT(result)
        Log.generation.notice("transcribe ok textChars=\(decoded.text.count) words=\(decoded.words.count) lang=\(decoded.language ?? "?")")
        return decoded
    }

    private static func decodeElevenLabsSTT(_ payload: Payload) throws -> TranscriptionResult {
        let jsonData: Data
        do { jsonData = try payload.json() }
        catch {
            Log.generation.error("transcribe payload re-encode failed: \(error)")
            throw TranscriptionError.decodeFailed
        }
        let raw: ElevenLabsSTTRaw
        do { raw = try JSONDecoder().decode(ElevenLabsSTTRaw.self, from: jsonData) }
        catch {
            Log.generation.error("transcribe decode failed: \(error)")
            throw TranscriptionError.decodeFailed
        }
        let words: [TranscriptionWord] = raw.words
            .filter { $0.type != "spacing" }
            .map { w in
                TranscriptionWord(
                    text: w.text, start: w.start, end: w.end,
                    type: w.type, speakerId: w.speakerId
                )
            }
        return TranscriptionResult(
            text: raw.text,
            language: raw.languageCode,
            languageProbability: raw.languageProbability,
            words: words
        )
    }

    private struct ElevenLabsSTTRaw: Decodable {
        let text: String
        let languageCode: String?
        let languageProbability: Double?
        let words: [Word]
        struct Word: Decodable {
            let text: String
            let start: Double?
            let end: Double?
            let type: String
            let speakerId: String?
            enum CodingKeys: String, CodingKey {
                case text, start, end, type
                case speakerId = "speaker_id"
            }
        }
        enum CodingKeys: String, CodingKey {
            case text, words
            case languageCode = "language_code"
            case languageProbability = "language_probability"
        }
    }
}
