import Testing
@testable import PalmierCore

// Minimal clip used only to prove the engines have no dependency on the app's
// concrete Clip struct or any UI/Foundation media model. If PalmierCore can run
// these tests, it is portable.
private struct StubClip: RippleClip {
    let id: String
    let startFrame: Int
    let durationFrames: Int
    let trimStartFrame: Int
    let speed: Double
    var endFrame: Int { startFrame + durationFrames }

    init(_ id: String, start: Int, duration: Int, trimStart: Int = 0, speed: Double = 1.0) {
        self.id = id
        self.startFrame = start
        self.durationFrames = duration
        self.trimStartFrame = trimStart
        self.speed = speed
    }
}

@Suite("PalmierCore.RippleEngine")
struct RippleEngineCoreTests {

    @Test func removingMiddleClipShiftsTrailingClipsLeft() {
        let head = StubClip("h", start: 0, duration: 50)
        let removed = StubClip("r", start: 50, duration: 50)
        let trailing = StubClip("t", start: 200, duration: 50)
        let shifts = RippleEngine.computeRippleShifts(clips: [head, removed, trailing], removedIds: ["r"])
        #expect(shifts == [ClipShift(clipId: "t", newStartFrame: 150)])
    }

    @Test func overlappingRangesMergeBeforeShifting() {
        let clip = StubClip("c", start: 300, duration: 100)
        let shifts = RippleEngine.computeRippleShiftsForRanges(
            clips: [clip],
            removedRanges: [FrameRange(start: 0, end: 100), FrameRange(start: 50, end: 200)]
        )
        #expect(shifts == [ClipShift(clipId: "c", newStartFrame: 100)])
    }

    @Test func pushSkipsExcludedIds() {
        let a = StubClip("a", start: 100, duration: 50)
        let b = StubClip("b", start: 200, duration: 50)
        let shifts = RippleEngine.computeRipplePush(clips: [a, b], insertFrame: 0, pushAmount: 25, excludeIds: ["a"])
        #expect(shifts == [ClipShift(clipId: "b", newStartFrame: 225)])
    }

    @Test func mergeRangesIsExposedForNonRippleConsumers() {
        let merged = RippleEngine.mergeRanges([FrameRange(start: 0, end: 50), FrameRange(start: 50, end: 100)])
        #expect(merged == [FrameRange(start: 0, end: 100)])
    }
}

@Suite("PalmierCore.OverwriteEngine")
struct OverwriteEngineCoreTests {

    @Test func envelopingClipIsSplit() {
        let clip = StubClip("c1", start: 0, duration: 200)
        let actions = OverwriteEngine.computeOverwrite(
            clips: [clip], regionStart: 50, regionEnd: 150,
            idProvider: { "new-id" }
        )
        guard case let .split(clipId, leftDuration, rightId, rightStartFrame, rightTrimStart, rightDuration) = actions[0] else {
            Issue.record("expected .split, got \(actions[0])")
            return
        }
        #expect(clipId == "c1")
        #expect(leftDuration == 50)
        #expect(rightId == "new-id")
        #expect(rightStartFrame == 150)
        #expect(rightTrimStart == 150)
        #expect(rightDuration == 50)
    }

    // Regression: the split case used to call UUID().uuidString inside the
    // engine, making results non-deterministic. The injected idProvider makes
    // the produced id stable and fully controlled by the caller.
    @Test func splitUsesInjectedIdProvider() {
        let clip = StubClip("c1", start: 0, duration: 200)
        var counter = 0
        let actions = OverwriteEngine.computeOverwrite(
            clips: [clip], regionStart: 50, regionEnd: 150,
            idProvider: { counter += 1; return "gen-\(counter)" }
        )
        guard case let .split(_, _, rightId, _, _, _) = actions[0] else {
            Issue.record("expected .split")
            return
        }
        #expect(rightId == "gen-1")
    }

    @Test func clipFullyInsideRegionIsRemoved() {
        let clip = StubClip("c1", start: 60, duration: 40)
        let actions = OverwriteEngine.computeOverwrite(
            clips: [clip], regionStart: 50, regionEnd: 150,
            idProvider: { "unused" }
        )
        if case .remove(let clipId) = actions[0] {
            #expect(clipId == "c1")
        } else {
            Issue.record("expected .remove, got \(actions[0])")
        }
    }
}
