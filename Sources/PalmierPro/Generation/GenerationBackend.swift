import Foundation
import Combine
@preconcurrency import ConvexMobile

/// The RPC layer for the backend
@MainActor
enum GenerationBackend {
    /// Reactive subscription to a single generation job pushed by Convex.
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

    /// Uploads a file to backend in three steps:
    static func uploadReference(
        fileURL: URL,
        contentType: String,
    ) async throws -> String {
        guard let convex = AccountService.shared.convex else {
            throw GenerationBackendError.notConfigured
        }

        // 1. Mint a Convex storage ticket
        let ticket: StagingTicket = try await convex.mutation("uploads:generateUploadTicket")
        guard let stagingURL = URL(string: ticket.uploadUrl) else {
            throw GenerationBackendError.transport("Invalid staging URL")
        }

        // 2. POST the bytes to the upload URL
        var stagingReq = URLRequest(url: stagingURL)
        stagingReq.httpMethod = "POST"
        stagingReq.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (stagingRespData, stagingResp) = try await URLSession.shared.upload(
            for: stagingReq,
            fromFile: fileURL,
        )
        try assertHTTPOK(respData: stagingRespData, response: stagingResp)
        let storageId = try JSONDecoder()
            .decode(StagingUploadResponse.self, from: stagingRespData)
            .storageId

        // 3. Commit the upload
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

    private static func assertHTTPOK(respData: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw GenerationBackendError.transport("Non-HTTP response")
        }
        if (200..<300).contains(http.statusCode) { return }
        let detail = String(data: respData, encoding: .utf8) ?? ""
        if let parsed = try? JSONDecoder().decode(BackendErrorEnvelope.self, from: respData) {
            throw GenerationBackendError.api(
                status: http.statusCode,
                code: parsed.error.code,
                message: parsed.error.message,
            )
        }
        throw GenerationBackendError.transport("HTTP \(http.statusCode): \(detail)")
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

private struct StagingTicket: Decodable, Sendable {
    let uploadUrl: String
}

private struct StagingUploadResponse: Decodable, Sendable {
    let storageId: String
}

private struct UrlResponse: Decodable, Sendable {
    let url: String
}

private struct SubmitGenerationResult: Decodable, Sendable {
    let jobId: String
}

private struct BackendErrorEnvelope: Decodable, Sendable {
    struct Inner: Decodable, Sendable {
        let code: String
        let message: String
    }
    let error: Inner
}
