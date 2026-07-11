import Foundation
import Combine
@preconcurrency import ConvexMobile

/// The RPC layer for the backend
@MainActor
enum GenerationBackend {
    static func subscribe(
        jobId: String
    ) -> AnyPublisher<BackendGenerationJob?, ClientError>? {
        guard let convex = AccountService.shared.convex else { return nil }
        return convex.subscribe(
            to: "generations:byId",
            with: ["id": jobId],
            yielding: BackendGenerationJob?.self,
        )
    }

    static func uploadReference(
        fileURL: URL,
        contentType: String,
    ) async throws -> String {
        guard let convex = AccountService.shared.convex else {
            throw GenerationBackendError.notConfigured
        }
        let storageId = try await BackendStorage.uploadStaged(fileURL: fileURL, contentType: contentType)
        let result: UrlResponse = try await convex.action(
            "uploads:commitUpload",
            with: ["storageId": storageId],
        )
        return result.url
    }

    static func submit(
        model: String,
        params: BackendGenerationParams,
        projectId: String? = nil,
    ) async throws -> String {
        guard let convex = AccountService.shared.convex else {
            throw GenerationBackendError.notConfigured
        }
        let args: [String: ConvexEncodable?] = [
            "model": model,
            "params": params,
            "projectId": projectId,
        ]
        let result: SubmitGenerationResult = try await convex.mutation(
            "generations:submit",
            with: args,
        )
        return result.jobId
    }
}

// MARK: - Backend generation types

enum BackendGenerationParams: Encodable, ConvexEncodable, Sendable {
    case video(VideoGenerationParams)
    case image(ImageGenerationParams)
    case audio(AudioGenerationParams)
    case upscale(UpscaleGenerationParams)

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .video(let p): try c.encode(p)
        case .image(let p): try c.encode(p)
        case .audio(let p): try c.encode(p)
        case .upscale(let p): try c.encode(p)
        }
    }
}

enum BackendGenerationStatus: String, Decodable, Sendable {
    case queued, running, succeeded, failed
}

struct BackendGenerationJob: Decodable, Sendable {
    let _id: String
    let status: BackendGenerationStatus
    let resultUrls: [String]?
    let errorMessage: String?
    let costCredits: Int?
    let completedAt: Double?
}

enum GenerationBackendError: LocalizedError {
    case notConfigured
    case transport(String)
    case api(status: Int, code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Palmier backend not configured."
        case .transport(let s): return s
        case .api(_, _, let message): return message
        }
    }
}

private struct UrlResponse: Decodable, Sendable {
    let url: String
}

private struct SubmitGenerationResult: Decodable, Sendable {
    let jobId: String
}
