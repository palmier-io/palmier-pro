import Testing
@testable import CompositorPro

struct PlanSourceRangeTests {
    @Test(arguments: [
        (0.0, 30, 0), (-0.0, 30, 0), (0.01, 30, 0),
        (1.999, 30, 59), (2.125, 24, 51), (0.009, 120, 1),
        (1.0, 1, 1), (1.0, 120, 120), (Double(maxFrameArg), 1, maxFrameArg),
    ])
    func finiteSecondsTruncateLikeSecondsToFrame(seconds: Double, fps: Int, expected: Int) throws {
        let frames = try PlanSourceRange.frames(seconds: seconds, fps: fps)
        #expect(frames == expected)
        #expect(frames == secondsToFrame(seconds: seconds, fps: fps))
    }

    @Test(arguments: [
        -1.0, -Double.leastNonzeroMagnitude, .nan, .infinity, -.infinity,
        Double(maxFrameArg) + 1, 1e19, 1e300, .greatestFiniteMagnitude,
    ])
    func invalidOrOverflowingSecondsAreRefused(seconds: Double) {
        expectError(.invalidTime) { _ = try PlanSourceRange.frames(seconds: seconds, fps: 1) }
    }

    @Test func multiplicationOverflowIsRefusedBeforeIntegerConversion() {
        expectError(.invalidTime) {
            _ = try PlanSourceRange.frames(seconds: .greatestFiniteMagnitude, fps: 120)
        }
    }

    @Test(arguments: [Int.min, -1, 0, 121, Int.max], [0.0, 1.0])
    func unsupportedFrameRatesAreRefusedEvenForZeroSeconds(fps: Int, seconds: Double) {
        expectError(.invalidTime) { _ = try PlanSourceRange.frames(seconds: seconds, fps: fps) }
    }

    @Test(arguments: [Int.min, 0, 121, Int.max])
    func implicitStillsAlsoRequireSupportedFrameRates(fps: Int) {
        expectError(.invalidTime) {
            _ = try PlanSourceRange.inspection(shot: makeShot(), fps: fps, type: .image, duration: 0)
        }
        expectError(.invalidTime) {
            _ = try PlanSourceRange.playback(shot: makeShot(), fps: fps, type: .image, duration: 0)
        }
    }

    @Test(arguments: [ClipType.video, .audio, .image])
    func explicitSpanUsesSourceCoordinatesAndExactSceneDuration(type: ClipType) throws {
        let shot = makeShot(start: 120, end: 180, sourceStart: 2, sourceEnd: 4)
        #expect(try PlanSourceRange.playback(shot: shot, fps: 30, type: type, duration: 4) == 60..<120)
    }

    @Test(arguments: [ClipType.video, .audio])
    func explicitInspectionDoesNotRequireMatchingSceneDuration(type: ClipType) throws {
        let shot = makeShot(end: 30, sourceStart: 2, sourceEnd: 4)
        #expect(try PlanSourceRange.inspection(shot: shot, fps: 30, type: type, duration: 5) == 60..<120)
    }

    @Test(arguments: [ClipType.video, .audio, .image], [59, 61])
    func explicitPlaybackRefusesShorterAndLongerSceneDurations(type: ClipType, count: Int) {
        let shot = makeShot(end: count, sourceStart: 2, sourceEnd: 4)
        expectError(.durationMismatch) {
            _ = try PlanSourceRange.playback(shot: shot, fps: 30, type: type, duration: 5)
        }
    }

    @Test(arguments: [ClipType.video, .audio, .image])
    func fractionalEndpointsTruncateSeparatelyBeforeCheckingDuration(type: ClipType) throws {
        let shot = makeShot(end: 30, sourceStart: 0.02, sourceEnd: 1.01)
        #expect(try PlanSourceRange.playback(shot: shot, fps: 30, type: type, duration: 2) == 0..<30)
    }

    @Test(arguments: [ClipType.video, .audio], [1, 60, 150])
    func implicitInspectionCoversFullSourceWhilePlaybackUsesSceneDuration(type: ClipType, count: Int) throws {
        let shot = makeShot(start: 90, end: 90 + count)
        #expect(try PlanSourceRange.inspection(shot: shot, fps: 30, type: type, duration: 5) == 0..<150)
        #expect(try PlanSourceRange.playback(shot: shot, fps: 30, type: type, duration: 5) == 0..<count)
    }

    @Test(arguments: [ClipType.video, .audio])
    func implicitPlaybackCannotExtendPastSource(type: ClipType) {
        expectError(.outsideSource) {
            _ = try PlanSourceRange.playback(shot: makeShot(end: 151), fps: 30, type: type, duration: 5)
        }
    }

    @Test(arguments: [0.0, -1.0, .nan, .infinity])
    func implicitStillPlaybackHasNoSourceDurationLimit(duration: Double) throws {
        let shot = makeShot(end: maxFrameArg)
        #expect(try PlanSourceRange.inspection(shot: shot, fps: 30, type: .image, duration: duration) == nil)
        #expect(try PlanSourceRange.playback(shot: shot, fps: 30, type: .image, duration: duration) == 0..<maxFrameArg)
    }

