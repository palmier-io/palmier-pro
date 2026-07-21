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
