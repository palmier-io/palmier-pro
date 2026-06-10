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

// MARK: - Adversarial

@Suite("OverwriteEngine — adversarial")
struct OverwriteEngineAdversarialTests {

    /// Apply an action sequence to a clip array (mimics what EditorViewModel does)
    /// and return the resulting clips sorted by startFrame.
    private func apply(_ actions: [OverwriteEngine.Action], to clips: [Clip]) -> [Clip] {
        var result = clips
        for action in actions {
            switch action {
            case .remove(let id):
                result.removeAll { $0.id == id }
            case .trimEnd(let id, let newDuration):
                if let i = result.firstIndex(where: { $0.id == id }) {
                    result[i].durationFrames = newDuration
                }
            case .trimStart(let id, let newStartFrame, let newTrimStart, let newDuration):
                if let i = result.firstIndex(where: { $0.id == id }) {
                    result[i].startFrame = newStartFrame
                    result[i].trimStartFrame = newTrimStart
                    result[i].durationFrames = newDuration
                }
            case .split(let id, let leftDuration, let rightId, let rightStartFrame, let rightTrimStart, let rightDuration):
                if let i = result.firstIndex(where: { $0.id == id }) {
                    var right = result[i]
                    result[i].durationFrames = leftDuration
                    right.id = rightId
                    right.startFrame = rightStartFrame
                    right.trimStartFrame = rightTrimStart
                    right.durationFrames = rightDuration
                    result.append(right)
                }
            }
        }
        return result.sorted { $0.startFrame < $1.startFrame }
    }

    private func overlaps(_ a: Clip, _ b: Clip) -> Bool {
        a.startFrame < b.endFrame && b.startFrame < a.endFrame
    }

    // MARK: - Invariants

    @Test func actionsClearTheRegionAcrossAllBranches() {
        // Apply actions and verify no clip occupies the region afterwards.
        let region = (start: 50, end: 150)
        let scenarios: [(name: String, clips: [Clip])] = [
            ("inside", [Fixtures.clip(id: "x", start: 60, duration: 40)]),
            ("exactly matching", [Fixtures.clip(id: "x", start: 50, duration: 100)]),
            ("overlaps left", [Fixtures.clip(id: "x", start: 0, duration: 100)]),
            ("overlaps right", [Fixtures.clip(id: "x", start: 100, duration: 100)]),
            ("envelops", [Fixtures.clip(id: "x", start: 0, duration: 200)]),
            ("envelop + speed", [Fixtures.clip(id: "x", start: 0, duration: 200, speed: 2.0)]),
            ("trimStart non-zero", [Fixtures.clip(id: "x", start: 0, duration: 200, trimStart: 10)]),
        ]
        for (name, clips) in scenarios {
            let actions = OverwriteEngine.computeOverwrite(
                clips: clips, regionStart: region.start, regionEnd: region.end
            )
            let after = apply(actions, to: clips)
            let occupant = after.first { $0.startFrame < region.end && $0.endFrame > region.start }
            #expect(occupant == nil, "\(name): clip \(occupant?.id ?? "?") still occupies region")
        }
    }

    @Test func actionsDoNotProduceOverlappingSurvivors() {
        let scenarios: [[Clip]] = [
            [Fixtures.clip(id: "x", start: 0, duration: 200)], // split into two halves
            [
                Fixtures.clip(id: "a", start: 0, duration: 60),
                Fixtures.clip(id: "b", start: 100, duration: 200),
            ],
        ]
        for clips in scenarios {
            let actions = OverwriteEngine.computeOverwrite(clips: clips, regionStart: 50, regionEnd: 150)
            let after = apply(actions, to: clips)
            for i in 0..<after.count {
                for j in (i + 1)..<after.count {
                    #expect(!overlaps(after[i], after[j]))
                }
            }
        }
    }

    /// Half-open boundary convention: a clip starting exactly at regionEnd is untouched.
    /// Verified together with RippleEngine's matching convention.
    @Test func adjacentClipAtRegionEndIsNotTouched() {
        let after = Fixtures.clip(id: "b", start: 100, duration: 50)
        let actions = OverwriteEngine.computeOverwrite(clips: [after], regionStart: 50, regionEnd: 100)
        #expect(actions.isEmpty)
    }

    // MARK: - Edge inputs

    @Test func zeroDurationClipDoesNotCrash() {
        // cs == ce == startFrame. Engine treats it as a point inside the region → .remove.
        let zeroClip = Fixtures.clip(id: "z", start: 100, duration: 0)
        let actions = OverwriteEngine.computeOverwrite(clips: [zeroClip], regionStart: 50, regionEnd: 150)
        _ = actions // don't assert specific shape, just that we don't crash
    }
}
