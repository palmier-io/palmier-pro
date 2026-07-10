import Foundation
import Testing
@testable import PalmierPro

/// Pure-logic tests for the export stall watchdog (#68). Time is fed in as a
/// `Duration` offset so no real clock is needed.
@Suite("ExportStallWatcher")
struct ExportStallWatcherTests {

    private let limit = Duration.seconds(10)

    @Test func advancingProgressNeverStalls() {
        var w = ExportStallWatcher()
        // Progress climbs every tick; even after many× the limit, no stall.
        for i in 0...200 {
            let now = Duration.milliseconds(200) * i
            let stalled = w.update(progress: Double(i) * 0.001, now: now, stallLimit: limit)
            #expect(!stalled)
        }
    }

    @Test func frozenProgressStallsAfterLimit() {
        var w = ExportStallWatcher()
        // First sample establishes baseline at t=0.
        _ = w.update(progress: 0.5, now: .zero, stallLimit: limit)
        // Frozen just under the limit: still ok.
        let under = w.update(progress: 0.5, now: .seconds(9), stallLimit: limit)
        #expect(!under)
        // At the limit with no movement: stall.
        let atLimit = w.update(progress: 0.5, now: .seconds(10), stallLimit: limit)
        #expect(atLimit)
    }

    @Test func advanceResetsTheStallClock() {
        var w = ExportStallWatcher()
        _ = w.update(progress: 0.0, now: .zero, stallLimit: limit)
        // Sit frozen for most of the limit.
        let under = w.update(progress: 0.0, now: .seconds(8), stallLimit: limit)
        #expect(!under)
        // Move just in time — clock resets.
        let afterMove = w.update(progress: 0.1, now: .seconds(9), stallLimit: limit)
        #expect(!afterMove)
        // Another window of stillness since the last advance: ok under, stall over.
        let underAgain = w.update(progress: 0.1, now: .seconds(18), stallLimit: limit)
        #expect(!underAgain)
        let over = w.update(progress: 0.1, now: .seconds(19), stallLimit: limit)
        #expect(over)
    }

    @Test func firstSampleDoesNotCountAsProgress() {
        var w = ExportStallWatcher()
        // A single sample at the limit boundary: never advanced, so it stalls.
        let stalled = w.update(progress: 0.3, now: limit, stallLimit: limit)
        #expect(stalled)
    }

    @Test func neverMovingStallsFromZero() {
        var w = ExportStallWatcher()
        for s in 0...60 {
            let stalled = w.update(progress: 0.0, now: Duration.seconds(s), stallLimit: limit)
            #expect(stalled == (s >= 10))
        }
    }

    @Test func subEpsilonJitterIsNotMovement() {
        var w = ExportStallWatcher(epsilon: 0.001)
        _ = w.update(progress: 0.5, now: .zero, stallLimit: limit)
        // Jitter below epsilon must not reset the clock.
        let stalled = w.update(progress: 0.5005, now: .seconds(11), stallLimit: limit)
        #expect(stalled)
    }

    @Test func meaningfulMovementPastEpsilonResets() {
        var w = ExportStallWatcher(epsilon: 0.001)
        _ = w.update(progress: 0.5, now: .zero, stallLimit: limit)
        // A real advance just before the limit resets, so no stall at the boundary.
        let moved = w.update(progress: 0.52, now: .seconds(9), stallLimit: limit)
        #expect(!moved)
        let stillOk = w.update(progress: 0.52, now: .seconds(18), stallLimit: limit)
        #expect(!stillOk)
    }
}
