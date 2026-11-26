import Foundation
import Testing
@testable import PalmierPro

@Suite("Three-point editing")
@MainActor
struct ThreePointEditTests {

    private func asset(
        type: ClipType = .video,
        duration: Double = 10,
        hasAudio: Bool = false,
        marks: SourceMarks? = nil
    ) -> MediaAsset {
        let a = MediaAsset(url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).mp4"), type: type, name: "clip", duration: duration)
        a.hasAudio = hasAudio
        a.sourceMarks = marks
        return a
    }

    // EditorUndo holds its manager weakly; the suite keeps it alive for the test.
    private let undoManager = UndoManager()

    private func editor(tracks: [Track], assets: [MediaAsset]) -> EditorViewModel {
        let e = EditorViewModel()
        e.timeline = Fixtures.timeline(tracks: tracks)
        e.mediaAssets = assets
        e.undo.attach(undoManager)
        return e
    }

    // MARK: - markedSegment

    struct SegmentCase: Sendable {
        var marks: SourceMarks?
        var duration: Double = 10
        var type: ClipType = .video
        var expected: ClosedRange<Double>?
    }

    private nonisolated static let segmentCases: [SegmentCase] = [
        SegmentCase(marks: nil, expected: nil),
        SegmentCase(marks: SourceMarks(inSeconds: 2), expected: 2...10),
        SegmentCase(marks: SourceMarks(outSeconds: 5), expected: 0...5),
        SegmentCase(marks: SourceMarks(inSeconds: 2, outSeconds: 5), expected: 2...5),
        SegmentCase(marks: SourceMarks(inSeconds: 3, outSeconds: 3), expected: nil),
        SegmentCase(marks: SourceMarks(inSeconds: 5, outSeconds: 2), expected: nil),
        SegmentCase(marks: SourceMarks(inSeconds: 2, outSeconds: 15), expected: 2...10),
        SegmentCase(marks: SourceMarks(inSeconds: 12), expected: nil),
        SegmentCase(marks: SourceMarks(inSeconds: 2, outSeconds: 5), type: .image, expected: nil),
        SegmentCase(marks: SourceMarks(inSeconds: 2, outSeconds: 5), duration: 0, expected: nil),
    ]

    @Test(arguments: segmentCases)
    func markedSegmentClampsAndValidates(_ c: SegmentCase) {
        let a = asset(type: c.type, duration: c.duration, marks: c.marks)
        #expect(a.markedSegment == c.expected)
    }

    // MARK: - Marking

    @Test func markingWritesClampedSecondsAndManifest() {
        let a = asset()
        let e = editor(tracks: [Fixtures.videoTrack()], assets: [a])
        e.openPreviewTab(for: a)

        e.sourcePlayheadFrame = 60
        e.markSourceIn()
        e.sourcePlayheadFrame = 150
        e.markSourceOut()

        #expect(a.sourceMarks == SourceMarks(inSeconds: 2, outSeconds: 5))
        #expect(e.mediaManifest.entries.first { $0.id == a.id }?.sourceMarks == a.sourceMarks)
    }

    @Test func markingInPastOutClearsOut() {
        let a = asset(marks: SourceMarks(inSeconds: 1, outSeconds: 3))
        let e = editor(tracks: [Fixtures.videoTrack()], assets: [a])
        e.openPreviewTab(for: a)

        e.sourcePlayheadFrame = 120
        e.markSourceIn()

        #expect(a.sourceMarks == SourceMarks(inSeconds: 4, outSeconds: nil))
    }

    @Test func markingOutBeforeInClearsIn() {
        let a = asset(marks: SourceMarks(inSeconds: 6, outSeconds: 8))
        let e = editor(tracks: [Fixtures.videoTrack()], assets: [a])
        e.openPreviewTab(for: a)

        e.sourcePlayheadFrame = 90
        e.markSourceOut()

        #expect(a.sourceMarks == SourceMarks(inSeconds: nil, outSeconds: 3))
    }

