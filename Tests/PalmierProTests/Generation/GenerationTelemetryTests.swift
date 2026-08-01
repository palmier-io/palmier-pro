import Foundation
import Testing
@testable import PalmierPro

@Suite("Generation telemetry")
struct GenerationTelemetryTests {
    private func genInput(upscale: UpscaleSettings? = nil) -> GenerationInput {
        GenerationInput(
            prompt: "a wide shot of a harbor at dawn",
            model: "seedance-2.0",
            duration: 5,
            aspectRatio: "16:9",
            resolution: nil,
            upscaleSettings: upscale
        )
    }

    @Test(arguments: [ClipType.video, .image, .audio])
    func generationTypeMatchesAssetType(assetType: ClipType) {
        let type = GenerationService.generationType(assetType: assetType, genInput: genInput())

        #expect(type == assetType.rawValue)
    }

    @Test func upscaleIsReportedSeparatelyFromItsAssetType() {
        let input = genInput(upscale: UpscaleSettings())

        #expect(GenerationService.generationType(assetType: .video, genInput: input) == "upscale")
        #expect(GenerationService.generationType(assetType: .image, genInput: input) == "upscale")
    }

    @Test func submissionOutsideAToolRunIsAttributedToTheUser() {
        let properties = Analytics.originProperties()

        #expect(properties["source"] as? String == Analytics.manualSource)
        #expect(properties["session_id"] == nil)
    }

    @Test func submissionInsideAToolRunCarriesItsSourceAndSession() {
        let origin = Analytics.Origin(source: "mcp", sessionID: "session-1")

        let properties = Analytics.$origin.withValue(origin) { Analytics.originProperties() }

        #expect(properties["source"] as? String == "mcp")
        #expect(properties["session_id"] as? String == "session-1")
    }
}
