import Foundation
import Testing
@testable import PalmierPro

@Suite("Transcription cancellation")
struct TranscriptionCancellationTests {
    private enum SampleError: Error {
        case failed
    }

    @Test func cancelledTaskDoesNotConvertFailure() async {
        let task = Task<TranscriptionError, Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            return try Transcription.failurePreservingCancellation(
                SampleError.failed,
                as: TranscriptionError.analysisFailed
            )
        }

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test func frameworkCancellationRemainsFailureWhileTaskIsActive() throws {
        let failure = try Transcription.failurePreservingCancellation(
            CancellationError(),
            as: TranscriptionError.analysisFailed
        )

        guard case .analysisFailed = failure else {
            Issue.record("Expected an analysis failure")
            return
        }
    }

    @Test func cacheRejectsCancelledRequestBeforeStartingTranscription() async {
        let task = Task<TranscriptionResult, Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await TranscriptCache.shared.transcript(
                for: URL(fileURLWithPath: "/missing/transcription-source.wav"),
                isVideo: false,
                range: nil
            )
        }

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}
