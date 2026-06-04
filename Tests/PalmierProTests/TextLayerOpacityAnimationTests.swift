import AVFoundation
import QuartzCore
import Testing
@testable import PalmierPro

@Suite("TextLayerController — opacity animation")
@MainActor
struct TextLayerOpacityAnimationTests {

    private func animation(for clip: Clip, fps: Int = 30) -> (anim: CAKeyframeAnimation?, layer: CATextLayer?) {
        let track = Fixtures.videoTrack(clips: [clip])
        let timeline = Fixtures.timeline(fps: fps, tracks: [track])
        let (parent, videoLayer) = TextLayerController.buildForExport(
            timeline: timeline, fps: fps, renderSize: CGSize(width: 1920, height: 1080)
        )
        _ = videoLayer
        let textLayer = parent.sublayers?.dropFirst().first as? CATextLayer
        let anim = textLayer?.animation(forKey: "opacity") as? CAKeyframeAnimation
        return (anim, textLayer)
    }

    private func textClip(start: Int, duration: Int, fadeIn: Int = 0, fadeOut: Int = 0) -> Clip {
        var c = Fixtures.clip(mediaRef: "text-1", mediaType: .text, start: start, duration: duration)
        c.textContent = "hi"
        c.fadeInFrames = fadeIn
        c.fadeOutFrames = fadeOut
        return c
    }

    @Test func layerStartsInvisible() {
        let (_, layer) = animation(for: textClip(start: 30, duration: 60, fadeIn: 10))
        #expect(layer?.opacity == 0)
    }

    @Test func usesDiscreteCalculationMode() {
        // Discrete per-frame keyframes are immune to implicit timing-function bias from AVFoundation.
        let (anim, _) = animation(for: textClip(start: 30, duration: 60, fadeIn: 10))
        #expect(anim?.calculationMode == .discrete)
    }

    @Test func emitsOneValuePerExportFrame() {
        // Timeline is 90 frames (30 frames before clip + 60-frame clip) at 30fps → 90 values, 91 keyTimes.
        let (anim, _) = animation(for: textClip(start: 30, duration: 60, fadeIn: 10))
        #expect(anim?.values?.count == 90)
        #expect(anim?.keyTimes?.count == 91)
    }

    @Test func fadeInRampsLinearlyPerFrame() {
        // Clip at [30, 90) with fadeIn=10. Frame 30 → 0, frame 31 → 0.1, ..., frame 40 → 1.0.
        let (anim, _) = animation(for: textClip(start: 30, duration: 60, fadeIn: 10))
        let values = (anim?.values as? [NSNumber]) ?? []
        // values[i] is opacity during frame i.
        #expect(values[29].floatValue == 0)          // last frame before clip
        #expect(values[30].floatValue == 0)          // frame 0 of clip, fade just begun
        #expect(abs(values[31].floatValue - 0.1) < 1e-6)
        #expect(abs(values[35].floatValue - 0.5) < 1e-6)
        #expect(values[40].floatValue == 1.0)         // fade-in complete
        #expect(values[89].floatValue == 1.0)         // last frame of clip
    }

    @Test func fadeOutRampsLinearlyPerFrame() {
        // Clip at [30, 90) with fadeOut=10. Frame 80 → 1.0, frame 85 → 0.5, frame 89 → 0.1.
        let (anim, _) = animation(for: textClip(start: 30, duration: 60, fadeOut: 10))
        let values = (anim?.values as? [NSNumber]) ?? []
        #expect(values[79].floatValue == 1.0)
        #expect(values[80].floatValue == 1.0)
        #expect(abs(values[85].floatValue - 0.5) < 1e-6)
        #expect(abs(values[89].floatValue - 0.1) < 1e-6)
    }

    @Test func noFadeStaysAtFullOpacityWithinClip() {
        let (anim, _) = animation(for: textClip(start: 30, duration: 60))
        let values = (anim?.values as? [NSNumber]) ?? []
        for f in 30..<90 {
            #expect(values[f].floatValue == 1.0, "frame \(f)")
        }
        #expect(values[29].floatValue == 0)
        // Timeline is exactly the clip length here so no post-clip frames.
    }

    @Test func appliesBorderStyleToTextLayer() {
        var clip = textClip(start: 0, duration: 30)
        var style = TextStyle()
        style.border.enabled = true
        clip.textStyle = style
        let (_, layer) = animation(for: clip)
        #expect(layer?.borderColor != nil)
        #expect(layer?.borderWidth == AppTheme.BorderWidth.thin)
    }
}
