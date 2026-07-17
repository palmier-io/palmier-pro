import Testing
@testable import PalmierPro

@Suite("ClipType")
struct ClipTypeTests {

    @Test func notificationLabelDistinguishesSequencesFromVideoTracks() {
        #expect(ClipType.sequence.notificationLabel == "Sequence")
        #expect(ClipType.video.notificationLabel == "Video")
        #expect(ClipType.audio.notificationLabel == "Audio")
    }
}
