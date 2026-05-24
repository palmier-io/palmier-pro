import Testing
@testable import PalmierPro

@Suite("OverwriteEngine.computeOverwrite")
struct OverwriteEngineTests {

    @Test func emptyRegionProducesNoActions() {
        let clip = Fixtures.clip(start: 0, duration: 100)
        #expect(OverwriteEngine.computeOverwrite(clips: [clip], regionStart: 50, regionEnd: 50).isEmpty)
        #expect(OverwriteEngine.computeOverwrite(clips: [clip], regionStart: 60, regionEnd: 50).isEmpty)
    }

    @Test func noClipsProducesNoActions() {
        #expect(OverwriteEngine.computeOverwrite(clips: [], regionStart: 0, regionEnd: 100).isEmpty)
    }

    @Test func clipFullyOutsideRegionIsIgnored() {
        let before = Fixtures.clip(id: "before", start: 0, duration: 40)   // [0, 40)
        let after = Fixtures.clip(id: "after", start: 200, duration: 50)   // [200, 250)
        let actions = OverwriteEngine.computeOverwrite(clips: [before, after], regionStart: 50, regionEnd: 150)
        #expect(actions.isEmpty)
    }

    @Test func clipFullyInsideRegionIsRemoved() {
        let clip = Fixtures.clip(id: "c1", start: 60, duration: 40) // [60, 100)
        let actions = OverwriteEngine.computeOverwrite(clips: [clip], regionStart: 50, regionEnd: 150)
        #expect(actions.count == 1)
        if case .remove(let clipId) = actions[0] {
            #expect(clipId == "c1")
        } else {
            Issue.record("expected .remove, got \(actions[0])")
        }
    }

    @Test func clipExactlyMatchingRegionIsRemoved() {
        let clip = Fixtures.clip(id: "c1", start: 50, duration: 100) // [50, 150)
        let actions = OverwriteEngine.computeOverwrite(clips: [clip], regionStart: 50, regionEnd: 150)
        #expect(actions.count == 1)
        if case .remove = actions[0] {} else {
            Issue.record("expected .remove, got \(actions[0])")
        }
    }

    @Test func clipEnvelopingRegionIsSplit() {
        // Clip [0, 200), region [50, 150). Expect split: leftDuration=50, rightStart=150, rightDuration=50.
        let clip = Fixtures.clip(id: "c1", start: 0, duration: 200)
        let actions = OverwriteEngine.computeOverwrite(clips: [clip], regionStart: 50, regionEnd: 150)
        #expect(actions.count == 1)
        guard case let .split(clipId, leftDuration, _, rightStartFrame, rightTrimStart, rightDuration) = actions[0] else {
            Issue.record("expected .split, got \(actions[0])")
            return
        }
        #expect(clipId == "c1")
        #expect(leftDuration == 50)
        #expect(rightStartFrame == 150)
        #expect(rightTrimStart == 150) // trimStart 0 + (150-0)*1.0
        #expect(rightDuration == 50)
    }

    @Test func splitRespectsSpeedAndTrimStart() {
        // speed=2.0, trimStart=10, clip [0, 200), region [50, 150)
        let clip = Fixtures.clip(id: "c1", start: 0, duration: 200, trimStart: 10, speed: 2.0)
        let actions = OverwriteEngine.computeOverwrite(clips: [clip], regionStart: 50, regionEnd: 150)
        guard case let .split(_, leftDuration, _, rightStartFrame, rightTrimStart, rightDuration) = actions[0] else {
            Issue.record("expected .split")
            return
        }
        #expect(leftDuration == 50)
        #expect(rightStartFrame == 150)
        #expect(rightTrimStart == 310) // 10 + (150-0)*2.0
        #expect(rightDuration == 50)
    }

    @Test func clipOverlappingLeftEdgeIsTrimEnd() {
        // Clip [0, 100), region [50, 200). Expect trimEnd to newDuration=50.
        let clip = Fixtures.clip(id: "c1", start: 0, duration: 100)
        let actions = OverwriteEngine.computeOverwrite(clips: [clip], regionStart: 50, regionEnd: 200)
        #expect(actions.count == 1)
        guard case let .trimEnd(clipId, newDuration) = actions[0] else {
            Issue.record("expected .trimEnd, got \(actions[0])")
            return
        }
        #expect(clipId == "c1")
        #expect(newDuration == 50)
    }

    @Test func clipOverlappingRightEdgeIsTrimStart() {
        // Clip [50, 150), region [0, 100). Expect trimStart at frame 100, newDuration=50.
        let clip = Fixtures.clip(id: "c1", start: 50, duration: 100)
        let actions = OverwriteEngine.computeOverwrite(clips: [clip], regionStart: 0, regionEnd: 100)
        #expect(actions.count == 1)
        guard case let .trimStart(clipId, newStartFrame, newTrimStart, newDuration) = actions[0] else {
            Issue.record("expected .trimStart, got \(actions[0])")
            return
        }
        #expect(clipId == "c1")
        #expect(newStartFrame == 100)
        #expect(newTrimStart == 50) // trimStart 0 + (100-50)*1.0
        #expect(newDuration == 50)
    }

    @Test func trimStartRespectsSpeedAndTrimStart() {
        // speed=2.0, trimStart=10, clip [50, 150), region [0, 100)
        let clip = Fixtures.clip(id: "c1", start: 50, duration: 100, trimStart: 10, speed: 2.0)
        let actions = OverwriteEngine.computeOverwrite(clips: [clip], regionStart: 0, regionEnd: 100)
        guard case let .trimStart(_, newStartFrame, newTrimStart, newDuration) = actions[0] else {
            Issue.record("expected .trimStart")
            return
        }
        #expect(newStartFrame == 100)
        #expect(newTrimStart == 110) // 10 + (100-50)*2.0
        #expect(newDuration == 50)
    }

    @Test func adjacentEdgesDoNotTrigger() {
        // Clip ends exactly at regionStart, or starts exactly at regionEnd → no action.
        let left = Fixtures.clip(id: "left", start: 0, duration: 50)   // [0, 50)
        let right = Fixtures.clip(id: "right", start: 150, duration: 50) // [150, 200)
        let actions = OverwriteEngine.computeOverwrite(clips: [left, right], regionStart: 50, regionEnd: 150)
        #expect(actions.isEmpty)
    }

    @Test func multipleClipsProduceOneActionEach() {
        // Region [50, 150) against three clips covering each non-skip branch.
        let inside = Fixtures.clip(id: "inside", start: 60, duration: 30)      // [60, 90)  → remove
        let leftOverlap = Fixtures.clip(id: "left", start: 0, duration: 60)    // [0, 60)   → trimEnd
        let rightOverlap = Fixtures.clip(id: "right", start: 100, duration: 200) // [100, 300) → trimStart
        let actions = OverwriteEngine.computeOverwrite(
            clips: [inside, leftOverlap, rightOverlap],
            regionStart: 50,
            regionEnd: 150
        )
        #expect(actions.count == 3)
    }
}