    @Test func markingImageAssetIsRefused() {
        let a = asset(type: .image)
        let e = editor(tracks: [Fixtures.videoTrack()], assets: [a])
        e.openPreviewTab(for: a)

        e.markSourceIn()

        #expect(a.sourceMarks == nil)
    }

    @Test func clearSourceMarksClearsAssetAndManifest() {
        let a = asset(marks: SourceMarks(inSeconds: 1, outSeconds: 3))
        let e = editor(tracks: [Fixtures.videoTrack()], assets: [a])
        e.openPreviewTab(for: a)

        e.clearSourceMarks()

        #expect(a.sourceMarks == nil)
        #expect(e.mediaManifest.entries.first { $0.id == a.id }?.sourceMarks == nil)
    }

    // MARK: - Append

    @Test func appendPlacesMarkedRangeAtTimelineEnd() throws {
        let a = asset(marks: SourceMarks(inSeconds: 2, outSeconds: 5))
        let existing = Fixtures.clip(start: 0, duration: 100)
        let e = editor(tracks: [Fixtures.videoTrack(clips: [existing])], assets: [a])
        e.openPreviewTab(for: a)
        e.currentFrame = 10

        e.appendSourceToEnd()

        let appended = try #require(e.timeline.tracks[0].clips.first { $0.mediaRef == a.id })
        #expect(appended.startFrame == 100)
        #expect(appended.durationFrames == 90)
        #expect(appended.trimStartFrame == 60)
        #expect(e.currentFrame == 10)
        #expect(e.undo.undoLatest() == "Append to End")
        #expect(e.timeline.tracks[0].clips.map(\.id) == [existing.id])
    }

    @Test func appendOnEmptyTimelineCreatesTracksAndLinkedAudio() throws {
        let a = asset(hasAudio: true)
        let e = editor(tracks: [], assets: [a])
        e.openPreviewTab(for: a)

        e.appendSourceToEnd()

        let videoTrack = try #require(e.timeline.tracks.first { $0.type == .video })
        let audioTrack = try #require(e.timeline.tracks.first { $0.type == .audio })
        let video = try #require(videoTrack.clips.first)
        let audio = try #require(audioTrack.clips.first)
        #expect(video.startFrame == 0)
        #expect(video.durationFrames == 300)
        #expect(video.linkGroupId != nil)
        #expect(video.linkGroupId == audio.linkGroupId)
    }

    // MARK: - Overwrite

    @Test func overwriteReplacesRegionWithoutRipple() {
        let a = asset(marks: SourceMarks(inSeconds: 0, outSeconds: 3))
        let existing = Fixtures.clip(start: 0, duration: 300)
        let downstream = Fixtures.clip(start: 300, duration: 100)
        let e = editor(tracks: [Fixtures.videoTrack(clips: [existing, downstream])], assets: [a])
        e.openPreviewTab(for: a)
        e.currentFrame = 100

        e.overwriteSourceAtPlayhead()

        let clips = e.timeline.tracks[0].clips.sorted { $0.startFrame < $1.startFrame }
        #expect(clips.count == 4)
        #expect(clips[0].endFrame == 100)
        #expect(clips[1].mediaRef == a.id)
        #expect(clips[1].startFrame == 100)
        #expect(clips[1].durationFrames == 90)
        #expect(clips[2].startFrame == 190)
        #expect(clips[3].startFrame == 300)
        #expect(e.currentFrame == 190)

        #expect(e.undo.undoLatest() == "Overwrite at Playhead")
        #expect(e.timeline.tracks[0].clips.count == 2)
        #expect(e.timeline.tracks[0].clips.map(\.durationFrames) == [300, 100])
    }

    // MARK: - Insert

