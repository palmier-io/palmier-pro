import AVFoundation

extension AVVideoComposition {
    func palmierConfiguration() -> AVVideoComposition.Configuration {
        var config = AVVideoComposition.Configuration()
        config.customVideoCompositorClass = customVideoCompositorClass
        config.frameDuration = frameDuration
        config.sourceTrackIDForFrameTiming = sourceTrackIDForFrameTiming
        config.renderSize = renderSize
        config.renderScale = renderScale
        config.instructions = instructions
        config.animationTool = animationTool
        config.sourceSampleDataTrackIDs = sourceSampleDataTrackIDs
        return config
    }
}
