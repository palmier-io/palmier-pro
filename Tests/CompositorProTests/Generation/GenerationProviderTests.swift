import Foundation
import Testing
@testable import CompositorPro

@Suite("Generation provider & synthesis", .serialized)
@MainActor
struct GenerationProviderTests {
    @Test func submitJobThroughProviderCompletesWithResult() async throws {
        let provider = LocalGenerationProvider(authorizedBudget: 100)
        GenerationBackend.provider = provider
        defer { GenerationBackend.provider = nil }

        let params = BackendGenerationParams.video(.init(prompt: "Harbor at sunset", duration: 5, aspectRatio: "16:9", resolution: "1080p"))
        let jobId = try await GenerationBackend.submit(model: "gen-video-v1", params: params)
        #expect(!jobId.isEmpty)

        let status = try await provider.status(jobId: jobId)
        #expect(status?.status == .succeeded)
        #expect(status?.costCredits == 10)
        #expect(status?.resultUrls?.isEmpty == false)
    }

    @Test func duplicateSubmissionDeduplicatesWithoutDoubleCharge() async throws {
        let provider = LocalGenerationProvider(authorizedBudget: 100)
        GenerationBackend.provider = provider
        defer { GenerationBackend.provider = nil }

        let params = BackendGenerationParams.video(.init(prompt: "Same prompt", duration: 4, aspectRatio: "16:9", resolution: "1080p"))
        let id1 = try await GenerationBackend.submit(model: "gen-video-v1", params: params)
        let id2 = try await GenerationBackend.submit(model: "gen-video-v1", params: params)
        #expect(id1 == id2)
    }

    @Test func referenceUploadGeneratesRefId() async throws {
        let provider = LocalGenerationProvider(authorizedBudget: 100)
        GenerationBackend.provider = provider
        defer { GenerationBackend.provider = nil }

        let tempURL = URL(fileURLWithPath: "/tmp/test-ref.png")
        let refId = try await GenerationBackend.uploadReference(fileURL: tempURL, contentType: "image/png")
        #expect(refId.hasPrefix("ref-"))
    }

    @Test func budgetExhaustionFailsFast() async throws {
        let provider = LocalGenerationProvider(authorizedBudget: 5)
        GenerationBackend.provider = provider
        defer { GenerationBackend.provider = nil }

        let params = BackendGenerationParams.image(.init(prompt: "Expensive image", aspectRatio: "16:9", resolution: "1080p", quality: "standard", imageURLs: [], numImages: 1))
        await #expect(throws: Error.self) {
            try await GenerationBackend.submit(model: "gen-image-v1", params: params)
        }
    }

    @Test func cancellationRefundsBudget() async throws {
        let provider = LocalGenerationProvider(authorizedBudget: 50)
        let params = BackendGenerationParams.video(.init(prompt: "Will cancel", duration: 5, aspectRatio: "16:9", resolution: "1080p"))
        let jobId = try await provider.submit(model: "v1", params: params)
        try await provider.cancel(jobId: jobId)

        let status = try await provider.status(jobId: jobId)
        #expect(status?.status == BackendGenerationStatus.failed)
        #expect(status?.errorMessage == "Cancelled by user")
    }
}
