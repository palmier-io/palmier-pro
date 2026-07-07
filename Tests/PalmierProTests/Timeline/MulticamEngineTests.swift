import Foundation
import Testing
@testable import PalmierPro

@Suite("Multicam")
@MainActor
struct MulticamTests {

    private func harness() -> ToolHarness {
        let h = ToolHarness()
        h.addAsset(id: "camA", type: .video, duration: 120, hasAudio: true)
        h.addAsset(id: "camB", type: .video, duration: 110, hasAudio: true)
        h.addAsset(id: "mic1", type: .audio, duration: 130)
        return h
    }

    private func specs() -> [EditorViewModel.MulticamMemberSpec] {
        [
            .init(mediaRef: "camA", kind: .angle, angleLabel: "cam-a"),
            .init(mediaRef: "camB", kind: .angle, angleLabel: "cam-b"),
            .init(mediaRef: "mic1", kind: .mic, angleLabel: "mic-1"),
        ]
    }

    private func maps() -> [String: MulticamSource.SyncMap] {
        [
            "camA": .init(offsetSeconds: 0, confidence: 1),
            "camB": .init(offsetSeconds: 5, confidence: 0.9),
            "mic1": .init(offsetSeconds: 2, confidence: 1),
        ]
    }

    @discardableResult
    private func createGroup(_ h: ToolHarness, place: Bool = true) throws -> (childId: String, carrierIds: [String]) {
        try h.editor.createMulticamGroup(
            specs: specs(), syncMaps: maps(), masterRef: "mic1", name: "MC", place: place, startFrame: 0
        )
    }

    private func programClips(_ h: ToolHarness, _ childId: String) -> [Clip] {
        let child = h.editor.timeline(for: childId)!
        let idx = child.tracks.firstIndex { $0.id == child.multicam!.programTrackId }!
        return child.tracks[idx].clips
    }

    // MARK: - Model

    @Test func sourceRoundTripsThroughCodable() throws {
        let h = harness()
        let (childId, _) = try createGroup(h)
        let child = h.editor.timeline(for: childId)!
        let data = try JSONEncoder().encode(child)
        let decoded = try JSONDecoder().decode(Timeline.self, from: data)
        #expect(decoded.isMulticam)
        #expect(decoded.multicam == child.multicam)
    }

    @Test func legacyTimelineDecodesAsStandard() throws {
        let data = try JSONEncoder().encode(Fixtures.timeline())
        let decoded = try JSONDecoder().decode(Timeline.self, from: data)
        #expect(!decoded.isMulticam)
        #expect(decoded.multicam == nil)
    }

    @Test func lagSearchKeepsHalfOverlap() {
        // 3:35 files (~21500 hops) with a 240s window: without the clamp, ±220s lags
        // with seconds of overlap were legal — the false-peak that doubled a group's length.
        let clamped = MulticamEngine.maxLagHops(windowSeconds: 240, hopSeconds: 0.01, referenceCount: 21500, targetCount: 21500)
        #expect(clamped == 10750)
        // Long recordings keep the full requested window.
        let long = MulticamEngine.maxLagHops(windowSeconds: 240, hopSeconds: 0.01, referenceCount: 54000, targetCount: 54000)
        #expect(long == 24000)
        #expect(MulticamEngine.maxLagHops(windowSeconds: 240, hopSeconds: 0.01, referenceCount: 0, targetCount: 100) == 1)
    }

    @Test func trimDerivation() {
        let member = MulticamSource.Member(
            mediaRef: "m", kind: .angle, angleLabel: "a",
            sync: .init(offsetSeconds: 5.2, confidence: 1)
        )
        #expect(member.trimFrame(atChildFrame: 300, fps: 30) == 144)
        #expect(member.coverage(sourceDuration: 110, fps: 30) == 156..<3456)
    }

    @Test func duplicatedGroupRemapsEngineTrackIds() throws {
        let h = harness()
        let (childId, _) = try createGroup(h)
        _ = try h.editor.switchMulticamAngles(childId: childId, requests: [
            .init(range: 300..<900, layout: .sideBySide, slots: [("left", "cam-a"), ("right", "cam-b")], fit: .fill)
        ])
        let copyId = try #require(h.editor.duplicateTimeline(childId, activate: false))
        let copy = h.editor.timeline(for: copyId)!
        let source = try #require(copy.multicam)
        #expect(copy.tracks.contains { $0.id == source.programTrackId })
        for overlayId in source.overlayTrackIds {
            #expect(copy.tracks.contains { $0.id == overlayId })
        }
    }

