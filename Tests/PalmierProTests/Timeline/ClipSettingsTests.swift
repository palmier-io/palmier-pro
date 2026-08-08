import Foundation
import Testing
@testable import PalmierPro

@Suite("Clip settings transfer")
@MainActor
struct ClipSettingsTests {
    @Test func textSettingsPreserveContentTimingAndAnimationTracks() throws {
        var source = Fixtures.clip(id: "source", mediaRef: "", mediaType: .text, start: 0, duration: 60)
        source.textContent = "Title"
        source.textStyle = TextStyle(fontName: "Avenir", fontSize: 48, isBold: true)
        source.textAnimation = TextAnimation(preset: .wordPop)
        source.textFillMode = .footage
        source.opacity = 0.65
        source.transform.centerX = 0.2
        source.transform.centerY = 0.8
        source.transform.rotation = -8
        source.effects = [.make("stylize.invert")]

        var target = Fixtures.clip(id: "target", mediaRef: "", mediaType: .text, start: 90, duration: 120)
        target.textContent = "A much longer target title"
        target.wordTimings = [WordTiming(text: "A", startFrame: 0, endFrame: 10)]
        target.captionGroupId = "captions"
        target.opacityTrack = KeyframeTrack(keyframes: [Keyframe(frame: 20, value: 0.5)])
        let original = target

        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [source, target])])
        editor.selectedClipIds = [source.id]
        editor.copySelectedClipsToClipboard()
        let snapshot = try #require(editor.copiedClipSettings(for: .text))
        _ = try editor.applyClipSettings(snapshot, to: [target.id])
        let updated = try #require(editor.clipFor(id: target.id))

        #expect(updated.textContent == original.textContent)
        #expect(updated.wordTimings == original.wordTimings)
        #expect(updated.captionGroupId == original.captionGroupId)
        #expect(updated.durationFrames == original.durationFrames)
        #expect(updated.opacityTrack == original.opacityTrack)
        #expect(updated.textStyle == source.textStyle)
        #expect(updated.textAnimation == source.textAnimation)
        #expect(updated.textFillMode == source.textFillMode)
        #expect(updated.opacity == source.opacity)
        #expect(updated.effects == source.effects)
        #expect(updated.transform.centerX == source.transform.centerX)
        #expect(updated.transform.centerY == source.transform.centerY)
        #expect(updated.transform.rotation == source.transform.rotation)
        #expect(updated.transform.width < source.transform.width)
    }

    @Test func audioSettingsCopyVolumeAndEffectsOnly() throws {
        var source = Fixtures.clip(id: "source", mediaType: .audio, start: 0, duration: 60, volume: 0.35)
        source.effects = [.make(Clip.denoiseEffectType, ["amount": 0.75])]
        var target = Fixtures.clip(id: "target", mediaType: .audio, start: 70, duration: 30, volume: 1)
        target.fadeOutFrames = 8
        target.volumeTrack = KeyframeTrack(keyframes: [Keyframe(frame: 5, value: -6)])
        let original = target

        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [source, target])])
        let snapshot = try editor.clipSettingsSnapshot(for: source.id)
        _ = try editor.applyClipSettings(snapshot, to: [target.id])
        let updated = try #require(editor.clipFor(id: target.id))

        #expect(updated.volume == source.volume)
        #expect(updated.effects == source.effects)
        #expect(updated.fadeOutFrames == original.fadeOutFrames)
        #expect(updated.volumeTrack == original.volumeTrack)
        #expect(updated.startFrame == original.startFrame)
        #expect(updated.durationFrames == original.durationFrames)
    }
}