    @Test func insertSplitsStraddlerAndRipples() {
        let a = asset(marks: SourceMarks(inSeconds: 0, outSeconds: 3))
        let straddler = Fixtures.clip(start: 0, duration: 300)
        let syncClip = Fixtures.clip(mediaRef: "other", mediaType: .audio, start: 200, duration: 100)
        let e = editor(
            tracks: [Fixtures.videoTrack(clips: [straddler]), Fixtures.audioTrack(clips: [syncClip])],
            assets: [a]
        )
        e.openPreviewTab(for: a)
        e.currentFrame = 100

        e.insertSourceAtPlayhead()

        let clips = e.timeline.tracks[0].clips.sorted { $0.startFrame < $1.startFrame }
        #expect(clips.count == 3)
        #expect(clips[0].endFrame == 100)
        #expect(clips[1].mediaRef == a.id)
        #expect(clips[1].startFrame == 100)
        #expect(clips[2].startFrame == 190)
        #expect(clips[2].endFrame == 390)
        // Sync-locked audio track ripples too.
        #expect(e.timeline.tracks[1].clips.first?.startFrame == 290)
        #expect(e.currentFrame == 190)

        #expect(e.undo.undoLatest() == "Insert at Playhead")
        #expect(e.timeline.tracks[0].clips.map(\.durationFrames) == [300])
        #expect(e.timeline.tracks[1].clips.first?.startFrame == 200)
    }

    // MARK: - Refusals

    @Test func editWithNoSourceIsRefusedWithoutUndoEntry() {
        let e = editor(tracks: [Fixtures.videoTrack()], assets: [])

        e.appendSourceToEnd()
        e.insertSourceAtPlayhead()
        e.overwriteSourceAtPlayhead()

        #expect(e.timeline.tracks[0].clips.isEmpty)
        #expect(e.undo.undoLatest() == nil)
    }

    @Test func editWithGeneratingAssetIsRefused() {
        let a = asset()
        a.generationStatus = .generating
        let e = editor(tracks: [Fixtures.videoTrack()], assets: [a])
        e.selectedMediaAssetIds = [a.id]

        e.appendSourceToEnd()

        #expect(e.timeline.tracks[0].clips.isEmpty)
        #expect(e.undo.undoLatest() == nil)
    }

    @Test func selectedPanelAssetsAreEditSourceWhenTimelineTabActive() {
        let a = asset()
        let e = editor(tracks: [Fixtures.videoTrack()], assets: [a])
        e.selectedMediaAssetIds = [a.id]

        e.appendSourceToEnd()

        #expect(e.timeline.tracks[0].clips.first?.mediaRef == a.id)
    }

    // MARK: - Regressions

    @Test func rippleDropStillDoesNotSplitStraddlers() throws {
        let a = asset()
        let straddler = Fixtures.clip(start: 0, duration: 300)
        let e = editor(tracks: [Fixtures.videoTrack(clips: [straddler])], assets: [a])

        e.placeDroppedAssets([a], cursor: .existingTrack(0), atFrame: 100, ripple: true)

        let original = try #require(e.timeline.tracks[0].clips.first { $0.id == straddler.id })
        #expect(original.startFrame == 0)
        #expect(original.durationFrames == 300)
    }

    @Test func sourceMarksRoundTripThroughManifest() throws {
        let a = asset(marks: SourceMarks(inSeconds: 1.5, outSeconds: 7.25))
        let entry = a.toManifestEntry(projectURL: nil)
        let decoded = try JSONDecoder().decode(MediaManifestEntry.self, from: JSONEncoder().encode(entry))
        let restored = MediaAsset(entry: decoded, resolvedURL: a.url)
        #expect(restored.sourceMarks == a.sourceMarks)
        #expect(restored.markedSegment == 1.5...7.25)

        // Manifests written before sourceMarks existed decode with nil marks.
        var legacy = entry
        legacy.sourceMarks = nil
        let legacyDecoded = try JSONDecoder().decode(MediaManifestEntry.self, from: JSONEncoder().encode(legacy))
        #expect(legacyDecoded.sourceMarks == nil)
    }
}
