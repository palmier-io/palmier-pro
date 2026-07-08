import Foundation
import Testing
@testable import PalmierPro

@MainActor
@Suite("Multi-timeline — proxy, switching, CRUD")
struct MultiTimelineTests {

    @Test func proxyAssignmentAdoptsUnknownIdInActiveSlot() {
        let e = EditorViewModel()
        let replacement = Fixtures.timeline(tracks: [Fixtures.videoTrack()])
        e.timeline = replacement
        #expect(e.activeTimelineId == replacement.id)
        #expect(e.timelines.count == 1)
        #expect(e.openTimelineIds == [replacement.id])
    }

    @Test func proxyAssignmentRoutesByIdAndActivates() {
        let e = EditorViewModel()
        let firstId = e.activeTimelineId
        let secondId = e.createTimeline(activate: false)
        #expect(e.activeTimelineId == firstId)

        var second = e.timeline(for: secondId)!
        second.tracks = [Fixtures.videoTrack()]
        e.timeline = second

        #expect(e.activeTimelineId == secondId)
        #expect(e.timeline(for: secondId)?.tracks.count == 1)
        #expect(e.timeline(for: firstId)?.tracks.isEmpty == true)
    }

    @Test func activateStashesAndRestoresViewState() {
        let e = EditorViewModel()
        let firstId = e.activeTimelineId
        e.timeline.tracks = [Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 500)])]
        let secondId = e.createTimeline(activate: false)

        e.currentFrame = 120
        e.zoomScale = 9.5
        e.activateTimeline(secondId)

        #expect(e.viewState(for: firstId).playheadFrame == 120)
        #expect(e.viewState(for: firstId).zoomScale == 9.5)
        #expect(e.zoomScale == Defaults.pixelsPerFrame)
        #expect(e.currentFrame == 0)

        e.activateTimeline(firstId)
        #expect(e.currentFrame == 120)
        #expect(e.zoomScale == 9.5)
    }

    @Test func activateClearsTimelineScopedSelection() {
        let e = EditorViewModel()
        e.timeline.tracks = [Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 30)])]
        e.selectedClipIds = [e.timeline.tracks[0].clips[0].id]
        let secondId = e.createTimeline(activate: false)
        e.activateTimeline(secondId)
        #expect(e.selectedClipIds.isEmpty)
    }

    @Test func createInheritsSettingsAndAutoNames() {
        let e = EditorViewModel()
        e.applyTimelineSettings(fps: 24, width: 1080, height: 1920)
        let id = e.createTimeline()
        let t = e.timeline(for: id)!
        #expect(t.fps == 24)
        #expect(t.width == 1080)
        #expect(t.height == 1920)
        #expect(t.settingsConfigured)
        #expect(t.name == "Timeline 2")
        #expect(e.activeTimelineId == id)
        #expect(e.openTimelineIds.contains(id))
    }

    @Test func duplicateCopiesContentWithFreshIds() {
        let e = EditorViewModel()
        let a = Fixtures.clip(start: 0, duration: 30)
        var b = Fixtures.clip(mediaType: .audio, start: 0, duration: 30)
        b.linkGroupId = "g1"
        var a2 = a
        a2.linkGroupId = "g1"
        e.timeline.tracks = [Fixtures.videoTrack(clips: [a2]), Fixtures.audioTrack(clips: [b])]
        e.timeline.name = "Main"
        let sourceId = e.activeTimelineId

        let dupId = e.duplicateTimeline(sourceId)!
        let dup = e.timeline(for: dupId)!
        let source = e.timeline(for: sourceId)!

        #expect(dup.name == "Main copy")
        #expect(dup.tracks.count == 2)
        #expect(dup.tracks[0].id != source.tracks[0].id)
        #expect(dup.tracks[0].clips[0].id != source.tracks[0].clips[0].id)
        let g = dup.tracks[0].clips[0].linkGroupId
        #expect(g != nil && g != "g1")
        #expect(dup.tracks[1].clips[0].linkGroupId == g)
    }

    @Test func deleteKeepsAtLeastOneAndReactivates() {
        let e = EditorViewModel()
        let firstId = e.activeTimelineId
        e.deleteTimeline(firstId)
        #expect(e.timelines.count == 1)   // last timeline is not deletable

        let secondId = e.createTimeline()
        #expect(e.activeTimelineId == secondId)
        e.deleteTimeline(secondId)
        #expect(e.activeTimelineId == firstId)
        #expect(e.timelines.count == 1)
        #expect(!e.openTimelineIds.contains(secondId))
    }

    @Test func deleteUndoRestoresTimelineAndTab() {
        let e = EditorViewModel()
        let undo = UndoManager()
        e.undoManager = undo
        let secondId = e.createTimeline()
        e.timeline.tracks = [Fixtures.videoTrack()]

        undo.removeAllActions()
        e.deleteTimeline(secondId)
        #expect(e.timeline(for: secondId) == nil)

        undo.undo()
        #expect(e.timeline(for: secondId)?.tracks.count == 1)
        #expect(e.openTimelineIds.contains(secondId))

        undo.redo()
        #expect(e.timeline(for: secondId) == nil)
    }

    @Test func renameTrimsAndUndoes() {
        let e = EditorViewModel()
        let undo = UndoManager()
        e.undoManager = undo
        let id = e.activeTimelineId
        let original = e.timeline.name
        e.renameTimeline(id, to: "  Selects  ")
        #expect(e.timeline.name == "Selects")
        undo.undo()
        #expect(e.timeline.name == original)
    }

    @Test func closeTabNeverClosesLastAndReactivatesNeighbor() {
        let e = EditorViewModel()
        let firstId = e.activeTimelineId
        let secondId = e.createTimeline()
        e.closeTimelineTab(secondId)
        #expect(e.openTimelineIds == [firstId])
        #expect(e.activeTimelineId == firstId)
        #expect(e.timeline(for: secondId) != nil)   // closing a tab never deletes
        e.closeTimelineTab(firstId)
        #expect(e.openTimelineIds == [firstId])
    }

    @Test func deleteMediaSweepsAllTimelines() {
        let e = EditorViewModel()
        e.timeline.tracks = [Fixtures.videoTrack(clips: [Fixtures.clip(mediaRef: "m1", start: 0, duration: 30)])]
        let secondId = e.createTimeline(activate: false)
        var second = e.timeline(for: secondId)!
        second.tracks = [Fixtures.videoTrack(clips: [
            Fixtures.clip(mediaRef: "m1", start: 0, duration: 30),
            Fixtures.clip(mediaRef: "m2", start: 30, duration: 30)
        ])]
        e.timelines[e.timelines.firstIndex(where: { $0.id == secondId })!] = second

        let removed = e.removeClipsReferencingAssets(["m1"])

        #expect(removed.count == 2)
        #expect(e.timeline.tracks.isEmpty)   // emptied track pruned
        let rest = e.timeline(for: secondId)!
        #expect(rest.tracks.count == 1)
        #expect(rest.tracks[0].clips.map(\.mediaRef) == ["m2"])
    }

    @Test func settingsUndoLandsOnOwningTimeline() {
        let e = EditorViewModel()
        let undo = UndoManager()
        e.undoManager = undo
        let firstId = e.activeTimelineId
        e.applyTimelineSettings(fps: 30, width: 1920, height: 1080)
        undo.removeAllActions()

        e.applyTimelineSettings(fps: 30, width: 3840, height: 2160)
        undo.disableUndoRegistration()
        let secondId = e.createTimeline()
        undo.enableUndoRegistration()
        #expect(e.activeTimelineId == secondId)

        undo.undo()   // resolution undo must land back on A, not B
        #expect(e.activeTimelineId == firstId)
        #expect(e.timeline(for: firstId)?.width == 1920)
        #expect(e.timeline(for: secondId)?.width == 3840)   // B untouched
    }

    @Test func projectFileSnapshotCarriesLiveViewState() {
        let e = EditorViewModel()
        e.timeline.tracks = [Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 500)])]
        e.currentFrame = 250
        e.zoomScale = 6
        let file = e.projectFileSnapshot()
        #expect(file.viewStates?[e.activeTimelineId]?.playheadFrame == 250)
        #expect(file.viewStates?[e.activeTimelineId]?.zoomScale == 6)
    }

    @Test func deleteActiveTimelineUndoReactivatesWithFreshViewState() {
        let e = EditorViewModel()
        let undo = UndoManager()
        e.undoManager = undo
        e.timeline.tracks = [Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 900)])]
        let firstId = e.activeTimelineId
        _ = e.createTimeline()
        e.activateTimeline(firstId)
        e.currentFrame = 800
        undo.removeAllActions()

        e.deleteTimeline(firstId)
        undo.undo()

        #expect(e.activeTimelineId == firstId)
        #expect(e.currentFrame == 800)
    }

    @Test func timelineUndoReactivatesOwningTimeline() {
        let e = EditorViewModel()
        let undo = UndoManager()
        e.undoManager = undo
        let aId = e.activeTimelineId
        let bId = e.createTimeline(activate: false)
        undo.removeAllActions()

        var undoneOnTimeline: String?
        e.registerTimelineUndo { vm in undoneOnTimeline = vm.activeTimelineId }
        e.activateTimeline(bId)
        undo.undo()

        #expect(undoneOnTimeline == aId)
        #expect(e.activeTimelineId == aId)
    }

    @Test func finalizeGeneratingClipPatchesDuplicatedCopies() {
        let e = EditorViewModel()
        e.timeline.tracks = [Fixtures.videoTrack(clips: [Fixtures.clip(mediaRef: "gen-1", start: 0, duration: 300)])]
        let copyId = e.duplicateTimeline(e.activeTimelineId, activate: false)
        let asset = MediaAsset(id: "gen-1", url: URL(fileURLWithPath: "/tmp/x.mp4"), type: .video, name: "gen", duration: 2)

        e.finalizeGeneratingClip(placeholderId: "gen-1", asset: asset)

        let expected = 2 * e.timeline.fps
        for id in [e.activeTimelineId, copyId].compactMap({ $0 }) {
            let clip = e.timeline(for: id)?.tracks.flatMap(\.clips).first { $0.mediaRef == "gen-1" }
            #expect(clip?.durationFrames == expected)
        }
    }

    @Test func deleteTimelineClearsMediaPanelSelection() {
        let e = EditorViewModel()
        let second = e.createTimeline(activate: false)
        e.selectedTimelineIds = [second]
        e.deleteTimeline(second)
        #expect(e.selectedTimelineIds.isEmpty)
    }

    @Test func moveTimelinesToFolderSetsParentAndUndoes() {
        let e = EditorViewModel()
        let undo = UndoManager()
        e.undoManager = undo
        let folderId = e.createFolder(name: "Cuts")
        let tid = e.activeTimelineId
        undo.removeAllActions()

        e.moveTimelinesToFolder(timelineIds: [tid], folderId: folderId)
        #expect(e.timeline(for: tid)?.folderId == folderId)

        undo.undo()
        #expect(e.timeline(for: tid)?.folderId == nil)
    }

    @Test func deleteFolderReparentsContainedTimelinesToRoot() {
        let e = EditorViewModel()
        let folderId = e.createFolder(name: "Cuts")
        let tid = e.activeTimelineId
        e.moveTimelinesToFolder(timelineIds: [tid], folderId: folderId)

        e.deleteFolders(ids: [folderId])

        #expect(e.timeline(for: tid) != nil)   // never cascade-deleted
        #expect(e.timeline(for: tid)?.folderId == nil)
    }

    @Test func timelineFolderIdPersists() throws {
        var t = Fixtures.timeline()
        t.folderId = "f1"
        let file = ProjectFile(timelines: [t], activeTimelineId: t.id, openTimelineIds: [t.id])
        let decoded = try ProjectFile.decode(JSONEncoder().encode(file))
        #expect(decoded.timelines[0].folderId == "f1")
    }

    @Test func fpsChangeRescalesEveryTimeline() {
        let e = EditorViewModel()
        e.timeline.tracks = [Fixtures.videoTrack(clips: [Fixtures.clip(start: 30, duration: 30)])]
        let secondId = e.createTimeline(activate: false)
        var second = e.timeline(for: secondId)!
        second.tracks = [Fixtures.videoTrack(clips: [Fixtures.clip(start: 60, duration: 60)])]
        e.timelines[e.timelines.firstIndex(where: { $0.id == secondId })!] = second
        e.liveViewStates[secondId] = TimelineViewState(playheadFrame: 90)

        e.applyTimelineSettings(fps: 60, width: e.timeline.width, height: e.timeline.height)

        #expect(e.timelines.allSatisfy { $0.fps == 60 })
        #expect(e.timeline.tracks[0].clips[0].startFrame == 60)
        let rescaled = e.timeline(for: secondId)!
        #expect(rescaled.tracks[0].clips[0].startFrame == 120)
        #expect(rescaled.tracks[0].clips[0].durationFrames == 120)
        #expect(e.viewState(for: secondId).playheadFrame == 180)
    }
}

