import Combine
import Foundation

enum BackendUnavailableError: LocalizedError {
    case hostedServicesRemoved

    var errorDescription: String? {
        "Hosted generation is not available in this build."
    }
}

/// The account-backed generation backend was removed in the backend teardown
/// (R1). Submissions fail fast; types remain for retained job bookkeeping.
enum GenerationBackend {
    static func submit(
        model: String,
        params: BackendGenerationParams,
        projectId: String? = nil
    ) async throws -> String {
        throw BackendUnavailableError.hostedServicesRemoved
    }

    static func enhanceDraft(sourceJobId: String) async throws -> String {
        throw BackendUnavailableError.hostedServicesRemoved
    }

    static func subscribe(jobId: String) -> AnyPublisher<BackendGenerationJob?, Never>? {
        nil
    }

    static func subscribeToProjectActivity(
        projectId: String
    ) -> AnyPublisher<[BackendProjectActivityEntry], Never>? {
        nil
    }

    static func uploadReference(
        fileURL: URL,
        contentType: String
    ) async throws -> String {
        throw BackendUnavailableError.hostedServicesRemoved
    }
}

// MARK: - Backend generation types (local, no Convex encoding)

enum BackendGenerationParams: Encodable, Sendable {
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
    let refundedCredits: Int?
    let completedAt: Double?
}

struct BackendProjectActivityEntry: Decodable, Sendable, Identifiable {
    enum Kind: String, Decodable, Sendable {
        case generation
        case failed
        case refund
    }

    let id: String
    let kind: Kind
    let model: String
    let credits: Int
    let createdAt: Double

    var creditImpact: Int {
        kind == .refund ? -credits : credits
    }

    var createdDate: Date {
        Date(timeIntervalSince1970: createdAt / 1_000)
    }
}
