import AVFoundation
import Foundation

enum CloudTranscription {
    static func transcribe(
        fileURL: URL,
        range: ClosedRange<Double>?,
        preferredLocale: Locale?,
        projectId: String?
    ) async throws -> TranscriptionResult {
        let language = languageIdentifier(preferredLocale)
        if let cached = await TranscriptCache.shared.cachedCloudTranscript(
            for: fileURL,
            range: range,
            language: language
        ) {
            return cached
        }

        let tempAudioURL = try await Transcription.extractAudioTrack(
            from: fileURL,
            range: range,
            fileExtension: "wav"
        )
        defer { try? FileManager.default.removeItem(at: tempAudioURL) }

        let durationSeconds = try await transcriptionDuration(for: tempAudioURL, sourceRange: range)
        let storageId = try await BackendStorage.uploadStaged(fileURL: tempAudioURL, contentType: "audio/wav")
        let submitted = try await TranscriptionBackend.submit(
            storageId: storageId,
            durationSeconds: durationSeconds,
            language: language,
            projectId: projectId
        )
        let result = try await TranscriptionBackend.waitForResult(jobId: submitted.jobId)
            .offsetting(by: range?.lowerBound ?? 0)
        await TranscriptCache.shared.storeCloudTranscript(
            result,
            for: fileURL,
            range: range,
            language: language
        )
        return result
    }

    static func languageIdentifier(_ preferredLocale: Locale?) -> String? {
        preferredLocale.flatMap { locale in
            locale.language.languageCode?.identifier ?? locale.identifier(.bcp47)
        }
    }

    private static func transcriptionDuration(
        for audioURL: URL,
        sourceRange: ClosedRange<Double>?
    ) async throws -> Double {
        if let sourceRange {
            return max(0.01, sourceRange.upperBound - sourceRange.lowerBound)
        }
        let asset = AVURLAsset(url: audioURL)
        let duration = try await asset.load(.duration).seconds
        return max(0.01, duration.isFinite ? duration : 0.01)
    }
}
