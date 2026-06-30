import Foundation
import Testing
@testable import PalmierPro

private final class SpyUndoManager: UndoManager {
    var actionNames: [String] = []
    override func setActionName(_ actionName: String) {
        actionNames.append(actionName)
        super.setActionName(actionName)
    }
}

@Suite("apply_layout")
@MainActor
struct ApplyLayoutTests {

    private func approx(_ a: Double, _ b: Double, tol: Double = 1e-6) -> Bool { abs(a - b) < tol }

    @discardableResult
    private func videoAsset(_ h: ToolHarness, id: String, w: Int = 1920, ht: Int = 1080, hasAudio: Bool = false) -> MediaAsset {
        let a = h.addAsset(id: id, type: .video, hasAudio: hasAudio)
        a.sourceWidth = w
        a.sourceHeight = ht
        return a
    }

    private func configured(_ w: Int, _ h: Int) -> ToolHarness {
        var t = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [Fixtures.clip(id: "existing", start: 0, duration: 30)])])
        t.width = w; t.height = h; t.settingsConfigured = true
        return ToolHarness(timeline: t)
    }

    private func clips(_ h: ToolHarness, mediaRef: String) -> Clip? {
        h.editor.timeline.tracks.flatMap(\.clips).first { $0.mediaRef == mediaRef }
    }

    private func clip(_ h: ToolHarness, id: String) -> Clip? {
        h.editor.timeline.tracks.flatMap(\.clips).first { $0.id == id }
    }

    @Test func placementAdoptsLayoutSlotOrderForSettings() async throws {
        let h = ToolHarness()
        videoAsset(h, id: "landscape", w: 1920, ht: 1080)
        videoAsset(h, id: "portrait", w: 1080, ht: 1920)
        let r = await h.runRaw("apply_layout", args: [
            "layout": "side_by_side", "durationFrames": 60,
            "slots": [["slot": "right", "mediaRef": "portrait"], ["slot": "left", "mediaRef": "landscape"]],
        ])
        #expect(r.isError == false)
        #expect(h.editor.timeline.width == 1920)
        #expect(h.editor.timeline.height == 1080)
    }

    @Test func sideBySideFillsWithoutStretch() async throws {
        let h = ToolHarness()
        videoAsset(h, id: "a"); videoAsset(h, id: "b")
        let r = await h.runRaw("apply_layout", args: [
            "layout": "side_by_side", "durationFrames": 120,
            "slots": [["slot": "left", "mediaRef": "a"], ["slot": "right", "mediaRef": "b"]],
        ])
        #expect(r.isError == false)
        #expect(h.editor.timeline.tracks.count == 2)
        let left = clips(h, mediaRef: "a")!
        let right = clips(h, mediaRef: "b")!
        #expect(approx(left.transform.centerX, 0.25))
        #expect(approx(right.transform.centerX, 0.75))
        let canvasAspect = 1920.0 / 1080.0
        for c in [left, right] {
            #expect(approx(c.crop.left, 0.25))
            #expect(approx(c.crop.right, 0.25))
            #expect(approx((c.transform.width / c.transform.height) * canvasAspect, 16.0 / 9.0, tol: 1e-3))
            #expect(approx(c.transform.width * c.crop.visibleWidthFraction, 0.5))
            #expect(approx(c.transform.height * c.crop.visibleHeightFraction, 1.0))
        }
    }

    @Test func pipInsetSitsOnTopOfMain() async throws {
        let h = ToolHarness()
        videoAsset(h, id: "screen"); videoAsset(h, id: "cam")
        let r = await h.runRaw("apply_layout", args: [
            "layout": "pip_bottom_right", "durationFrames": 90,
            "slots": [["slot": "main", "mediaRef": "screen"], ["slot": "inset", "mediaRef": "cam"]],
        ])
        #expect(r.isError == false)
        #expect(h.editor.timeline.tracks.count == 2)
        var insetIdx = -1, mainIdx = -1
        for (i, t) in h.editor.timeline.tracks.enumerated() {
            for c in t.clips {
                if approx(c.transform.width, 0.28) { insetIdx = i }
                if approx(c.transform.width, 1.0) { mainIdx = i }
            }
        }
        #expect(insetIdx >= 0 && mainIdx >= 0)
        #expect(insetIdx < mainIdx)
        let inset = clips(h, mediaRef: "cam")!
        #expect(inset.transform.topLeft.x > 0.6 && inset.transform.topLeft.y > 0.6)
    }

    @Test func fitLetterboxesWithoutCropping() async throws {
        let h = ToolHarness()
        videoAsset(h, id: "a"); videoAsset(h, id: "b")
        let r = await h.runRaw("apply_layout", args: [
            "layout": "top_bottom", "durationFrames": 60, "fit": "fit",
            "slots": [["slot": "top", "mediaRef": "a"], ["slot": "bottom", "mediaRef": "b"]],
        ])
        #expect(r.isError == false)
        let canvasAspect = 1920.0 / 1080.0
        for c in h.editor.timeline.tracks.flatMap(\.clips) {
            #expect(approx(c.crop.left, 0) && approx(c.crop.top, 0))
            #expect(approx((c.transform.width / c.transform.height) * canvasAspect, 16.0 / 9.0, tol: 1e-3))
            #expect(c.transform.height <= 0.5 + 1e-6)
        }
    }

    @Test func gridFillsFourSlots() async throws {
        let h = ToolHarness()
        for id in ["a", "b", "c", "d"] { videoAsset(h, id: id) }
        let r = await h.runRaw("apply_layout", args: [
            "layout": "grid_2x2", "durationFrames": 90,
            "slots": [
                ["slot": "top_left", "mediaRef": "a"], ["slot": "top_right", "mediaRef": "b"],
                ["slot": "bottom_left", "mediaRef": "c"], ["slot": "bottom_right", "mediaRef": "d"],
            ],
        ])
        #expect(r.isError == false)
        let cs = h.editor.timeline.tracks.flatMap(\.clips)
        #expect(cs.count == 4)
        for c in cs { #expect(approx(c.transform.width, 0.5) && approx(c.transform.height, 0.5)) }
    }

    @Test func placementIsSingleUndoStep() async throws {
        let h = configured(1920, 1080)
        for id in ["a", "b", "c", "d"] { videoAsset(h, id: id, hasAudio: true) }
        let um = SpyUndoManager()
        h.editor.undoManager = um
        let r = await h.runRaw("apply_layout", args: [
            "layout": "grid_2x2", "durationFrames": 90,
            "slots": [
                ["slot": "top_left", "mediaRef": "a"], ["slot": "top_right", "mediaRef": "b"],
                ["slot": "bottom_left", "mediaRef": "c"], ["slot": "bottom_right", "mediaRef": "d"],
            ],
        ])
        #expect(r.isError == false)
        #expect(um.actionNames == ["Apply Layout (Agent)"])

        let tracksAfter = h.editor.timeline.tracks.count
        #expect(tracksAfter > 1)
        um.undo()
        #expect(h.editor.timeline.tracks.count < tracksAfter)
        #expect(h.editor.timeline.tracks.flatMap(\.clips).allSatisfy { $0.id == "existing" })
        #expect(um.canUndo == false)
    }

    @Test func reLayoutsExistingClipsByClipId() async throws {
        let timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "ca", mediaRef: "a", start: 0, duration: 60)]),
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "cb", mediaRef: "b", start: 0, duration: 60)]),
        ])
        let h = ToolHarness(timeline: timeline)
        videoAsset(h, id: "a"); videoAsset(h, id: "b")
        let before = h.editor.timeline.tracks.count
        let r = await h.runRaw("apply_layout", args: [
            "layout": "side_by_side",
            "slots": [["slot": "left", "clipIds": ["ca"]], ["slot": "right", "clipIds": ["cb"]]],
        ])
        #expect(r.isError == false)
        #expect(h.editor.timeline.tracks.count == before)
        #expect(approx(clip(h, id: "ca")!.transform.centerX, 0.25))
        #expect(approx(clip(h, id: "cb")!.transform.centerX, 0.75))
        #expect(clip(h, id: "ca")!.startFrame == 0)
    }

    @Test func reLayoutsBatchOfClipsIntoOneSlot() async throws {
        var t = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "ca", mediaRef: "a", start: 0, duration: 60),
                Fixtures.clip(id: "cb", mediaRef: "a", start: 60, duration: 60),
            ]),
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "cc", mediaRef: "b", start: 0, duration: 120)]),
        ])
        t.width = 1920; t.height = 1080; t.settingsConfigured = true
        let h = ToolHarness(timeline: t)
        videoAsset(h, id: "a"); videoAsset(h, id: "b")
        let before = h.editor.timeline.tracks.count
        let r = await h.runRaw("apply_layout", args: [
            "layout": "side_by_side",
            "slots": [["slot": "left", "clipIds": ["ca", "cb"]], ["slot": "right", "clipIds": ["cc"]]],
        ])
        #expect(r.isError == false)
        #expect(h.editor.timeline.tracks.count == before)
        #expect(approx(clip(h, id: "ca")!.transform.centerX, 0.25))
        #expect(approx(clip(h, id: "cb")!.transform.centerX, 0.25))
        #expect(approx(clip(h, id: "cc")!.transform.centerX, 0.75))
    }

    @Test func batchRejectsOverlapAcrossDifferentSlots() async throws {
        var t = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "ca", mediaRef: "a", start: 0, duration: 60),
            Fixtures.clip(id: "cb", mediaRef: "b", start: 30, duration: 60),
        ])])
        t.width = 1920; t.height = 1080; t.settingsConfigured = true
        let h = ToolHarness(timeline: t)
        videoAsset(h, id: "a"); videoAsset(h, id: "b")
        let r = await h.runRaw("apply_layout", args: [
            "layout": "side_by_side",
            "slots": [["slot": "left", "clipIds": ["ca"]], ["slot": "right", "clipIds": ["cb"]]],
        ])
        #expect(r.isError)
        #expect(approx(clip(h, id: "ca")!.transform.centerX, 0.5))
    }

    @Test func batchRejectsEmptyAndDuplicateClipIds() async throws {
        var t = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "ca", mediaRef: "a", start: 0, duration: 60)]),
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "cb", mediaRef: "b", start: 0, duration: 60)]),
        ])
        t.width = 1920; t.height = 1080; t.settingsConfigured = true
        let h = ToolHarness(timeline: t)
        videoAsset(h, id: "a"); videoAsset(h, id: "b")
        let empty = await h.runRaw("apply_layout", args: [
            "layout": "side_by_side",
            "slots": [["slot": "left", "clipIds": [String]()], ["slot": "right", "clipIds": ["cb"]]],
        ])
        #expect(empty.isError)
        let dup = await h.runRaw("apply_layout", args: [
            "layout": "side_by_side",
            "slots": [["slot": "left", "clipIds": ["ca", "ca"]], ["slot": "right", "clipIds": ["cb"]]],
        ])
        #expect(dup.isError)
    }

    @Test func reLayoutClearsAnimationTracks() async throws {
        var t = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "ca", mediaRef: "a", start: 0, duration: 60)]),
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "cb", mediaRef: "b", start: 0, duration: 60)]),
        ])
        t.width = 1920; t.height = 1080; t.settingsConfigured = true
        let h = ToolHarness(timeline: t)
        videoAsset(h, id: "a"); videoAsset(h, id: "b")
        h.editor.timeline.tracks[0].clips[0].positionTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: AnimPair(a: 0, b: 0)),
            Keyframe(frame: 60, value: AnimPair(a: 0.5, b: 0.5)),
        ])
        h.editor.timeline.tracks[0].clips[0].scaleTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: AnimPair(a: 1, b: 1)),
            Keyframe(frame: 60, value: AnimPair(a: 0.5, b: 0.5)),
        ])
        h.editor.timeline.tracks[0].clips[0].cropTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: Crop()),
            Keyframe(frame: 60, value: Crop(left: 0.5, top: 0, right: 0, bottom: 0)),
        ])
        let r = await h.runRaw("apply_layout", args: [
            "layout": "side_by_side",
            "slots": [["slot": "left", "clipIds": ["ca"]], ["slot": "right", "clipIds": ["cb"]]],
        ])
        #expect(r.isError == false)
        let c = clip(h, id: "ca")!
        #expect(c.positionTrack == nil && c.scaleTrack == nil && c.cropTrack == nil)
        #expect(approx(c.transformAt(frame: 0).centerX, 0.25))
        #expect(approx(c.transformAt(frame: 60).centerX, 0.25))
    }

    @Test func reLayoutRejectsSameTrackOverlap() async throws {
        var t = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "ca", mediaRef: "a", start: 0, duration: 60),
            Fixtures.clip(id: "cb", mediaRef: "b", start: 30, duration: 60),
        ])])
        t.width = 1920; t.height = 1080; t.settingsConfigured = true
        let h = ToolHarness(timeline: t)
        videoAsset(h, id: "a"); videoAsset(h, id: "b")
        let r = await h.runRaw("apply_layout", args: [
            "layout": "side_by_side",
            "slots": [["slot": "left", "clipIds": ["ca"]], ["slot": "right", "clipIds": ["cb"]]],
        ])
        #expect(r.isError)
        #expect(approx(clip(h, id: "ca")!.transform.centerX, 0.5))
    }

    @Test func reLayoutRejectsClipsThatNeverCoincide() async throws {
        var t = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "ca", mediaRef: "a", start: 0, duration: 60)]),
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "cb", mediaRef: "b", start: 120, duration: 60)]),
        ])
        t.width = 1920; t.height = 1080; t.settingsConfigured = true
        let h = ToolHarness(timeline: t)
        videoAsset(h, id: "a"); videoAsset(h, id: "b")
        let r = await h.runRaw("apply_layout", args: [
            "layout": "side_by_side",
            "slots": [["slot": "left", "clipIds": ["ca"]], ["slot": "right", "clipIds": ["cb"]]],
        ])
        #expect(r.isError)
        #expect(approx(clip(h, id: "ca")!.transform.centerX, 0.5))
    }

    @Test func fullRefitsSingleClipToCanvasAspect() async throws {
        var t = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", mediaRef: "wide", start: 0, duration: 60)])])
        t.width = 1080; t.height = 1920; t.settingsConfigured = true
        let h = ToolHarness(timeline: t)
        videoAsset(h, id: "wide", w: 1920, ht: 1080)
        let before = h.editor.timeline.tracks.count
        let r = await h.runRaw("apply_layout", args: [
            "layout": "full", "slots": [["slot": "main", "clipIds": ["c1"], "anchorX": 0.3]],
        ])
        #expect(r.isError == false)
        #expect(h.editor.timeline.tracks.count == before)
        let c = clip(h, id: "c1")!
        #expect(approx(c.transform.width * c.crop.visibleWidthFraction, 1.0))
        #expect(approx(c.transform.height * c.crop.visibleHeightFraction, 1.0))
        #expect(approx((c.transform.width / c.transform.height) * (1080.0 / 1920.0), 16.0 / 9.0, tol: 1e-3))
        #expect(approx(c.crop.top, 0))
        #expect(approx(c.crop.left, (c.crop.left + c.crop.right) * 0.3))
    }

    @Test func anchorBiasesCropContinuously() async throws {
        let h = configured(1920, 1080)
        for id in ["c", "p", "t"] { videoAsset(h, id: id, w: 1080, ht: 1920) }
        let r = await h.runRaw("apply_layout", args: [
            "layout": "three_up", "durationFrames": 60,
            "slots": [
                ["slot": "left", "mediaRef": "c"],
                ["slot": "center", "mediaRef": "p", "anchorY": 0.2],
                ["slot": "right", "mediaRef": "t", "anchor": "top"],
            ],
        ])
        #expect(r.isError == false)
        let center = clips(h, mediaRef: "c")!, partial = clips(h, mediaRef: "p")!, top = clips(h, mediaRef: "t")!
        let total = center.crop.top + center.crop.bottom
        #expect(total > 0.01)
        #expect(approx(partial.crop.top, total * 0.2))
        #expect(approx(top.crop.top, 0))
        #expect(top.crop.top < partial.crop.top && partial.crop.top < center.crop.top)
        #expect(approx(center.crop.top, center.crop.bottom))
        #expect(approx(top.transform.topLeft.y, 0))
    }

    @Test func rejectsInvalidInput() async {
        let t = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [Fixtures.clip(id: "cx", mediaRef: "a", start: 0, duration: 30)])])
        let h = ToolHarness(timeline: t)
        videoAsset(h, id: "a"); videoAsset(h, id: "b")
        let bad: [(String, [String: Any])] = [
            ("unknown layout", ["layout": "hexagon", "durationFrames": 30, "slots": [["slot": "left", "mediaRef": "a"]]]),
            ("unknown slot", ["layout": "side_by_side", "durationFrames": 30, "slots": [["slot": "left", "mediaRef": "a"], ["slot": "mid", "mediaRef": "b"]]]),
            ("missing slot", ["layout": "side_by_side", "durationFrames": 30, "slots": [["slot": "left", "mediaRef": "a"]]]),
            ("mixed sources", ["layout": "side_by_side", "durationFrames": 30, "slots": [["slot": "left", "clipIds": ["cx"]], ["slot": "right", "mediaRef": "b"]]]),
            ("no duration", ["layout": "side_by_side", "slots": [["slot": "left", "mediaRef": "a"], ["slot": "right", "mediaRef": "b"]]]),
            ("both source + clip", ["layout": "full", "durationFrames": 30, "slots": [["slot": "main", "mediaRef": "a", "clipIds": ["cx"]]]]),
            ("invalid anchor", ["layout": "full", "durationFrames": 30, "slots": [["slot": "main", "mediaRef": "a", "anchor": "diagonal"]]]),
            ("anchor out of range", ["layout": "full", "durationFrames": 30, "slots": [["slot": "main", "mediaRef": "a", "anchorY": 1.5]]]),
            ("duplicate clipIds", ["layout": "side_by_side", "slots": [["slot": "left", "clipIds": ["cx"]], ["slot": "right", "clipIds": ["cx"]]]]),
            ("deprecated clipId", ["layout": "side_by_side", "slots": [["slot": "left", "clipId": "cx"], ["slot": "right", "clipIds": ["b"]]]]),
        ]
        for (label, args) in bad {
            let r = await h.runRaw("apply_layout", args: args)
            #expect(r.isError, "expected error for: \(label)")
        }
    }
}
