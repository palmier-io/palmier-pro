import AVFoundation
import Foundation

/// Hosted cloud transcription was removed in the backend teardown (R1). The
/// cached hosted transcripts still validate as cached reads through the
/// local path; fresh cloud work throws before any upload or submit.
enum CloudTranscription {
    static func transcribe(
        fileURL: URL,
        range: ClosedRange<Double>?,
        preferredLocale: Locale?,
        projectId: String?
    ) async throws -> TranscriptionResult {
        try HostedServices.cloudTranscriptionAvailability.requireAvailable()
        // Unreachable: hosted services are excluded by design (R1).
        fatalError("Hosted cloud transcription is unavailable")
    }

    static func languageIdentifier(_ preferredLocale: Locale?) -> String? {
        preferredLocale.flatMap { locale in
            locale.language.languageCode?.identifier ?? locale.identifier(.bcp47)
        }
    }
}
