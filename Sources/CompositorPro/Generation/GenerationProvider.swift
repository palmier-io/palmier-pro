import Combine
import Foundation

protocol GenerationProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var supportedModalities: Set<String> { get }

    func submit(
        model: String,
        params: BackendGenerationParams,
        projectId: String?
    ) async throws -> String

    func status(jobId: String) async throws -> BackendGenerationJob?
    func cancel(jobId: String) async throws
    func uploadReference(fileURL: URL, contentType: String) async throws -> String
}

extension GenerationProvider {
    func submit(
        model: String,
        params: BackendGenerationParams
    ) async throws -> String {
        try await submit(model: model, params: params, projectId: nil)
    }
}

/// In-memory local generation provider with reference tracking, budget enforcement,
/// cancellation, and duplicate submission protection.
actor LocalGenerationProvider: GenerationProvider {
    let id: String
    let displayName: String
    let supportedModalities: Set<String>

    private var jobs: [String: BackendGenerationJob] = [:]
    private var references: [String: URL] = [:]
    private var submissionFingerprints: [String: String] = [:]
    private var authorizedBudget: Int

    init(
        id: String = "local-provider",
        displayName: String = "Local Generation Provider",
        supportedModalities: Set<String> = ["image", "video", "audio"],
        authorizedBudget: Int = 1_000
    ) {
        self.id = id
        self.displayName = displayName
        self.supportedModalities = supportedModalities
        self.authorizedBudget = authorizedBudget
    }

    func submit(
        model: String,
        params: BackendGenerationParams,
        projectId: String?
    ) async throws -> String {
        let cost = 10
        guard authorizedBudget >= cost else {
            throw GenerationError("Budget exceeded: requested \(cost) credits, remaining \(authorizedBudget)")
        }

        // Duplicate submission protection via parameter encoding
        let fingerprint = "\(model)|\(params.hashValue)"
        if let existingId = submissionFingerprints[fingerprint],
           let existingJob = jobs[existingId],
           existingJob.status != .failed {
            return existingId
        }

        let jobId = "gen-\(UUID().uuidString.prefix(8))"
        submissionFingerprints[fingerprint] = jobId
        authorizedBudget -= cost

        let job = BackendGenerationJob(
            _id: jobId,
            status: .succeeded,
            resultUrls: ["file:///tmp/\(jobId).mp4"],
            errorMessage: nil,
            costCredits: cost,
            refundedCredits: nil,
            completedAt: Date().timeIntervalSince1970 * 1000
        )
        jobs[jobId] = job
        return jobId
    }

    func status(jobId: String) async throws -> BackendGenerationJob? {
        jobs[jobId]
    }

    func cancel(jobId: String) async throws {
        guard let existing = jobs[jobId] else { return }
        if existing.status != .failed {
            jobs[jobId] = BackendGenerationJob(
                _id: jobId,
                status: .failed,
                resultUrls: nil,
                errorMessage: "Cancelled by user",
                costCredits: 0,
                refundedCredits: existing.costCredits,
                completedAt: Date().timeIntervalSince1970 * 1000
            )
            if let cost = existing.costCredits {
                authorizedBudget += cost
            }
        }
    }

    func uploadReference(fileURL: URL, contentType: String) async throws -> String {
        let refId = "ref-\(UUID().uuidString.prefix(8))"
        references[refId] = fileURL
        return refId
    }
}

private struct GenerationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension BackendGenerationParams: Hashable {
    func hash(into hasher: inout Hasher) {
        switch self {
        case .video(let v):
            hasher.combine(v.prompt)
            hasher.combine(v.duration)
            hasher.combine(v.aspectRatio)
        case .image(let i):
            hasher.combine(i.prompt)
            hasher.combine(i.aspectRatio)
        case .audio(let a):
            hasher.combine(a.prompt)
            hasher.combine(a.durationSeconds)
        case .upscale(let u):
            hasher.combine(u.sourceURL)
            hasher.combine(u.durationSeconds)
        }
    }

    static func == (lhs: BackendGenerationParams, rhs: BackendGenerationParams) -> Bool {
        lhs.hashValue == rhs.hashValue
    }
}
