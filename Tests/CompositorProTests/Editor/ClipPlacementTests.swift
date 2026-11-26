import Testing
@testable import CompositorPro

struct ClipPlacementTests {
    private let source = ClipPlacement.Source(mediaRef: "source", type: .video, durationSeconds: 10,
                                              hasAudio: true, width: 1920, height: 1080)

    @Test func linkedAudioSharesExactSourceAndTimelineRanges() throws {
        let result = try ClipPlacement.make(source: source, trackType: .video, fps: 30, canvasWidth: 1080,
            canvasHeight: 1920, startFrame: 45, durationFrames: 90, trimStartFrame: 60,
            primaryId: "visual", audioId: "audio", linkGroupId: "link")
        let audio = try #require(result.linkedAudio)
        #expect(result.primary.transform == Transform(width: 1, height: 0.31640625))
        #expect(result.primary.trimEndFrame == 150)
        #expect(audio.startFrame == result.primary.startFrame && audio.durationFrames == result.primary.durationFrames)
        #expect(audio.trimStartFrame == 60 && audio.trimEndFrame == 150)
        #expect(audio.linkGroupId == result.primary.linkGroupId && audio.linkGroupId == "link")
        #expect(audio.sourceClipType == .video && audio.mediaType == .audio)
    }

    @Test func omittedSourceAudioCreatesOnlyVisualClip() throws {
        let result = try ClipPlacement.make(source: source, trackType: .video, fps: 30, canvasWidth: 1920,
            canvasHeight: 1080, startFrame: 0, durationFrames: 30, addLinkedAudio: false)
        #expect(result.linkedAudio == nil && result.primary.linkGroupId == nil)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, -1, Double(maxFrameArg)])
    func invalidSourceSecondsAreRefused(seconds: Double) {
        #expect(throws: ClipPlacement.Failure.invalidRange) { try ClipPlacement.frames(seconds: seconds, fps: 30) }
    }

    @Test(arguments: [(0, 0, 0), (-1, 1, 0), (maxFrameArg, 1, 0), (0, 301, 0), (0, 30, 280), (0, 30, -1)])
    func invalidFrameRangesAreRefused(range: (Int, Int, Int)) {
        #expect(throws: ClipPlacement.Failure.invalidRange) {
            try ClipPlacement.make(source: source, trackType: .video, fps: 30, canvasWidth: 1920,
                canvasHeight: 1080, startFrame: range.0, durationFrames: range.1, trimStartFrame: range.2)
        }
    }

    @Test(arguments: [0.0, Double.nan, -1])
    func movingSourcesNeedKnownPositiveDuration(duration: Double) {
        let unknown = ClipPlacement.Source(mediaRef: "source", type: .video, durationSeconds: duration,
                                            hasAudio: false, width: nil, height: nil)
        #expect(throws: ClipPlacement.Failure.invalidRange) {
            try ClipPlacement.make(source: unknown, trackType: .video, fps: 30, canvasWidth: 1920,
                canvasHeight: 1080, startFrame: 0, durationFrames: 30)
        }
    }

    @Test func stillImageCanHoldWithoutSourceDuration() throws {
        let still = ClipPlacement.Source(mediaRef: "still", type: .image, durationSeconds: 0,
                                          hasAudio: false, width: nil, height: nil)
        let result = try ClipPlacement.make(source: still, trackType: .video, fps: 30, canvasWidth: 1920,
            canvasHeight: 1080, startFrame: 0, durationFrames: 300)
        #expect(result.primary.durationFrames == 300 && result.linkedAudio == nil)
    }

    @Test(arguments: [-100, 0, 1, 100])
    func trackInsertionKeepsVisualAudioPartition(requested: Int) {
        let tracks = [Track(type: .video), Track(type: .audio)]
        #expect(ClipPlacement.trackInsertionIndex(type: .video, requested: requested, tracks: tracks) <= 1)
        #expect(ClipPlacement.trackInsertionIndex(type: .audio, requested: requested, tracks: tracks) >= 1)
    }
}
