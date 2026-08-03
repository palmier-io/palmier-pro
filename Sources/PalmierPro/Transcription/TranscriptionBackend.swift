@preconcurrency import Combine
import Foundation
#if HOSTED_BACKEND && arch(arm64)
@preconcurrency import ConvexMobile
typealias TranscriptionClientError = ClientError
#else
enum TranscriptionClientError: Error {
    case unavailable
}
#endif

enum TranscriptionBackend {
    @MainActor
    static func submit(
        storageId: String,
        durationSeconds: Double,
        language: String?,
        projectId: String?
    ) async throws -> BackendTranscriptionSubmit {
        #if HOSTED_BACKEND && arch(arm64)
        guard let convex = AccountService.shared.convex else {
            throw BackendError.notConfigured
        }
        let args: [String: ConvexEncodable?] = [
            "storageId": storageId,
            "durationSeconds": durationSeconds,
            "model": "cloud",
            "languageMode": language == nil ? "auto" : "specific",
            "language": language,
            "projectId": projectId,
        ]
        return try await convex.action("transcriptions:submit", with: args)
        #else
        throw BackendError.notConfigured
        #endif
    }

    @MainActor
    static func subscribe(jobId: String) -> AnyPublisher<BackendTranscriptionJob?, TranscriptionClientError>? {
        #if HOSTED_BACKEND && arch(arm64)
        guard let convex = AccountService.shared.convex else { return nil }
        return convex.subscribe(
            to: "transcriptions:byId",
            with: ["id": jobId],
            yielding: BackendTranscriptionJob?.self
        )
        #else
        return nil
        #endif
    }

    static func result(jobId: String) async throws -> TranscriptionResult {
        let response = try await resultRef(jobId: jobId)
        guard let url = URL(string: response.resultUrl) else {
            throw TranscriptionBackendError.failed("Invalid transcription result URL")
        }
        let (data, urlResponse) = try await URLSession.shared.data(from: url)
        guard let http = urlResponse as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TranscriptionBackendError.failed("Could not download transcription result")
        }
        return try JSONDecoder().decode(TranscriptionResult.self, from: data)
    }

    @MainActor
    private static func resultRef(jobId: String) async throws -> BackendTranscriptionResultRef {
        #if HOSTED_BACKEND && arch(arm64)
        guard let convex = AccountService.shared.convex else {
            throw BackendError.notConfigured
        }
        return try await convex.action(
            "transcriptions:result",
            with: ["id": jobId]
        )
        #else
        throw BackendError.notConfigured
        #endif
    }

    @MainActor
    static func waitForResult(jobId: String) async throws -> TranscriptionResult {
        guard let publisher = subscribe(jobId: jobId) else {
            throw BackendError.notConfigured
        }
        for await job in jobStream(from: publisher) {
            guard let job else { continue }
            switch job.status {
            case .succeeded:
                return try await result(jobId: jobId)
            case .failed:
                throw TranscriptionBackendError.failed(job.errorMessage ?? "Transcription failed")
            case .queued, .running:
                continue
            }
        }
        throw TranscriptionBackendError.failed("Transcription status stream ended")
    }

    private static func jobStream<Failure: Error>(
        from publisher: AnyPublisher<BackendTranscriptionJob?, Failure>
    ) -> AsyncStream<BackendTranscriptionJob?> {
        AsyncStream<BackendTranscriptionJob?> { continuation in
            let cancellable = publisher
                .receive(on: DispatchQueue.main)
                .sink(
                    receiveCompletion: { _ in continuation.finish() },
                    receiveValue: { continuation.yield($0) }
                )
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }
}

enum BackendTranscriptionStatus: String, Decodable, Sendable {
    case queued, running, succeeded, failed
}

struct BackendTranscriptionSubmit: Decodable, Sendable {
    let jobId: String
}

struct BackendTranscriptionJob: Decodable, Sendable {
    let id: String
    let status: BackendTranscriptionStatus
    let errorMessage: String?
}

private struct BackendTranscriptionResultRef: Decodable, Sendable {
    let resultUrl: String
}

enum TranscriptionBackendError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        }
    }
}
