import Foundation

/// Exact timeline time as an integer tick count at 120,000 ticks per second. 120k divides evenly
/// by every standard frame rate (including drop-frame), so snapping never drifts.
struct MediaTime: Hashable, Comparable, Sendable, Codable {
    static let ticksPerSecond: Int64 = 120_000

    let ticks: Int64

    init(ticks: Int64) {
        self.ticks = ticks
    }

    /// Exact seconds only; non-finite or out-of-range values are rejected.
    init?(seconds: Double) {
        guard seconds.isFinite else { return nil }
        let scaled = (seconds * Double(Self.ticksPerSecond)).rounded()
        guard scaled >= Double(Int64.min), scaled <= Double(Int64.max) else { return nil }
        self.ticks = Int64(scaled)
    }

    var seconds: Double { Double(ticks) / Double(Self.ticksPerSecond) }

    func adding(_ other: MediaTime) -> MediaTime? {
        let (value, overflow) = ticks.addingReportingOverflow(other.ticks)
        return overflow ? nil : MediaTime(ticks: value)
    }

    func subtracting(_ other: MediaTime) -> MediaTime? {
        let (value, overflow) = ticks.subtractingReportingOverflow(other.ticks)
        return overflow ? nil : MediaTime(ticks: value)
    }

    static func < (lhs: MediaTime, rhs: MediaTime) -> Bool { lhs.ticks < rhs.ticks }
}

/// Rational frame rate with exact ticks-per-frame constants for standard rates.
struct FrameRate: Hashable, Sendable, Codable {
    let numerator: Int64
    let denominator: Int64

    init?(numerator: Int64, denominator: Int64) {
        guard numerator > 0, denominator > 0 else { return nil }
        let divisor = Self.greatestCommonDivisor(numerator, denominator)
        self.numerator = numerator / divisor
        self.denominator = denominator / divisor
    }

    static let fps24 = FrameRate(numerator: 24, denominator: 1)!
    static let fps25 = FrameRate(numerator: 25, denominator: 1)!
    static let fps30 = FrameRate(numerator: 30, denominator: 1)!
    static let fps60 = FrameRate(numerator: 60, denominator: 1)!
    static let fps23_976 = FrameRate(numerator: 24_000, denominator: 1_001)!
    static let fps29_97 = FrameRate(numerator: 30_000, denominator: 1_001)!

    /// Exact ticks per frame for the standard rates; nil for a rate 120k cannot represent evenly.
    var ticksPerFrame: Int64? {
        let exact = Int64(MediaTime.ticksPerSecond) * denominator
        guard exact % numerator == 0 else { return nil }
        return exact / numerator
    }

    enum Rounding: Sendable { case floor, nearest, ceil }

    /// Frame index containing `time`, using the requested rounding.
    func frameIndex(at time: MediaTime, rounding: Rounding = .floor) -> Int64? {
        guard let ticksPerFrame else { return nil }
        let quotient = time.ticks.quotientAndRemainder(dividingBy: ticksPerFrame)
        switch rounding {
        case .floor: return quotient.quotient
        case .ceil: return quotient.remainder == 0 ? quotient.quotient : quotient.quotient + 1
        case .nearest:
            return quotient.remainder * 2 >= ticksPerFrame ? quotient.quotient + 1 : quotient.quotient
        }
    }

    /// Start time of a frame.
    func time(ofFrame frame: Int64) -> MediaTime? {
        guard let ticksPerFrame else { return nil }
        let (value, overflow) = frame.multipliedReportingOverflow(by: ticksPerFrame)
        return overflow ? nil : MediaTime(ticks: value)
    }

    private static func greatestCommonDivisor(_ a: Int64, _ b: Int64) -> Int64 {
        var a = a, b = b
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }
}

extension FrameRate {
    /// HH:MM:SS:FF using nominal whole-frame numbering (no drop-frame compensation).
    func timecode(forFrame frame: Int64) -> String {
        let nominalFPS = max(1, Int((Double(numerator) / Double(denominator)).rounded()))
        let framesPerMinute = Int64(nominalFPS) * 60
        let framesPerHour = framesPerMinute * 60
        let hours = frame / framesPerHour
        let minutes = (frame % framesPerHour) / framesPerMinute
        let seconds = (frame % framesPerMinute) / Int64(nominalFPS)
        let frames = frame % Int64(nominalFPS)
        return String(format: "%02d:%02d:%02d:%02d", hours, minutes, seconds, frames)
    }
}
