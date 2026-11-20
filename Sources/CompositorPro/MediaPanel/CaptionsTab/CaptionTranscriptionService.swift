import Foundation

struct CaptionTranscriptionService: Sendable {
    struct Input: Sendable {
        let url: URL
        let isVideo: Bool
        let range: ClosedRange<Double>?
        let censorProfanity: Bool
        let locale: Locale?
        let provider: TranscriptionProvider
        let projectId: String?
    }

    static let live = CaptionTranscriptionService(load: load)
    let load: @Sendable (Input) async throws -> TranscriptionResult

    private static func load(_ input: Input) async throws -> TranscriptionResult {
        switch input.provider {
        case .local:
            if input.censorProfanity || input.locale != nil {
                return input.isVideo
                    ? try await Transcription.transcribeVideoAudio(videoURL: input.url, censorProfanity: input.censorProfanity, preferredLocale: input.locale, sourceRange: input.range)
                    : try await Transcription.transcribe(fileURL: input.url, censorProfanity: input.censorProfanity, preferredLocale: input.locale, sourceRange: input.range)
            }
            return try await TranscriptCache.shared.transcript(for: input.url, isVideo: input.isVideo, range: input.range)
        case .cloud:
            return try await CloudTranscription.transcribe(
                fileURL: input.url, range: input.range, preferredLocale: input.locale, projectId: input.projectId
            )
        }
    }
}
