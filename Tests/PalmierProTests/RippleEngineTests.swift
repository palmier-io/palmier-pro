import Testing
@testable import PalmierPro

@Suite("RippleEngine")
struct RippleEngineTests {

    // MARK: - computeRippleShifts (delete + close gap)

    @Test func emptyRemovedIdsProducesNoShifts() {
        let a = Fixtures.clip(id: "a", start: 0, duration: 50)
        let b = Fixtures.clip(id: "b", start: 100, duration: 50)
        #expect(RippleEngine.computeRippleShifts(clips: [a, b], removedIds: []).isEmpty)
    }

    @Test func removingMiddleClipShiftsTrailingClipsLeft() {
        // Remove [50, 100). The clip at [200, 250) should shift left by 50 → [150, 200).
        let removed = Fixtures.clip(id: "r", start: 50, duration: 50)
        let trailing = Fixtures.clip(id: "t", start: 200, duration: 50)
        let head = Fixtures.clip(id: "h", start: 0, duration: 50)

        let shifts = RippleEngine.computeRippleShifts(clips: [head, removed, trailing], removedIds: ["r"])
        #expect(shifts == [ClipShift(clipId: "t", newStartFrame: 150)])
    }

    @Test func clipsBeforeRemovedRangeDoNotShift() {
        let head = Fixtures.clip(id: "h", start: 0, duration: 50)
        let removed = Fixtures.clip(id: "r", start: 100, duration: 50)
        let shifts = RippleEngine.computeRippleShifts(clips: [head, removed], removedIds: ["r"])
        #expect(shifts.isEmpty)
    }

    @Test func removingMultipleClipsShiftsByMergedTotal() {
        // Remove [0, 50) and [100, 150). Clip at [200, 250) shifts left by 100 → [100, 200).
        let r1 = Fixtures.clip(id: "r1", start: 0, duration: 50)
        let r2 = Fixtures.clip(id: "r2", start: 100, duration: 50)
        let tail = Fixtures.clip(id: "t", start: 200, duration: 50)
        let shifts = RippleEngine.computeRippleShifts(clips: [r1, r2, tail], removedIds: ["r1", "r2"])
        #expect(shifts == [ClipShift(clipId: "t", newStartFrame: 100)])
    }

    // MARK: - computeRippleShiftsForRanges (merge + shift)

    @Test func overlappingRangesMergeBeforeShifting() {
        // Ranges [0, 100) and [50, 200) → merged [0, 200). Clip at [300, 400) shifts by 200 → [100, ...).
        let clip = Fixtures.clip(id: "c", start: 300, duration: 100)
        let shifts = RippleEngine.computeRippleShiftsForRanges(
            clips: [clip],
            removedRanges: [FrameRange(start: 0, end: 100), FrameRange(start: 50, end: 200)]
        )
        #expect(shifts == [ClipShift(clipId: "c", newStartFrame: 100)])
    }

    @Test func touchingRangesMergeBeforeShifting() {
        // [0, 50) touching [50, 100) → merged [0, 100). Clip at [200) shifts by 100.
        let clip = Fixtures.clip(id: "c", start: 200, duration: 50)
        let shifts = RippleEngine.computeRippleShiftsForRanges(
            clips: [clip],
            removedRanges: [FrameRange(start: 0, end: 50), FrameRange(start: 50, end: 100)]
        )
        #expect(shifts == [ClipShift(clipId: "c", newStartFrame: 100)])
    }

    @Test func rangeWhollyBeforeClipShiftsClip_rangeAfterDoesNot() {
        // Range [0, 50) shifts both clips. Range [400, 500) is after both → ignored.
        let a = Fixtures.clip(id: "a", start: 100, duration: 50)
        let b = Fixtures.clip(id: "b", start: 200, duration: 50)
        let shifts = RippleEngine.computeRippleShiftsForRanges(
            clips: [a, b],
            removedRanges: [FrameRange(start: 0, end: 50), FrameRange(start: 400, end: 500)]
        )
        #expect(shifts == [
            ClipShift(clipId: "a", newStartFrame: 50),
            ClipShift(clipId: "b", newStartFrame: 150),
        ])
    }

    @Test func rangeMustEndAtOrBeforeClipStartToShift() {
        // Range [0, 100) — clip at frame 100 has `range.end <= clip.startFrame` → shifts.
        // Range [0, 101) — clip at frame 100 fails the predicate → does NOT shift.
        let clip = Fixtures.clip(id: "c", start: 100, duration: 50)

        let exactlyAtStart = RippleEngine.computeRippleShiftsForRanges(
            clips: [clip],
            removedRanges: [FrameRange(start: 0, end: 100)]
        )
        #expect(exactlyAtStart == [ClipShift(clipId: "c", newStartFrame: 0)])

        let overlapping = RippleEngine.computeRippleShiftsForRanges(
            clips: [clip],
            removedRanges: [FrameRange(start: 0, end: 101)]
        )
        #expect(overlapping.isEmpty)
    }

    // MARK: - computeRipplePush (insert + push forward)

    @Test func pushMovesClipsAtOrAfterInsertFrame() {
        let a = Fixtures.clip(id: "a", start: 0, duration: 50)    // before insert
        let b = Fixtures.clip(id: "b", start: 100, duration: 50)  // at insert
        let c = Fixtures.clip(id: "c", start: 200, duration: 50)  // after insert
        let shifts = RippleEngine.computeRipplePush(clips: [a, b, c], insertFrame: 100, pushAmount: 30)
        #expect(shifts == [
            ClipShift(clipId: "b", newStartFrame: 130),
            ClipShift(clipId: "c", newStartFrame: 230),
        ])
    }

    @Test func pushSkipsExcludedIds() {
        let a = Fixtures.clip(id: "a", start: 100, duration: 50)
        let b = Fixtures.clip(id: "b", start: 200, duration: 50)
        let shifts = RippleEngine.computeRipplePush(
            clips: [a, b],
            insertFrame: 0,
            pushAmount: 25,
            excludeIds: ["a"]
        )
        #expect(shifts == [ClipShift(clipId: "b", newStartFrame: 225)])
    }
}