    @Test func explicitStillSpanIsNotBoundedByAssetDuration() throws {
        let shot = makeShot(end: 60, sourceStart: 5, sourceEnd: 7)
        #expect(try PlanSourceRange.inspection(shot: shot, fps: 30, type: .image, duration: 0) == nil)
        #expect(try PlanSourceRange.playback(shot: shot, fps: 30, type: .image, duration: 0) == 150..<210)
    }

    @Test(arguments: [ClipType.video, .audio], [2.0001, 3.0])
    func explicitEndpointsPastSourceAreRefusedWithoutFrameClamping(type: ClipType, sourceEnd: Double) {
        let shot = makeShot(end: 60, sourceStart: 0, sourceEnd: sourceEnd)
        expectError(.outsideSource) {
            _ = try PlanSourceRange.inspection(shot: shot, fps: 30, type: type, duration: 2)
        }
        expectError(.outsideSource) {
            _ = try PlanSourceRange.playback(shot: shot, fps: 30, type: type, duration: 2)
        }
    }

    @Test(arguments: [ClipType.video, .audio, .image], [
        (-1.0, 1.0), (-2.0, -1.0), (0.0, 0.0), (2.0, 1.0), (0.001, 0.01),
    ])
    func negativeReversedOrEmptyFrameSpansAreRefused(type: ClipType, span: (Double, Double)) {
        let shot = makeShot(sourceStart: span.0, sourceEnd: span.1)
        expectError(.invalidTime) {
            _ = try PlanSourceRange.playback(shot: shot, fps: 30, type: type, duration: 5)
        }
    }

    @Test(arguments: [ClipType.video, .audio, .image], [
        (Double.nan, 1.0), (Double.infinity, 1.0), (-Double.infinity, 1.0),
        (0.0, Double.nan), (0.0, Double.infinity), (0.0, -Double.infinity),
        (1e300, 1e300), (0.0, Double.greatestFiniteMagnitude),
    ])
    func nonfiniteOrOverflowingExplicitEndpointsAreRefused(type: ClipType, span: (Double, Double)) {
        #expect(throws: PlanSourceRangeError.self) {
            _ = try PlanSourceRange.playback(
                shot: makeShot(sourceStart: span.0, sourceEnd: span.1), fps: 30, type: type, duration: 5
            )
        }
    }

    @Test(arguments: [ClipType.video, .audio, .image], [
        (Optional(1.0), Optional<Double>.none), (Optional<Double>.none, Optional(2.0)),
    ])
    func incompleteExplicitSpansAreRefused(type: ClipType, span: (Double?, Double?)) {
        let shot = makeShot(sourceStart: span.0, sourceEnd: span.1)
        expectError(.invalidTime) {
            _ = try PlanSourceRange.playback(shot: shot, fps: 30, type: type, duration: 5)
        }
    }

    @Test(arguments: [ClipType.video, .audio], [0.0, 0.01])
    func sourcesWithoutOneAvailableFrameHaveUnknownDuration(type: ClipType, duration: Double) {
        expectError(.unknownDuration) {
            _ = try PlanSourceRange.inspection(shot: makeShot(), fps: 30, type: type, duration: duration)
        }
        expectError(.unknownDuration) {
            _ = try PlanSourceRange.playback(shot: makeShot(), fps: 30, type: type, duration: duration)
        }
    }

    @Test(arguments: [ClipType.video, .audio], [-1.0, .nan, .infinity, -.infinity, .greatestFiniteMagnitude])
    func invalidSourceDurationsAreRefused(type: ClipType, duration: Double) {
        expectError(.invalidTime) {
            _ = try PlanSourceRange.inspection(shot: makeShot(), fps: 30, type: type, duration: duration)
        }
        expectError(.invalidTime) {
            _ = try PlanSourceRange.playback(shot: makeShot(), fps: 30, type: type, duration: duration)
        }
    }

    @Test(arguments: [ClipType.video, .audio, .image], [
        (-1, 30), (0, 0), (30, 29), (0, maxFrameArg + 1), (Int.min, Int.max),
    ])
    func invalidSceneFramesAreRefusedBeforeDurationArithmetic(type: ClipType, range: (Int, Int)) {
        #expect(throws: EditPlanValidationError.self) {
            _ = try PlanSourceRange.playback(shot: makeShot(start: range.0, end: range.1), fps: 30, type: type, duration: 5)
        }
    }

    private func makeShot(start: Int = 0, end: Int = 30, sourceStart: Double? = nil, sourceEnd: Double? = nil) -> EditPlanShot {
        .init(id: "shot", title: "Source range", startFrame: start, endFrame: end,
              sourceStartSeconds: sourceStart, sourceEndSeconds: sourceEnd)
    }

    private func expectError(_ expected: PlanSourceRangeError, _ operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("Expected \(expected.blocker).")
        } catch let error as PlanSourceRangeError {
            #expect(error.blocker == expected.blocker)
        } catch {
            Issue.record(error)
        }
    }
}
