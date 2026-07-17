import Foundation
import Testing
@testable import PalmierPro

@Suite("Multicam")
@MainActor
struct MulticamTests {

    // Group clock at 30fps: camA covers [0, 3600), camB [150, 3450), mic1 (master) [60, 3960).
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
    private func createGroup(_ h: ToolHarness) throws -> (groupId: String, clipIds: [String]) {
        try h.editor.createMulticamGroup(
            specs: specs(), syncMaps: maps(), masterRef: "mic1", name: "MC", startFrame: 0
        )
    }

    private func programClips(_ h: ToolHarness, _ groupId: String) -> [Clip] {
        h.editor.multicamClips(of: groupId)
            .filter { h.editor.timeline.tracks[$0.trackIndex].type == .video }
            .map(\.clip).sorted { $0.startFrame < $1.startFrame }
    }

    private func micClip(_ h: ToolHarness, _ groupId: String) -> Clip {
        h.editor.multicamClips(of: groupId).first { $0.clip.mediaType == .audio }!.clip
    }

    // MARK: - Model

    @Test func groupMetadataRoundTripsThroughProjectFile() throws {
        var group = MulticamSource(name: "Pod", members: [
            .init(mediaRef: "a", kind: .both, angleLabel: "host",
                  sync: .init(offsetSeconds: 1.5, confidence: 0.91)),
        ])
        group.masterMemberId = group.members[0].id
        var timeline = Fixtures.timeline()
        timeline.tracks = [Track(type: .video)]
        var stamped = Clip(mediaRef: "a", startFrame: 0, durationFrames: 10)
        stamped.multicamGroupId = group.id
        timeline.tracks[0].clips = [stamped]
        let file = ProjectFile(timelines: [timeline], multicamGroups: [group])
        let decoded = try ProjectFile.decode(JSONEncoder().encode(file))
        #expect(decoded.multicamGroups == [group])
    }