    @Test func micMuteTogglesBedVolume() throws {
        let h = harness()
        let (childId, _) = try createGroup(h)
        let source = h.editor.timeline(for: childId)!.multicam!
        let mic1 = source.members.first { $0.mediaRef == "mic1" }!

        h.editor.setMulticamMemberMuted(childId: childId, memberId: mic1.id, muted: true)
        #expect(h.editor.multicamMemberMuted(child: h.editor.timeline(for: childId)!, member: mic1))
        h.editor.setMulticamMemberMuted(childId: childId, memberId: mic1.id, muted: false)
        #expect(!h.editor.multicamMemberMuted(child: h.editor.timeline(for: childId)!, member: mic1))
    }

    @Test func engineSplitPreservesKeyframesAndFades() throws {
        let h = harness()
        let (childId, _) = try createGroup(h)

        // Keyframe + fade the program clip inside the group (legal property edits).
        h.editor.activateTimeline(childId)
        let programId = h.editor.timeline.tracks[0].clips[0].id
        h.editor.mutateClips(ids: [programId], actionName: "KF") { clip in
            var track = KeyframeTrack<Double>()
            track.upsert(Keyframe(frame: 0, value: 1.0))
            track.upsert(Keyframe(frame: 1200, value: 0.2))
            clip.opacityTrack = track
            clip.fadeInFrames = 900
        }
        let parentId = h.editor.timelines.first { !$0.isMulticam }!.id
        h.editor.activateTimeline(parentId)

        // Switching splits at 600: right half must rebase keyframes and clamp fades.
        _ = try h.editor.switchMulticamAngles(childId: childId, requests: [
            .init(range: 600..<3600, layout: .full, slots: [("main", "cam-b")], fit: .fill)
        ])
        let program = programClips(h, childId)
        let left = program[0]
        #expect(left.fadeInFrames <= left.durationFrames)
        #expect(left.opacityTrack!.keyframes.allSatisfy { $0.frame <= left.durationFrames })
        let right = program[1]
        #expect(right.opacityTrack!.keyframes.allSatisfy { $0.frame >= 0 && $0.frame <= right.durationFrames })
    }

    @Test func sequenceTrimsAreUnbounded() throws {
        let h = harness()
        let (_, carrierIds) = try createGroup(h)
        let visual = carrierIds.compactMap { h.editor.clipFor(id: $0) }.first { $0.mediaType == .sequence }!
        // Extending the right edge reaches the audio-only tail via a negative tail trim.
        let values = h.editor.trimValues(for: visual, edge: .right, delta: 60)
        #expect(values.trimEnd == -60)
    }

    // MARK: - Creation

    @Test func createBuildsChildAndCarrierPair() throws {
        let h = harness()
        let (childId, carrierIds) = try createGroup(h)

        let child = h.editor.timeline(for: childId)!
        #expect(child.isMulticam)
        let source = try #require(child.multicam)
        #expect(source.members.count == 3)
        #expect(source.master?.angleLabel == "mic-1")

        // camA covers 0..<3600; mic1 offset 2s → child frames 60..<3960.
        let program = programClips(h, childId)
        #expect(program.count == 1)
        #expect(program[0].mediaRef == "camA")
        #expect(program[0].startFrame == 0 && program[0].durationFrames == 3600)
        let micTrack = child.tracks.first { $0.type == .audio }!
        #expect(micTrack.clips[0].startFrame == 60 && micTrack.clips[0].durationFrames == 3900)

        // One linked visual+audio carrier pair, spanning video coverage (0..<3600) —
        // the mic's audio-only tail (to 3960) stays inside the group.
        let carriers = carrierIds.compactMap { h.editor.clipFor(id: $0) }
        #expect(carriers.count == 2)
        #expect(Set(carriers.map(\.mediaType)) == [.sequence, .audio])
        #expect(child.totalFrames == 3960)
        #expect(carriers.allSatisfy { $0.trimStartFrame == 0 && $0.durationFrames == 3600 })
        #expect(Set(carriers.compactMap(\.linkGroupId)).count == 1)
    }