@Suite("Multi-timeline — persistence")
struct ProjectFilePersistenceTests {

    @Test func legacyBareTimelineDecodesAndWraps() throws {
        let legacy = Fixtures.timeline(fps: 24, tracks: [Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 10)])])
        let data = try JSONEncoder().encode(legacy)
        let file = try ProjectFile.decode(data)
        #expect(file.timelines.count == 1)
        #expect(file.timelines[0].fps == 24)
        #expect(file.activeTimelineId == file.timelines[0].id)
    }

    @Test func projectFileRoundTripsViewStateAndTabs() throws {
        var a = Fixtures.timeline()
        a.name = "Main"
        a.tracks = [Fixtures.videoTrack()]
        a.tracks[0].displayHeight = 88
        var b = Fixtures.timeline()
        b.name = "Vertical"
        let vs = TimelineViewState(playheadFrame: 42, zoomScale: 7, scrollOffsetX: 300)

        let file = ProjectFile(
            timelines: [a, b], activeTimelineId: b.id, openTimelineIds: [a.id, b.id],
            viewStates: [a.id: vs]
        )
        let decoded = try ProjectFile.decode(JSONEncoder().encode(file))

        #expect(decoded.timelines.map(\.name) == ["Main", "Vertical"])
        #expect(decoded.activeTimelineId == b.id)
        #expect(decoded.openTimelineIds == [a.id, b.id])
        #expect(decoded.viewStates?[a.id] == vs)
        #expect(decoded.timelines[0].tracks[0].displayHeight == 88)
    }

    @Test func legacyTimelineWithoutIdGetsOne() throws {
        // Hand-built legacy JSON lacking id/name/viewState keys entirely.
        let json = """
        {"fps": 30, "width": 1920, "height": 1080, "settingsConfigured": true, "tracks": []}
        """
        let file = try ProjectFile.decode(Data(json.utf8))
        #expect(!file.timelines[0].id.isEmpty)
        #expect(file.timelines[0].name == "Timeline 1")
        #expect(file.timelines[0].settingsConfigured)
    }

    @MainActor
    @Test func applyProjectFileValidatesActiveAndOpenIds() {
        let e = EditorViewModel()
        let a = Fixtures.timeline()
        let b = Fixtures.timeline()
        let file = ProjectFile(timelines: [a, b], activeTimelineId: "missing", openTimelineIds: ["missing", b.id])
        e.applyProjectFile(file)
        #expect(e.activeTimelineId == a.id)
        #expect(e.openTimelineIds == [b.id, a.id])
    }
}
