import Testing
@testable import PalmierPro

@Suite("Silence removal planner")
struct SilenceRemovalPlannerTests {
    @Test func filtersPausesShorterThanMinimum() throws {
        let settings = try #require(SilenceRemovalSettings(
            minimumPauseSeconds: 0.5,
            speechPaddingSeconds: 0
        ))

        let mask = SilenceRemovalPlanner.removableMask(
            from: [false, true, true, true, true, false],
            settings: settings,
            cellDuration: 0.1
        )

        #expect(!mask.contains(true))
    }

    @Test func padsBothSpeechBoundaries() throws {
        let settings = try #require(SilenceRemovalSettings(
            minimumPauseSeconds: 0.5,
            speechPaddingSeconds: 0.2
        ))

        let mask = SilenceRemovalPlanner.removableMask(
            from: [false] + [Bool](repeating: true, count: 10) + [false],
            settings: settings,
            cellDuration: 0.1
        )

        #expect(mask == [false, false, false] + [Bool](repeating: true, count: 6) + [false, false, false])
    }

    @Test func doesNotPadSourceEdges() throws {
        let settings = try #require(SilenceRemovalSettings(
            minimumPauseSeconds: 0.3,
            speechPaddingSeconds: 0.2
        ))

        let mask = SilenceRemovalPlanner.removableMask(
            from: [Bool](repeating: true, count: 5) + [false] + [Bool](repeating: true, count: 5),
            settings: settings,
            cellDuration: 0.1
        )

        #expect(mask == [true, true, true, false, false, false, false, false, true, true, true])
    }

    @Test func removesPaddingAtTrimmedClipEdgesOnly() {
        let settings = SilenceRemovalSettings(
            minimumPauseSeconds: 0.5,
            speechPaddingSeconds: 0.2
        )!
        let mask = [false, false, true, true, true, true, false, false]

        #expect(SilenceRemovalPlanner.visibleRemovableRanges(
            from: mask,
            visibleSourceRange: 0.0..<9.0,
            framesPerSecond: 10,
            settings: settings,
            cellDuration: 0.1
        ) == [0.0..<6.0])
        #expect(SilenceRemovalPlanner.visibleRemovableRanges(
            from: mask,
            visibleSourceRange: -1.0..<8.0,
            framesPerSecond: 10,
            settings: settings,
            cellDuration: 0.1
        ) == [2.0..<8.0])
        #expect(SilenceRemovalPlanner.visibleRemovableRanges(
            from: mask,
            visibleSourceRange: -1.0..<9.0,
            framesPerSecond: 10,
            settings: settings,
            cellDuration: 0.1
        ) == [2.0..<6.0])
        #expect(SilenceRemovalPlanner.visibleRemovableRanges(
            from: mask,
            visibleSourceRange: 0.0..<1.0,
            framesPerSecond: 10,
            settings: settings,
            cellDuration: 0.1
        ) == [0.0..<1.0])
        #expect(SilenceRemovalPlanner.visibleRemovableRanges(
            from: mask,
            visibleSourceRange: 7.0..<8.0,
            framesPerSecond: 10,
            settings: settings,
            cellDuration: 0.1
        ) == [7.0..<8.0])
    }

    @Test func rejectsInvalidSettings() {
        #expect(SilenceRemovalSettings(minimumPauseSeconds: .nan, speechPaddingSeconds: 0.15) == nil)
        #expect(SilenceRemovalSettings(minimumPauseSeconds: 0.1, speechPaddingSeconds: 0.15) == nil)
        #expect(SilenceRemovalSettings(minimumPauseSeconds: 0.5, speechPaddingSeconds: 0.75) == nil)
    }

    @Test func extremeCellResolutionDoesNotOverflow() {
        let mask = SilenceRemovalPlanner.removableMask(
            from: [true, true],
            settings: .default,
            cellDuration: .leastNonzeroMagnitude
        )

        #expect(mask == [false, false])
    }

    @Test func rejectsNonFiniteVisibleSourceBounds() {
        #expect(SilenceRemovalPlanner.visibleRemovableRanges(
            from: [true],
            visibleSourceRange: 0..<Double.infinity,
            framesPerSecond: 30,
            settings: .default
        ).isEmpty)
    }
}
