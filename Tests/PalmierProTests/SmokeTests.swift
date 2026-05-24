import Testing
@testable import PalmierPro

@Suite("Smoke")
struct SmokeTests {
    @Test func fixturesProduceConsistentTimeline() {
        let clip = Fixtures.clip(start: 0, duration: 30)
        let track = Fixtures.videoTrack(clips: [clip])
        let timeline = Fixtures.timeline(tracks: [track])

        #expect(timeline.fps == 30)
        #expect(timeline.tracks.count == 1)
        #expect(timeline.tracks[0].clips.count == 1)
        #expect(timeline.totalFrames == 30)
    }
}
