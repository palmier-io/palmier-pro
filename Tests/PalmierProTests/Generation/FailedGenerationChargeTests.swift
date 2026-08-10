import Foundation
import Testing
@testable import PalmierPro

@Suite("Failed generation charge")
@MainActor
struct FailedGenerationChargeTests {
    private func generated(creditsCharged: Bool?) -> MediaAsset {
        var input = GenerationInput(
            prompt: "a harbor at dawn",
            model: "seedance-2.0",
            duration: 5,
            aspectRatio: "16:9",
            resolution: nil
        )
        input.creditsCharged = creditsCharged
        return MediaAsset(
            url: URL(fileURLWithPath: "/tmp/gen.mp4"),
            type: .video,
            name: "Harbor",
            generationInput: input
        )
    }

    @Test func refundedFailureReportsNoCharge() {
        let asset = generated(creditsCharged: false)
        asset.generationStatus = .failed("Provider rejected the prompt")

        #expect(asset.failedWithoutCharge)
    }

    @Test func failureAfterAChargedJobReportsNothing() {
        let asset = generated(creditsCharged: true)
        asset.generationStatus = .failed("Download failed")

        #expect(!asset.failedWithoutCharge)
    }

    @Test func failureWithAnUnknownChargeReportsNothing() {
        let asset = generated(creditsCharged: nil)
        asset.generationStatus = .failed("Backend not configured")

        #expect(!asset.failedWithoutCharge)
    }

    @Test func inProgressGenerationReportsNothing() {
        let asset = generated(creditsCharged: false)
        asset.generationStatus = .generating

        #expect(!asset.failedWithoutCharge)
    }

    @Test func importFailureWithoutGenerationInputReportsNothing() {
        let asset = MediaAsset(url: URL(fileURLWithPath: "/tmp/import.mp4"), type: .video, name: "Import")
        asset.generationStatus = .failed("Could not read media file.")

        #expect(!asset.failedWithoutCharge)
    }

    @Test func refundedFailureSurvivesManifestRoundTrip() throws {
        let asset = generated(creditsCharged: false)
        asset.generationStatus = .failed("Provider rejected the prompt")

        let data = try JSONEncoder().encode(asset.toManifestEntry(projectURL: nil))
        let restored = try JSONDecoder().decode(MediaManifestEntry.self, from: data)

        #expect(MediaAsset(entry: restored, resolvedURL: asset.url).failedWithoutCharge)
    }
}
