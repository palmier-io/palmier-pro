import AVFoundation
import Testing
@testable import PalmierPro

@Suite("Preview playback rate")
@MainActor
struct PreviewPlaybackRateTests {
    @Test func presetsMatchReviewSpeeds() {
        #expect(PreviewPlaybackRate.allCases.map(\.rawValue) == [0.5, 0.75, 1, 1.5, 2, 4, 10])
        #expect(PreviewPlaybackRate.allCases.map(\.label) == [
            "0.5×",
            "0.75×",
            "1×",
            "1.5×",
            "2×",
            "4×",
            "10×",
        ])
    }

    @Test(arguments: PreviewPlaybackRate.allCases)
    func observerCadenceStaysAtThirtyUpdatesPerSecond(rate: PreviewPlaybackRate) {
        let interval = VideoEngine.playheadObserverInterval(for: rate)
        let updatesPerSecond = Double(rate.rawValue) / interval.seconds
        #expect(abs(updatesPerSecond - 30) < 0.0001)
    }

    @Test func frameAlignedDurationPreservesItsExactFrameCount() {
        let duration = CMTime(value: 123, timescale: 30)

        #expect(VideoEngine.frameCount(for: duration, fps: 30) == 123)
    }

    @Test func audioMeteringStopsAboveDoubleSpeed() {
        #expect(PreviewPlaybackRate.allCases.filter(\.allowsAudioMetering) == [
            .half,
            .threeQuarters,
            .normal,
            .oneAndHalf,
            .double,
        ])
    }

    @Test func selectionUpdatesThePlayerDefaultRate() {
        let editor = EditorViewModel()
        let engine = VideoEngine(editor: editor)
        editor.videoEngine = engine
        defer {
            engine.teardown()
            editor.videoEngine = nil
        }

        editor.setPlaybackRate(.quadruple)

        #expect(editor.playbackRate == .quadruple)
        #expect(engine.player.defaultRate == 4)
        #expect(engine.player.rate == 0)
    }

    @Test func visualRefreshNeverSeeksDuringPlayback() {
        #expect(VideoEngine.visualRefreshAction(isPlaying: true, playbackRate: .normal) == .meterPlayback)
        #expect(VideoEngine.visualRefreshAction(isPlaying: true, playbackRate: .quadruple) == .none)
        #expect(VideoEngine.visualRefreshAction(isPlaying: false, playbackRate: .quadruple) == .seekToActiveFrame)
    }

    @Test func rateChangeDoesNotStartDeferredPlayback() {
        let editor = EditorViewModel()
        let engine = VideoEngine(editor: editor)
        editor.videoEngine = engine
        defer {
            engine.teardown()
            editor.videoEngine = nil
        }
        engine.player.replaceCurrentItem(with: AVPlayerItem(asset: AVMutableComposition()))
        editor.isPlaying = true

        editor.setPlaybackRate(.quadruple)

        #expect(engine.player.defaultRate == 4)
        #expect(engine.player.rate == 0)
    }

    @Test func rateChangeUpdatesActivePlayback() {
        let editor = EditorViewModel()
        let engine = VideoEngine(editor: editor)
        editor.videoEngine = engine
        defer {
            engine.pause()
            engine.teardown()
            editor.videoEngine = nil
        }
        engine.player.replaceCurrentItem(with: AVPlayerItem(asset: AVMutableComposition()))
        editor.isPlaying = true
        engine.player.play()

        editor.setPlaybackRate(.quadruple)

        #expect(engine.player.rate == 4)
    }

    @Test func currentItemEndStopsPlayback() {
        let editor = EditorViewModel()
        let engine = VideoEngine(editor: editor)
        editor.videoEngine = engine
        defer {
            engine.teardown()
            editor.videoEngine = nil
        }
        let item = AVPlayerItem(asset: AVMutableComposition())
        engine.player.replaceCurrentItem(with: item)
        editor.isPlaying = true
        editor.currentFrame = 1

        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: item)

        #expect(!editor.isPlaying)
        #expect(editor.currentFrame == editor.activePreviewDurationFrames)
    }

    @Test func anotherPlayerItemEndingDoesNotStopPlayback() {
        let editor = EditorViewModel()
        let engine = VideoEngine(editor: editor)
        editor.videoEngine = engine
        defer {
            engine.teardown()
            editor.videoEngine = nil
        }
        let currentItem = AVPlayerItem(asset: AVMutableComposition())
        engine.player.replaceCurrentItem(with: currentItem)
        editor.isPlaying = true

        let otherItem = AVPlayerItem(asset: AVMutableComposition())
        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: otherItem)

        #expect(editor.isPlaying)
    }

    @Test func fastPlaybackRateResetsTheAudioMeter() {
        let editor = EditorViewModel()
        let engine = VideoEngine(editor: editor)
        editor.videoEngine = engine
        defer {
            engine.teardown()
            editor.videoEngine = nil
        }
        editor.audioMeter.ingest(AudioMeterAnalysis(leftPeak: 1, rightPeak: 0.5), at: 100)

        editor.setPlaybackRate(.quadruple)

        let display = editor.audioMeter.display(at: 100)
        #expect(display.left.levelDb == AudioMeterChannelState.floorDb)
        #expect(display.right.levelDb == AudioMeterChannelState.floorDb)
    }
}
