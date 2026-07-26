/// A proposed new start frame for a single clip, produced by the ripple engine
/// and applied by the caller.
public struct ClipShift: Equatable, Sendable {
    public let clipId: String
    public let newStartFrame: Int

    public init(clipId: String, newStartFrame: Int) {
        self.clipId = clipId
        self.newStartFrame = newStartFrame
    }
}
