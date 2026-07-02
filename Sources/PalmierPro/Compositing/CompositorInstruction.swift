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
    /// Composition track carrying this clip's baked person-mask matte, if any — see `PersonMaskBaker`.
    var personMaskTrackID: CMPersistentTrackID? = nil

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
        var ids: [NSValue] = []
        for layer in layers {
            for id in [layer.trackID, layer.personMaskTrackID].compactMap({ $0 }) where seen.insert(id).inserted {
                ids.append(NSNumber(value: id))
            }
        }
        self.requiredSourceTrackIDs = ids
        super.init()
    }
}
