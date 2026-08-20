@preconcurrency import Combine
import Foundation
@preconcurrency import ConvexMobile

enum MaskTrackingBackend {
    @MainActor
    static func submit(
        videoStorageId: String,
        frameCount: Int,
        seed: BackendMaskSeed,
        projectId: String?
    ) async throws -> BackendMaskSubmit {
        guard let convex = AccountService.shared.convex else {
            throw BackendError.notConfigured
        }
        let args: [String: ConvexEncodable?] = [
            "videoStorageId": videoStorageId,
            "frameCount": Double(frameCount),
            "seed": seed,
            "projectId": projectId,
        ]
        return try await convex.action("masks:submit", with: args)
    }

    @MainActor
    static func subscribe(jobId: String) -> AnyPublisher<BackendMaskJob?, ClientError>? {
        guard let convex = AccountService.shared.convex else { return nil }
        return convex.subscribe(
            to: "masks:byId",
            with: ["id": jobId],
            yielding: BackendMaskJob?.self
        )
    }

    @MainActor
    static func waitForCompletion(jobId: String) async throws {
        guard let publisher = subscribe(jobId: jobId) else {
            throw BackendError.notConfigured
        }
        for await job in jobStream(from: publisher) {
            guard let job else { continue }
            switch job.status {
            case .succeeded:
                return
            case .failed:
                throw MaskTrackingBackendError.failed(job.errorMessage ?? "Mask tracking failed")
            case .queued, .running:
                continue
            }
        }
        throw MaskTrackingBackendError.failed("Mask job status stream ended")
    }

    static func resultPayload(jobId: String) async throws -> Data {
        let response = try await resultRef(jobId: jobId)
        guard let url = URL(string: response.resultUrl) else {
            throw MaskTrackingBackendError.failed("Invalid mask result URL")
        }
        let (data, urlResponse) = try await URLSession.shared.data(from: url)
        guard let http = urlResponse as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MaskTrackingBackendError.failed("Could not download mask result")
        }
        return data
    }

    @MainActor
    private static func resultRef(jobId: String) async throws -> BackendMaskResultRef {
        guard let convex = AccountService.shared.convex else {
            throw BackendError.notConfigured
        }
        return try await convex.action("masks:result", with: ["id": jobId])
    }

    private static func jobStream<Failure: Error>(
        from publisher: AnyPublisher<BackendMaskJob?, Failure>
    ) -> AsyncStream<BackendMaskJob?> {
        AsyncStream<BackendMaskJob?> { continuation in
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

struct BackendMaskSeed: Encodable, ConvexEncodable, Sendable {
    let type = "text"
    let prompt: String
}

enum BackendMaskStatus: String, Decodable, Sendable {
    case queued, running, succeeded, failed
}

struct BackendMaskSubmit: Decodable, Sendable {
    let jobId: String
}

struct BackendMaskJob: Decodable, Sendable {
    let status: BackendMaskStatus
    let errorMessage: String?
}

private struct BackendMaskResultRef: Decodable, Sendable {
    let resultUrl: String
}

enum MaskTrackingBackendError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        }
    }
}
