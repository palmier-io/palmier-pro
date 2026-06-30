import AVFoundation

/// Immutable per-clip snapshot read on the render queue — never the live timeline.
struct LayerPlan: Sendable {
    enum Source: Sendable {
        case track(CMPersistentTrackID)
        case text
    }
    let source: Source
    let clip: Clip
    let natSize: CGSize
    let preferredTransform: CGAffineTransform

    var trackID: CMPersistentTrackID? {
        if case .track(let id) = source { return id }
        return nil
    }
}

/// One timeline segment between clip boundaries. Layers are ordered bottom → top.
final class CompositorInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = true
    // Values are sampled per frame; never let AVFoundation cache one frame per instruction.
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let layers: [LayerPlan]
    let renderSize: CGSize
    let fps: Int

    init(timeRange: CMTimeRange, layers: [LayerPlan], renderSize: CGSize, fps: Int) {
        self.timeRange = timeRange
        self.layers = layers
        self.renderSize = renderSize
        self.fps = fps
        var seen = Set<CMPersistentTrackID>()
        self.requiredSourceTrackIDs = layers.compactMap {
            guard let id = $0.trackID else { return nil }  // text layers need no decoded source
            return seen.insert(id).inserted ? NSNumber(value: id) : nil
        }
        super.init()
    }
}
