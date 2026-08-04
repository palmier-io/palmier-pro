import CoreGraphics
import Testing
@testable import PalmierPro

@Suite struct ClipRendererPerformanceTests {
    @Test func volumeKeyframesUseTheSameVisibilityRulesAsRendering() {
        let narrowRect = CGRect(
            x: 0,
            y: 0,
            width: AppTheme.ComponentSize.timelineClipControlsMinWidth - AppTheme.BorderWidth.hairline,
            height: 64
        )
        let controlsRect = CGRect(
            x: 0,
            y: 0,
            width: AppTheme.ComponentSize.timelineClipControlsMinWidth,
            height: 64
        )

        #expect(!ClipRenderer.showsFadeControls(isSelected: true, isHovered: true, in: narrowRect))
        #expect(!ClipRenderer.showsVolumeKeyframes(isSelected: true, isHovered: true, in: narrowRect))
        #expect(ClipRenderer.showsFadeControls(isSelected: false, isHovered: true, in: controlsRect))
        #expect(!ClipRenderer.showsVolumeKeyframes(isSelected: false, isHovered: true, in: controlsRect))
        #expect(ClipRenderer.showsVolumeKeyframes(isSelected: true, isHovered: false, in: controlsRect))
    }

    @Test @MainActor func narrowClipsUseTheirWholeWidthForMoveDragging() {
        let narrowWidth = AppTheme.ComponentSize.timelineClipControlsMinWidth - AppTheme.BorderWidth.hairline
        let controlsWidth = AppTheme.ComponentSize.timelineClipControlsMinWidth

        #expect(TimelineInputController.trimEdge(localX: 0, clipWidth: narrowWidth) == nil)
        #expect(TimelineInputController.trimEdge(localX: narrowWidth, clipWidth: narrowWidth) == nil)
        #expect(TimelineInputController.trimEdge(localX: 0, clipWidth: controlsWidth) == .left)
        #expect(TimelineInputController.trimEdge(localX: controlsWidth, clipWidth: controlsWidth) == .right)
        #expect(TimelineInputController.trimEdge(localX: controlsWidth / 2, clipWidth: controlsWidth) == nil)
    }

    @Test func compactSelectedClipsRenderWithinInteractionBudget() throws {
        let context = try #require(CGContext(
            data: nil,
            width: 1_000,
            height: 64,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let clip = Fixtures.clip(
            id: "caption",
            mediaRef: "caption-media",
            mediaType: .text,
            start: 0,
            duration: 30
        )

        let duration = ContinuousClock().measure {
            for index in 0..<50_000 {
                ClipRenderer.draw(
                    clip,
                    type: .text,
                    in: CGRect(x: CGFloat(index % 1_000), y: 0, width: 0.5, height: 64),
                    isSelected: true,
                    context: context,
                    displayName: "Caption",
                    fps: 30
                )
            }
        }

        #expect(duration < .seconds(2))
    }

    @Test func compactClipsDoNotResolveSilenceRanges() throws {
        let context = try #require(CGContext(
            data: nil,
            width: 1,
            height: 64,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let clip = Fixtures.clip(mediaRef: "audio", mediaType: .audio, start: 0, duration: 30)
        var didResolve = false
        func ranges() -> [Range<Double>] {
            didResolve = true
            return []
        }

        ClipRenderer.draw(
            clip,
            type: .audio,
            in: CGRect(x: 0, y: 0, width: 0.5, height: 64),
            isSelected: false,
            context: context,
            deadAirRanges: ranges(),
            fps: 30
        )

        #expect(!didResolve)
    }
}