    @Test func placedClipSpansVideoCoverageOnly() throws {
        let h = ToolHarness()
        h.addAsset(id: "camA", type: .video, duration: 120, hasAudio: true)
        h.addAsset(id: "mic1", type: .audio, duration: 130)
        let maps: [String: MulticamSource.SyncMap] = [
            "camA": .init(offsetSeconds: 4, confidence: 1),
            "mic1": .init(offsetSeconds: 0, confidence: 1),
        ]
        let (childId, carrierIds) = try h.editor.createMulticamGroup(
            specs: [.init(mediaRef: "camA", kind: .angle, angleLabel: "cam-a"),
                    .init(mediaRef: "mic1", kind: .mic, angleLabel: "mic-1")],
            syncMaps: maps, masterRef: "mic1", name: nil, place: true, startFrame: 0
        )
        // Mic spans child 0..<3900; the camera 120..<3720 — the clip shows only picture.
        #expect(h.editor.timeline(for: childId)!.totalFrames == 3900)
        let carriers = carrierIds.compactMap { h.editor.clipFor(id: $0) }
        #expect(carriers.allSatisfy { $0.trimStartFrame == 120 && $0.durationFrames == 3600 })
    }

    @Test func childOpensWithAxisEditsLocked() throws {
        let h = harness()
        let (childId, _) = try createGroup(h)
        let parentId = h.editor.activeTimelineId
        h.editor.activateTimeline(childId)
        #expect(h.editor.activeTimelineId == childId)
        let before = h.editor.timeline(for: childId)!
        let programClipId = before.tracks[0].clips[0].id

        // Axis-moving edits refuse…
        if case .ok = h.editor.rippleDeleteRangesOnTrack(trackIndex: 0, ranges: [FrameRange(start: 0, end: 30)]) {
            Issue.record("ripple must refuse inside a multicam child")
        }
        h.editor.commitClipSpeed(ids: [programClipId], newSpeed: 2)
        h.editor.moveClips([(clipId: programClipId, toTrack: 0, toFrame: 100)])
        #expect(h.editor.timeline(for: childId)! == before)

        // …axis-preserving edits are free: property, trim, delete-with-gap.
        let micId = before.tracks.first { $0.type == .audio }!.clips[0].id
        h.editor.mutateClips(ids: [micId], actionName: "Volume") { $0.volume = 0.5 }
        #expect(h.editor.timeline(for: childId)!.tracks.first { $0.type == .audio }!.clips[0].volume == 0.5)

        h.editor.trimClips([(clipId: programClipId, trimStartFrame: 30, trimEndFrame: 0)])
        let trimmed = h.editor.timeline(for: childId)!.tracks[0].clips[0]
        #expect(trimmed.trimStartFrame == 30 && trimmed.startFrame == 30)

        h.editor.removeClips(ids: [programClipId])
        let child = h.editor.timeline(for: childId)!
        #expect(child.tracks[0].clips.isEmpty)
        // Engine-managed tracks survive emptying (no prune inside groups).
        #expect(child.tracks[0].id == child.multicam!.programTrackId)

        h.editor.activateTimeline(parentId)
        #expect(h.editor.activeTimelineId == parentId)
    }

