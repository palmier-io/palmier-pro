import Foundation

enum PlanSourceRangeError: Error, LocalizedError, Sendable {
    case invalidTime
    case unknownDuration
    case outsideSource
    case durationMismatch

    var blocker: String {
        switch self {
        case .invalidTime: "invalid_source_timing"
        case .unknownDuration: "unresolved_source_duration"
        case .outsideSource: "source_span_out_of_bounds"
        case .durationMismatch: "source_span_duration_mismatch"
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidTime: "Source times must be finite, non-negative, and inside supported frame bounds."
        case .unknownDuration: "Source audio/video requires a known positive duration."
        case .outsideSource: "Selected playback extends beyond the available source."
        case .durationMismatch: "Selected source span must match the resolved scene duration exactly; revise the span or pacing before assembly."
        }
    }
}

enum PlanSourceRange {
    static func frames(seconds: Double, fps: Int) throws -> Int {
        do { return try ClipPlacement.frames(seconds: seconds, fps: fps) }
        catch { throw PlanSourceRangeError.invalidTime }
    }

    static func inspection(shot: EditPlanShot, fps: Int, type: ClipType, duration: Double) throws -> Range<Int>? {
        guard (1...120).contains(fps) else { throw PlanSourceRangeError.invalidTime }
        guard type != .image else { return nil }
        let sourceFrames = try frames(seconds: duration, fps: fps)
        guard sourceFrames > 0 else { throw PlanSourceRangeError.unknownDuration }
        switch (shot.sourceStartSeconds, shot.sourceEndSeconds) {
        case let (.some(start), .some(end)):
            let first = try frames(seconds: start, fps: fps)
            let last = try frames(seconds: end, fps: fps)
            guard last > first else { throw PlanSourceRangeError.invalidTime }
            guard end <= duration else { throw PlanSourceRangeError.outsideSource }
            return first..<last
        case (.none, .none): return 0..<sourceFrames
        default: throw PlanSourceRangeError.invalidTime
        }
    }

    static func playback(shot: EditPlanShot, fps: Int, type: ClipType, duration: Double) throws -> Range<Int> {
        guard (1...120).contains(fps) else { throw PlanSourceRangeError.invalidTime }
        try EditPlan.validatedFrames(start: shot.startFrame, end: shot.endFrame)
        let count = shot.endFrame - shot.startFrame
        if type == .image {
            switch (shot.sourceStartSeconds, shot.sourceEndSeconds) {
            case let (.some(start), .some(end)):
                let first = try frames(seconds: start, fps: fps)
                let last = try frames(seconds: end, fps: fps)
                guard last > first else { throw PlanSourceRangeError.invalidTime }
                guard last - first == count else { throw PlanSourceRangeError.durationMismatch }
                return first..<last
            case (.none, .none): return 0..<count
            default: throw PlanSourceRangeError.invalidTime
            }
        }
        let selected = try inspection(shot: shot, fps: fps, type: type, duration: duration)
        guard let selected else { throw PlanSourceRangeError.invalidTime }
        if shot.sourceStartSeconds != nil {
            guard selected.count == count else { throw PlanSourceRangeError.durationMismatch }
            return selected
        }
        guard count <= selected.count else { throw PlanSourceRangeError.outsideSource }
        return 0..<count
    }
}
