/// A half-open `[start, end)` frame interval on a single track. Used to describe
/// the gaps that a ripple edit needs to close, and as a general-purpose frame
/// range type across the editor.
public struct FrameRange: Equatable, Sendable {
    public let start: Int
    public let end: Int
    public var length: Int { end - start }

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}