    @Test func clipStampSurvivesCodingAndLegacyDecodesNil() throws {
        var clip = Clip(mediaRef: "m", startFrame: 0, durationFrames: 10)
        clip.multicamGroupId = "g1"
        let decoded = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(clip))
        #expect(decoded.multicamGroupId == "g1")
        let plain = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(Clip(mediaRef: "m", startFrame: 0, durationFrames: 10)))
        #expect(plain.multicamGroupId == nil)
    }

    @Test func freshenIdsPreservesStampVerbatim() {
        var clip = Clip(mediaRef: "m", startFrame: 0, durationFrames: 10)
        clip.multicamGroupId = "g1"
        clip.linkGroupId = "L1"
        var groups: [String: String] = [:]
        clip.freshenIds(groups: &groups)
        #expect(clip.multicamGroupId == "g1")
        #expect(clip.linkGroupId != "L1")
    }

    @Test func lagSearchKeepsHalfOverlap() {
        // 3:35 files (~21500 hops) with a 240s window: without the clamp, ±220s lags
        // with seconds of overlap were legal — the false-peak that doubled a group's length.
        let clamped = MulticamEngine.maxLagHops(windowSeconds: 240, hopSeconds: 0.01, referenceCount: 21500, targetCount: 21500)
        #expect(clamped == 10750)
        let long = MulticamEngine.maxLagHops(windowSeconds: 240, hopSeconds: 0.01, referenceCount: 54000, targetCount: 54000)
        #expect(long == 24000)
        #expect(MulticamEngine.maxLagHops(windowSeconds: 240, hopSeconds: 0.01, referenceCount: 0, targetCount: 100) == 1)
    }

    // MARK: - Creation

    @Test func createFillsProgramHolesWithCoveringAngles() throws {
        // Seed camera stops early; a longer angle must fill the tail —
        // no gap where some camera has picture.
        let h = ToolHarness()
        h.addAsset(id: "short", type: .video, duration: 20, hasAudio: true)
        h.addAsset(id: "wide", type: .video, duration: 120, hasAudio: true)
        h.addAsset(id: "mic1", type: .audio, duration: 130)
        let (groupId, _) = try h.editor.createMulticamGroup(
            specs: [
                .init(mediaRef: "short", kind: .angle, angleLabel: "close"),
                .init(mediaRef: "wide", kind: .angle, angleLabel: "wide"),
                .init(mediaRef: "mic1", kind: .mic, angleLabel: "mic-1"),
            ],
            syncMaps: [
                "short": .init(offsetSeconds: 0, confidence: 1),
                "wide": .init(offsetSeconds: 0, confidence: 1),
                "mic1": .init(offsetSeconds: 0, confidence: 1),
            ],
            masterRef: "mic1", name: "MC", startFrame: 0
        )
        let program = programClips(h, groupId)
        #expect(program.map(\.mediaRef) == ["short", "wide"])
        #expect(program[0].endFrame == 600)
        #expect(program[1].startFrame == 600 && program[1].endFrame == 3600)
        // The filler shows its own source at the right moment, not from zero.
        #expect(program[1].trimStartFrame == 600)
    }

    @Test func createLaysStampedClips() throws {
        let h = harness()
        let (groupId, clipIds) = try createGroup(h)
        #expect(clipIds.count == 2)

        let program = programClips(h, groupId)
        #expect(program.count == 1)
        // Video spans the union of camera coverage.
        #expect(program[0].startFrame == 0 && program[0].endFrame == 3600)
        #expect(program[0].mediaRef == "camA")
        #expect(program[0].multicamGroupId == groupId)
        #expect(h.editor.multicamAngleLabel(for: program[0]) == "cam-a")

        // Mic is its own audio clip at its offset — stamped, not linked:
        // clips select and delete individually.
        let mic = micClip(h, groupId)
        #expect(mic.startFrame == 60 && mic.durationFrames == 3900)
        #expect(mic.trimStartFrame == 0)
        #expect(mic.linkGroupId == nil)

        #expect(h.editor.multicamGroup(id: groupId)?.name == "MC")
    }

    @Test func createUndoDropsClipsAndMetadata() throws {
        let h = harness()
        let undoManager = UndoManager()
        h.editor.undo.attach(undoManager)
        let (groupId, _) = try createGroup(h)
        undoManager.undo()
        #expect(h.editor.multicamClips(of: groupId).isEmpty)
        #expect(h.editor.multicamGroup(id: groupId) == nil)
        undoManager.redo()
        #expect(h.editor.multicamGroup(id: groupId) != nil)
        #expect(h.editor.multicamClips(of: groupId).count == 2)
    }

    @Test func switchMicRewritesAudioClipInPlace() throws {
        let h = ToolHarness()
        h.addAsset(id: "camA", type: .video, duration: 120, hasAudio: true)
        h.addAsset(id: "lapel", type: .audio, duration: 130)
        h.addAsset(id: "room", type: .audio, duration: 125)
        let (groupId, _) = try h.editor.createMulticamGroup(
            specs: [
                .init(mediaRef: "camA", kind: .angle, angleLabel: "cam-a"),
                .init(mediaRef: "lapel", kind: .mic, angleLabel: "lapel"),
                .init(mediaRef: "room", kind: .mic, angleLabel: "room"),
            ],
            syncMaps: [
                "camA": .init(offsetSeconds: 0, confidence: 1),
                "lapel": .init(offsetSeconds: 2, confidence: 1),
                "room": .init(offsetSeconds: 0, confidence: 1),
            ],
            masterRef: "lapel", name: "MC", startFrame: 0
        )
        // Chop the lapel lane, then switch just the middle piece to the room mic.
        let lapel = h.editor.multicamClips(of: groupId).first { $0.clip.mediaRef == "lapel" }!.clip
        _ = h.editor.splitClip(clipId: lapel.id, atFrame: 600)
        let mid = h.editor.multicamClips(of: groupId).first { $0.clip.mediaRef == "lapel" && $0.clip.startFrame == 600 }!.clip
        _ = h.editor.splitClip(clipId: mid.id, atFrame: 1200)
        let target = h.editor.multicamClips(of: groupId).first { $0.clip.mediaRef == "lapel" && $0.clip.startFrame == 600 }!.clip

        h.editor.switchMulticamSegment(clipId: target.id, to: "room")
        let swapped = h.editor.clipFor(id: target.id)!
        #expect(swapped.mediaRef == "room")
        // Same real moment on the room mic's clock: lapel trim 540 + 2s·30.
        #expect(swapped.trimStartFrame == 600)
        #expect(swapped.startFrame == 600 && swapped.endFrame == 1200)
        // Neighbors untouched.
        #expect(h.editor.multicamClips(of: groupId).map(\.clip).filter { $0.mediaRef == "lapel" }.count == 2)
    }

    // MARK: - Switching

    @Test func switchRewritesTrimThroughSyncMaps() throws {
        let h = harness()
        let (groupId, _) = try createGroup(h)
        let outcome = try h.editor.switchMulticamAngles(groupId: groupId, requests: [
            .init(range: 600..<1200, angle: "cam-b"),
        ])
        #expect(outcome.switched == 1)
        let clips = programClips(h, groupId)
        #expect(clips.map(\.mediaRef) == ["camA", "camB", "camA"])
        // Same real moment on cam-b's clock: 600 - (5-0)*30 = 450.
        #expect(clips[1].trimStartFrame == 450)
        #expect(clips[1].startFrame == 600 && clips[1].endFrame == 1200)
        #expect(clips[0].trimStartFrame == 0)
        #expect(clips[2].trimStartFrame == 1200)
        #expect(clips.allSatisfy { $0.multicamGroupId == groupId })
    }

    @Test func switchClampsToAngleCoverage() throws {
        let h = harness()
        let (groupId, _) = try createGroup(h)
        // cam-b has no picture before group frame 150.
        let outcome = try h.editor.switchMulticamAngles(groupId: groupId, requests: [
            .init(range: 0..<600, angle: "cam-b"),
        ])
        #expect(outcome.clamped.count == 1)
        #expect(outcome.clamped[0].applied == 150..<600)
        #expect(outcome.clamped[0].culprit == "cam-b")
        let clips = programClips(h, groupId)
        #expect(clips.map(\.mediaRef) == ["camA", "camB", "camA"])
        #expect(clips[1].startFrame == 150)
    }

    @Test func userFramingSurvivesAngleSwitch() throws {
        let h = harness()
        let (groupId, _) = try createGroup(h)

        // Cut a fragment out, then punch in on just that fragment.
        let program = programClips(h, groupId)[0]
        _ = h.editor.splitClip(clipId: program.id, atFrame: 600)
        let fragment = programClips(h, groupId).first { $0.startFrame == 600 }!
        _ = h.editor.splitClip(clipId: fragment.id, atFrame: 1200)
        var punched = Transform()
        punched.width = 1.2
        punched.height = 1.2
        let framed = programClips(h, groupId).first { $0.startFrame == 600 }!
        h.editor.mutateClips(ids: [framed.id], actionName: "Frame") {
            $0.transform = punched
            $0.crop = Crop(left: 0.1, top: 0, right: 0, bottom: 0)
        }

        // The punch-in rides the swap; the crop is untouched.
        _ = try h.editor.switchMulticamAngles(groupId: groupId, requests: [
            .init(range: 600..<1200, angle: "cam-b"),
        ])
        let swapped = programClips(h, groupId).first { $0.startFrame == 600 }!
        #expect(swapped.mediaRef == "camB")
        #expect(swapped.transform == punched)
        #expect(swapped.crop == Crop(left: 0.1, top: 0, right: 0, bottom: 0))

        // An unframed fragment stays at the default fit after switching.
        _ = try h.editor.switchMulticamAngles(groupId: groupId, requests: [
            .init(range: 1500..<1800, angle: "cam-b"),
        ])
        let plain = programClips(h, groupId).first { $0.startFrame == 1500 }!
        #expect(plain.crop == Crop())
    }

    @Test func sameAngleSwitchMergesBack() throws {
        let h = harness()
        let (groupId, _) = try createGroup(h)
        _ = try h.editor.switchMulticamAngles(groupId: groupId, requests: [
            .init(range: 600..<1200, angle: "cam-b"),
        ])
        let back = try h.editor.switchMulticamAngles(groupId: groupId, requests: [
            .init(range: 600..<1200, angle: "cam-a"),
        ])
        #expect(back.merged == 2)
        #expect(programClips(h, groupId).count == 1)
    }

    @Test func switchSurvivesWordCutFragments() throws {
        let h = harness()
        let (groupId, _) = try createGroup(h)
        // A word cut: ripple out [900, 1000) — the whole group shifts atomically.
        guard case .ok = h.editor.rippleDeleteRangesOnTrack(trackIndex: 0, ranges: [FrameRange(start: 900, end: 1000)]) else {
            Issue.record("ripple refused")
            return
        }
        // Switch across the seam.
        let outcome = try h.editor.switchMulticamAngles(groupId: groupId, requests: [
            .init(range: 800..<1100, angle: "cam-b"),
        ])
        #expect(outcome.switched == 2)
        let swapped = programClips(h, groupId).filter { $0.mediaRef == "camB" }
        // Each fragment shows cam-b at the same real time its camA content had:
        // before the seam camA trim 800 → camB 650; after it camA trim 1000 → camB 850.
        #expect(swapped.contains { $0.startFrame == 800 && $0.trimStartFrame == 650 })
        #expect(swapped.contains { $0.trimStartFrame == 850 })
    }

    @Test func switchOutsideGroupSkips() throws {
        let h = harness()
        let (groupId, _) = try createGroup(h)
        let outcome = try h.editor.switchMulticamAngles(groupId: groupId, requests: [
            .init(range: 90000..<90600, angle: "cam-b"),
        ])
        #expect(outcome.switched == 0)
        #expect(outcome.skipped.count == 1)
    }

    // MARK: - Lifecycle

    @Test func ungroupStripsStampsAndDropsMetadata() throws {
        let h = harness()
        let (groupId, clipIds) = try createGroup(h)
        h.editor.ungroupMulticam(groupId: groupId)
        #expect(h.editor.multicamClips(of: groupId).isEmpty)
        #expect(h.editor.multicamGroup(id: groupId) == nil)
        // Clips stay put as ordinary clips.
        let survivors = h.editor.timeline.tracks.flatMap(\.clips).filter { clipIds.contains($0.id) }
        #expect(survivors.count == clipIds.count)
        #expect(survivors.allSatisfy { $0.multicamGroupId == nil })
    }

    @Test func unreferencedGroupsDontPersist() throws {
        let h = harness()
        let (groupId, clipIds) = try createGroup(h)
        #expect(h.editor.savedMulticamGroups()?.count == 1)
        h.editor.removeClips(ids: Set(clipIds))
        // Metadata stays in memory for undo, but is filtered from saves.
        #expect(h.editor.multicamGroup(id: groupId) != nil)
        #expect(h.editor.savedMulticamGroups() == nil)
    }

    // MARK: - Guardrails

    @Test func partialRippleAcrossGroupRefuses() throws {
        let h = harness()
        let (groupId, _) = try createGroup(h)
        // Sever the A/V link so linked-partner expansion can't save us — the stamp guard must.
        for (ti, clip) in h.editor.multicamClips(of: groupId) {
            let ci = h.editor.timeline.tracks[ti].clips.firstIndex { $0.id == clip.id }!
            h.editor.timeline.tracks[ti].clips[ci].linkGroupId = nil
        }
        let micTrack = h.editor.multicamClips(of: groupId).first { $0.clip.mediaType == .audio }!.trackIndex
        let programTrack = h.editor.multicamClips(of: groupId).first { $0.clip.mediaType != .audio }!.trackIndex
        // Unlock the program track so only the mic would shift — must refuse.
        let outcome = h.editor.rippleDeleteRangesOnTrack(
            trackIndex: micTrack, ranges: [FrameRange(start: 300, end: 400)],
            ignoreSyncLockTrackIndices: [programTrack]
        )
        guard case .refused(let reason) = outcome else {
            Issue.record("expected refusal")
            return
        }
        #expect(reason.localizedCaseInsensitiveContains("multicam"))
        #expect(h.editor.mediaPanelToast?.message.localizedCaseInsensitiveContains("multicam") == true)
    }

    @Test func atomicRippleKeepsRelativeAlignment() throws {
        let h = harness()
        let (groupId, _) = try createGroup(h)
        guard case .ok = h.editor.rippleDeleteRangesOnTrack(trackIndex: 0, ranges: [FrameRange(start: 300, end: 400)]) else {
            Issue.record("ripple refused")
            return
        }
        let program = programClips(h, groupId)
        // Fragment after the cut resumes at source 400 — content at a position never changed.
        #expect(program.first { $0.startFrame == 300 }?.trimStartFrame == 400)
        // The mic carries the same 100-frame cut: both sides of the seam keep
        // source-time = group-time - offset.
        let micFragments = h.editor.multicamClips(of: groupId).map(\.clip)
            .filter { $0.mediaType == .audio }.sorted { $0.startFrame < $1.startFrame }
        #expect(micFragments.count == 2)
        #expect(micFragments[1].startFrame == 300)
        // mic offset is 2s (60 frames): group 400 → mic source 340.
        #expect(micFragments[1].trimStartFrame == 340)
    }

    @Test func partialMoveRefused() throws {
        let h = harness()
        let (groupId, _) = try createGroup(h)
        let program = programClips(h, groupId)[0]
        let before = program.startFrame
        // Horizontal shift of a subset must not land.
        h.editor.moveClips([(clipId: program.id, toTrack: 0, toFrame: before + 500)])
        #expect(programClips(h, groupId)[0].startFrame == before)
    }

    @Test func speedRefusedOnStampedClips() throws {
        let h = harness()
        let (groupId, _) = try createGroup(h)
        let clip = programClips(h, groupId)[0]
        h.editor.commitClipSpeed(ids: [clip.id], newSpeed: 2.0)
        #expect(programClips(h, groupId)[0].speed == 1.0)
    }

    @Test func splitAndDeleteStayFree() throws {
        let h = harness()
        let (groupId, _) = try createGroup(h)
        let clip = programClips(h, groupId)[0]
        _ = h.editor.splitClip(clipId: clip.id, atFrame: 600)
        var clips = programClips(h, groupId)
        #expect(clips.count == 2)
        #expect(clips.allSatisfy { $0.multicamGroupId == groupId })
        h.editor.removeClips(ids: [clips[1].id])
        clips = programClips(h, groupId)
        #expect(clips.count == 1)
    }

    @Test func manualRippleRefusedOnlyWhenStraddlingGroup() throws {
        let h = harness()
        let (groupId, _) = try createGroup(h)
        let program = programClips(h, groupId)[0]
        _ = h.editor.splitClip(clipId: program.id, atFrame: 600)
        let left = programClips(h, groupId)[0]

        // Deleting the first fragment shifts through the mic's middle — refused.
        let before = programClips(h, groupId).map(\.startFrame)
        h.editor.selectedClipIds = [left.id]
        h.editor.rippleDeleteSelectedClips()
        #expect(programClips(h, groupId).map(\.startFrame) == before)
        #expect(h.editor.mediaPanelToast?.message.localizedCaseInsensitiveContains("multicam") == true)

        // Ripple trim mid-group straddles the mic — refused.
        h.editor.mediaPanelToast = nil
        h.editor.rippleTrimClip(clipId: left.id, edge: .right, deltaFrames: -60, propagateToLinked: false)
        #expect(programClips(h, groupId).map(\.startFrame) == before)
        #expect(h.editor.mediaPanelToast?.message.localizedCaseInsensitiveContains("multicam") == true)

        // Range ripples (remove_silence / remove_words) stay allowed.
        guard case .ok = h.editor.rippleDeleteRangesOnTrack(trackIndex: 0, ranges: [FrameRange(start: 100, end: 200)]) else {
            Issue.record("range ripple should pass")
            return
        }
    }

    @Test func manualRippleAfterGroupStaysAllowed() throws {
        let h = harness()
        let (groupId, _) = try createGroup(h)
        // Plain clip entirely after the group; deleting it shifts everything
        // after — including nothing of the group — so it must pass.
        h.editor.addClips(assets: [h.editor.mediaAssets.first { $0.id == "camA" }!], trackIndex: 0, startFrame: 5000)
        let stray = h.editor.timeline.tracks.flatMap(\.clips).first { $0.multicamGroupId == nil && $0.startFrame == 5000 }!
        let groupBefore = programClips(h, groupId).map(\.startFrame)
        h.editor.selectedClipIds = [stray.id]
        h.editor.rippleDeleteSelectedClips()
        #expect(h.editor.clipFor(id: stray.id) == nil)
        #expect(programClips(h, groupId).map(\.startFrame) == groupBefore)
    }

    @Test func angleSwitchLeavesUnrelatedUpperTrackClipsWhole() throws {
        let h = harness()
        h.addAsset(id: "title", type: .video, duration: 60)
        let (groupId, _) = try createGroup(h)
        let titleAsset = h.editor.mediaAssets.first { $0.id == "title" }!
        _ = h.editor.insertTrack(at: 0, type: .video)
        h.editor.addClips(assets: [titleAsset], trackIndex: 0, startFrame: 100)
        let titleCount = { h.editor.timeline.tracks.flatMap(\.clips).filter { $0.mediaRef == "title" }.count }
        #expect(titleCount() == 1)

        _ = try h.editor.switchMulticamAngles(groupId: groupId, requests: [
            .init(range: 300..<900, angle: "cam-b"),
        ])
        #expect(titleCount() == 1)
    }

    @Test func duplicateDropsStamp() throws {
        let h = harness()
        let (groupId, _) = try createGroup(h)
        let program = programClips(h, groupId)[0]
        let trackIdx = h.editor.multicamClips(of: groupId).first { $0.clip.id == program.id }!.trackIndex
        h.editor.duplicateClipsToPositions([(clipId: program.id, toTrack: trackIdx, toFrame: 9000)])
        let clone = h.editor.timeline.tracks.flatMap(\.clips).first { $0.startFrame == 9000 }
        #expect(clone != nil)
        #expect(clone?.multicamGroupId == nil)
    }

    @Test func overwriteTrimClearsWhatItCovers() throws {
        let h = harness()
        let (groupId, _) = try createGroup(h)
        let program = programClips(h, groupId)[0]
        _ = h.editor.splitClip(clipId: program.id, atFrame: 600)
        var clips = programClips(h, groupId)
        let left = clips[0], right = clips[1]

        // Shrink the right clip's head, then extend the left clip over the gap:
        // the growth must overwrite (trim) the right neighbor, not stack on it.
        h.editor.commitTrim(clipId: right.id, edge: .left, deltaFrames: 90, propagateToLinked: false)
        h.editor.commitTrim(clipId: left.id, edge: .right, deltaFrames: 150, propagateToLinked: false)

        clips = programClips(h, groupId)
        #expect(clips.count == 2)
        #expect(clips[0].endFrame == 750)
        #expect(clips[1].startFrame == 750)
    }

    @Test func trimStopsAtRippleSeamAndCoverage() throws {
        let h = harness()
        let (groupId, _) = try createGroup(h)
        // Ripple out [600, 700): a seam at 600 with 100 frames of cut time.
        guard case .ok = h.editor.rippleDeleteRangesOnTrack(trackIndex: 0, ranges: [FrameRange(start: 600, end: 700)]) else {
            Issue.record("ripple refused")
            return
        }
        // Delete the program fragment left of the seam; try to cover the gap
        // by extending the right fragment leftward across the seam.
        let program = programClips(h, groupId)
        let left = program.first { $0.endFrame == 600 }!
        let right = program.first { $0.startFrame == 600 }!
        h.editor.removeClips(ids: [left.id])

        // Seam stop: the fragment sits at the seam, so leftward growth is 0 —
        // those frames were cut and the mics no longer carry them.
        let bounds = try #require(h.editor.multicamTrimBounds(for: h.editor.clipFor(id: right.id)!))
        #expect(bounds.left == 0)
        h.editor.commitTrim(clipId: right.id, edge: .left, deltaFrames: -80, propagateToLinked: false)
        #expect(h.editor.clipFor(id: right.id)!.startFrame == 600)

        // Coverage stop: rightward growth caps at the camera's remaining footage.
        let tail = h.editor.clipFor(id: right.id)!
        #expect(bounds.right == tail.trimEndFrame)
        h.editor.commitTrim(clipId: right.id, edge: .right, deltaFrames: tail.trimEndFrame + 500, propagateToLinked: false)
        #expect(h.editor.clipFor(id: right.id)!.trimEndFrame == 0)
    }

    // MARK: - Chip, program read, manual switch

    @Test func syncedMembersShowNoLinkOffsetBadge() throws {
        let h = harness()
        let (groupId, _) = try createGroup(h)
        // Members sit at different trims by design (different files, one clock) —
        // the misalignment badge must stay silent for an in-sync group.
        #expect(h.editor.linkGroupOffsets().isEmpty)

        // Ripple cuts shift each column by a different total — anchors differ
        // across columns but agree within one. No badge (remove_silence case).
        guard case .ok = h.editor.rippleDeleteRangesOnTrack(
            trackIndex: 0, ranges: [FrameRange(start: 300, end: 400), FrameRange(start: 900, end: 1050)]
        ) else {
            Issue.record("ripple refused")
            return
        }
        #expect(h.editor.linkGroupOffsets().isEmpty)

        // A genuine slip (dodging the guards) must still be flagged —
        // the badge lands on clips relative to the earliest anchor.
        let mic = micClip(h, groupId)
        let loc = h.editor.findClip(id: mic.id)!
        h.editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].trimStartFrame += 24
        #expect(!h.editor.linkGroupOffsets().isEmpty)
    }

    @Test func programRowsRunLengthMerge() throws {
        let h = harness()
        let (groupId, _) = try createGroup(h)
        _ = try h.editor.switchMulticamAngles(groupId: groupId, requests: [
            .init(range: 600..<1200, angle: "cam-b"),
        ])
        let rows = h.editor.multicamProgramRows(groupId: groupId)
        #expect(rows.map { $0[0] as? String } == ["cam-a", "cam-b", "cam-a"])
        #expect(rows[1][1] as? Int == 600 && rows[1][2] as? Int == 1200)
    }

}