    @Test func unsyncedMembersAreReportedAndUnusable() throws {
        let h = harness()
        var m = maps()
        m["camB"] = MulticamSource.SyncMap()
        let (childId, _) = try h.editor.createMulticamGroup(
            specs: specs(), syncMaps: m, masterRef: "mic1", name: nil, place: true, startFrame: 0
        )
        let source = h.editor.timeline(for: childId)!.multicam!
        #expect(source.angles.map(\.angleLabel) == ["cam-a"])
        #expect(
            throws: ToolError.self,
            performing: {
                try h.editor.switchMulticamAngles(childId: childId, requests: [
                    .init(range: 0..<100, layout: .full, slots: [("main", "cam-b")], fit: .fill)
                ])
            }
        )
    }

    // MARK: - Switching

    @Test func switchRewritesRangeAndPreservesContentTime() throws {
        let h = harness()
        let (childId, _) = try createGroup(h)
        let report = try h.editor.switchMulticamAngles(childId: childId, requests: [
            .init(range: 600..<1200, layout: .full, slots: [("main", "cam-b")], fit: .fill)
        ])
        #expect(report.applied == [[600, 1200]])

        let program = programClips(h, childId)
        #expect(program.map(\.mediaRef) == ["camA", "camB", "camA"])
        #expect(program.map(\.startFrame) == [0, 600, 1200])
        #expect(program.map(\.endFrame) == [600, 1200, 3600])
        // camB offset 5s → source position at child frame 600 is (20 − 5)s = frame 450.
        #expect(program[1].trimStartFrame == 450)
        // camA halves stay source-continuous across the swap.
        #expect(program[2].trimStartFrame == 1200)
    }

    @Test func switchBackMergesToOneClip() throws {
        let h = harness()
        let (childId, _) = try createGroup(h)
        _ = try h.editor.switchMulticamAngles(childId: childId, requests: [
            .init(range: 600..<1200, layout: .full, slots: [("main", "cam-b")], fit: .fill)
        ])
        let report = try h.editor.switchMulticamAngles(childId: childId, requests: [
            .init(range: 600..<1200, layout: .full, slots: [("main", "cam-a")], fit: .fill)
        ])
        #expect(report.merged == 2)
        #expect(programClips(h, childId).count == 1)
    }

    @Test func switchClampsToCoverageWithCulprit() throws {
        let h = harness()
        let (childId, _) = try createGroup(h)
        // camB starts at child frame 150 (5s offset).
        let report = try h.editor.switchMulticamAngles(childId: childId, requests: [
            .init(range: 0..<600, layout: .full, slots: [("main", "cam-b")], fit: .fill)
        ])
        #expect(report.clamped.count == 1)
        #expect(report.clamped[0].applied == [150, 600])
        #expect(report.clamped[0].culprit == "cam-b")
        let program = programClips(h, childId)
        #expect(program.map(\.mediaRef) == ["camA", "camB", "camA"])
        #expect(program[1].startFrame == 150)
        #expect(program[1].trimStartFrame == 0)
    }

    @Test func uncoveredRangeIsSkippedWithoutEdits() throws {
        let h = harness()
        let (childId, _) = try createGroup(h)
        let before = programClips(h, childId)
        let report = try h.editor.switchMulticamAngles(childId: childId, requests: [
            .init(range: 0..<100, layout: .full, slots: [("main", "cam-b")], fit: .fill)
        ])
        #expect(report.skipped.count == 1)
        #expect(report.applied.isEmpty)
        #expect(programClips(h, childId) == before)
    }

    @Test func batchedRequestsApplyInOneUndoStep() throws {
        let h = harness()
        let (childId, _) = try createGroup(h)
        let before = h.editor.timeline(for: childId)!
        let undo = UndoManager()
        undo.groupsByEvent = false
        h.editor.undoManager = undo

        undo.beginUndoGrouping()
        _ = try h.editor.switchMulticamAngles(childId: childId, requests: [
            .init(range: 300..<600, layout: .full, slots: [("main", "cam-b")], fit: .fill),
            .init(range: 900..<1500, layout: .full, slots: [("main", "cam-b")], fit: .fill),
        ])
        undo.endUndoGrouping()
        #expect(programClips(h, childId).count == 5)

        let activeBefore = h.editor.activeTimelineId
        undo.undo()
        #expect(h.editor.timeline(for: childId) == before)
        #expect(h.editor.activeTimelineId == activeBefore)
    }

    // MARK: - Layouts

    @Test func layoutPlacesOverlayAndFullClearsIt() throws {
        let h = harness()
        let (childId, _) = try createGroup(h)
        _ = try h.editor.switchMulticamAngles(childId: childId, requests: [
            .init(range: 300..<900, layout: .sideBySide,
                  slots: [("left", "cam-a"), ("right", "cam-b")], fit: .fill)
        ])
        var child = h.editor.timeline(for: childId)!
        var source = child.multicam!
        #expect(source.overlayTrackIds.count == 1)
        let overlayIdx = child.tracks.firstIndex { $0.id == source.overlayTrackIds[0] }!
        let programIdx = child.tracks.firstIndex { $0.id == source.programTrackId }!
        #expect(overlayIdx < programIdx)
        let overlay = child.tracks[overlayIdx].clips
        #expect(overlay.count == 1)
        #expect(overlay[0].mediaRef == "camB")
        #expect(overlay[0].startFrame == 300 && overlay[0].endFrame == 900)
        #expect(abs(overlay[0].transform.topLeft.x - 0.5) < 1e-9)

        _ = try h.editor.switchMulticamAngles(childId: childId, requests: [
            .init(range: 300..<900, layout: .full, slots: [("main", "cam-a")], fit: .fill)
        ])
        child = h.editor.timeline(for: childId)!
        source = child.multicam!
        let cleared = child.tracks.first { $0.id == source.overlayTrackIds[0] }!
        #expect(cleared.clips.isEmpty)
        #expect(programClips(h, childId).count == 1)
    }

    @Test func audioCarrierBearsMasterMic() throws {
        let h = harness()
        let (_, carrierIds) = try createGroup(h)
        let audio = carrierIds.compactMap { h.editor.clipFor(id: $0) }.first { $0.mediaType == .audio }!
        let bearer = h.editor.audioBearer(for: audio)
        #expect(bearer.mediaRef == "mic1")
        #expect(bearer.id == audio.id)
        #expect(bearer.startFrame == audio.startFrame)
        // mic-1 sits 2 s into group time → its source is 60 frames behind child frames @30 fps.
        #expect(bearer.trimStartFrame == audio.trimStartFrame - 60)
        // Non-multicam clips pass through untouched.
        let plain = Fixtures.clip(start: 0, duration: 10)
        #expect(h.editor.audioBearer(for: plain) == plain)
    }

    @Test func renderSegmentsProjectAngleCuts() throws {
        let h = harness()
        let (childId, carrierIds) = try createGroup(h)
        _ = try h.editor.switchMulticamAngles(childId: childId, requests: [
            .init(range: 600..<1200, layout: .full, slots: [("main", "cam-b")], fit: .fill)
        ])
        let visual = carrierIds.compactMap { h.editor.clipFor(id: $0) }.first { $0.mediaType == .sequence }!
        let segments = try #require(h.editor.multicamRenderSegments(for: visual))
        #expect(segments.map(\.label) == ["cam-a", "cam-b", "cam-a"])
        #expect(segments.map(\.clip.mediaRef) == ["camA", "camB", "camA"])
        #expect(segments[1].clip.startFrame == 600 && segments[1].clip.durationFrames == 600)
        #expect(segments[1].clip.trimStartFrame == 450)
        #expect(h.editor.clipDisplayLabel(for: visual) == "MC")
    }

    // MARK: - Parent mapping

    @Test func switchMapsThroughTrimmedCarrierFragments() throws {
        let h = harness()
        let (childId, carrierIds) = try createGroup(h)
        let visual = carrierIds.compactMap { h.editor.clipFor(id: $0) }.first { $0.mediaType == .sequence }!

        // Simulate a word cut: split the carrier and ripple the right half left.
        _ = h.editor.splitClip(clipId: visual.id, atFrame: 900)
        let rightId = h.editor.timeline.tracks.flatMap(\.clips)
            .first { $0.mediaRef == childId && $0.mediaType == .sequence && $0.startFrame == 900 }!.id
        _ = h.editor.rippleDeleteRangesOnTrack(trackIndex: h.editor.findClip(id: rightId)!.trackIndex, ranges: [FrameRange(start: 600, end: 900)])

        // Parent 700 now shows child frame 1000 (trim 900, start 600).
        _ = try h.editor.switchMulticamAngles(childId: childId, requests: [
            .init(range: 700..<1000, layout: .full, slots: [("main", "cam-b")], fit: .fill)
        ])
        let program = programClips(h, childId)
        let swapped = program.first { $0.mediaRef == "camB" }!
        #expect(swapped.startFrame == 1000 && swapped.endFrame == 1300)

        let rows = h.editor.multicamProgramRows(childId: childId)
        #expect(rows.contains { ($0[0] as? String) == "cam-b" && ($0[1] as? Int) == 700 && ($0[2] as? Int) == 1000 })
    }

    @Test func wordCutOnParentLeavesChildUntouched() throws {
        let h = harness()
        let (childId, carrierIds) = try createGroup(h)
        let childBefore = h.editor.timeline(for: childId)!
        let visual = carrierIds.compactMap { h.editor.clipFor(id: $0) }.first { $0.mediaType == .sequence }!
        let track = h.editor.findClip(id: visual.id)!.trackIndex

        _ = h.editor.rippleDeleteRangesOnTrack(trackIndex: track, ranges: [FrameRange(start: 300, end: 450)])

        #expect(h.editor.timeline(for: childId)! == childBefore)
        let fragments = h.editor.multicamCarriers(of: childId)
        #expect(fragments.count == 2)
        #expect(fragments[1].trimStartFrame == 450)
    }
}
