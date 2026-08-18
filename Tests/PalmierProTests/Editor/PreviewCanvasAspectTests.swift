import CoreGraphics
import Testing
@testable import PalmierPro

@Suite("Preview canvas aspect")
struct PreviewCanvasAspectTests {
    @Test func timelineUsesProjectDimensions() {
        let aspect = PreviewCanvasAspect.ratio(width: 1920, height: 1080)
        #expect(abs(aspect - 16.0 / 9.0) < 0.0001)
    }

    @Test func sourcePreviewUsesNativeMediaAspect() {
        let aspect = PreviewCanvasAspect.sourcePreviewRatio(
            sourceWidth: 1080,
            sourceHeight: 1920,
            generationAspectRatio: "16:9",
            timelineWidth: 1920,
            timelineHeight: 1080
        )
        #expect(abs(aspect - 9.0 / 16.0) < 0.0001)
    }

    @Test func sourcePreviewUsesImageNativeAspect() {
        let aspect = PreviewCanvasAspect.sourcePreviewRatio(
            sourceWidth: 2000,
            sourceHeight: 1500,
            generationAspectRatio: nil,
            timelineWidth: 1920,
            timelineHeight: 1080
        )
        #expect(abs(aspect - 4.0 / 3.0) < 0.0001)
    }

    @Test func sourcePreviewFallsBackToGenerationAspectWhenDimensionsUnknown() {
        let aspect = PreviewCanvasAspect.sourcePreviewRatio(
            sourceWidth: nil,
            sourceHeight: nil,
            generationAspectRatio: "9:16",
            timelineWidth: 1920,
            timelineHeight: 1080
        )
        #expect(abs(aspect - 9.0 / 16.0) < 0.0001)
    }

    @Test func sourcePreviewFallsBackToTimelineWhenAspectUnknown() {
        let aspect = PreviewCanvasAspect.sourcePreviewRatio(
            sourceWidth: nil,
            sourceHeight: 1080,
            generationAspectRatio: "invalid",
            timelineWidth: 1920,
            timelineHeight: 1080
        )
        #expect(abs(aspect - 16.0 / 9.0) < 0.0001)
    }

    @Test func zeroSourceDimensionsFallBackToGenerationThenTimeline() {
        let generation = PreviewCanvasAspect.sourcePreviewRatio(
            sourceWidth: 0,
            sourceHeight: 0,
            generationAspectRatio: "1:1",
            timelineWidth: 1920,
            timelineHeight: 1080
        )
        #expect(abs(generation - 1) < 0.0001)

        let timeline = PreviewCanvasAspect.sourcePreviewRatio(
            sourceWidth: 0,
            sourceHeight: 0,
            generationAspectRatio: nil,
            timelineWidth: 1080,
            timelineHeight: 1920
        )
        #expect(abs(timeline - 9.0 / 16.0) < 0.0001)
    }
}
