/// A user-selected empty gap on a single track.
public struct GapSelection: Equatable, Sendable {
    public let trackIndex: Int
    public let range: FrameRange

    public init(trackIndex: Int, range: FrameRange) {
        self.trackIndex = trackIndex
        self.range = range
    }
}
