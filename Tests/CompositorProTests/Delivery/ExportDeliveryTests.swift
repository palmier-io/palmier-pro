import CoreGraphics
import Foundation
import Testing
@testable import CompositorPro

@Suite("Export delivery presets")
struct ExportDeliveryTests {
    private let landscape = CGSize(width: 1920, height: 1080)
    private let portrait = CGSize(width: 1080, height: 1920)
    private let square = CGSize(width: 1080, height: 1080)

    @Test("Every platform resolves to a real codec and a real resolution")
    func resolvesForEveryPlatform() {
        for platform in DeliveryPlatform.allCases {
            let delivery = platform.exportDelivery(canvas: portrait)
            #expect(delivery.codec == .h264)
            #expect(delivery.resolution == (platform == .generic ? .matchTimeline : .r1080p))
            #expect(delivery.outputSize.width > 0 && delivery.outputSize.height > 0)
        }
    }

    @Test("Generic leaves the timeline alone")
    func genericMatchesTimeline() {
        #expect(exportSize(.generic, portrait) == "1080x1920")
        #expect(DeliveryPlatform.generic.exportDelivery(canvas: landscape).outputSize == landscape)
    }

    private func exportSize(_ platform: DeliveryPlatform, _ canvas: CGSize) -> String {
        let size = platform.exportDelivery(canvas: canvas).outputSize
        return "\(Int(size.width))x\(Int(size.height))"
    }

    @Test("A short-form delivery of a portrait canvas keeps the portrait size")
    func portraitDeliveryIsNotClamped() {
        #expect(exportSize(.tiktokShorts, portrait) == "1080x1920")
        #expect(exportSize(.instagramReels, portrait) == "1080x1920")
    }

    @Test("A short-form delivery of a landscape canvas still exports at 1080p")
    func landscapeDeliveryScalesNormally() {
        #expect(exportSize(.tiktokShorts, landscape) == "1920x1080")
    }

    @Test("A mismatched canvas orientation is reported, not silently letterboxed")
    func mismatchIsReported() {
        let shortFormOnLandscape = DeliveryPlatform.tiktokShorts.exportDelivery(canvas: landscape)
        #expect(shortFormOnLandscape.orientationWarning != nil)
        #expect(shortFormOnLandscape.orientationWarning?.contains("landscape") == true)

        let youtubeOnPortrait = DeliveryPlatform.youtube.exportDelivery(canvas: portrait)
        #expect(youtubeOnPortrait.orientationWarning != nil)

        let shortFormOnPortrait = DeliveryPlatform.tiktokShorts.exportDelivery(canvas: portrait)
        #expect(shortFormOnPortrait.orientationWarning == nil, "a matched canvas reports nothing")

        #expect(DeliveryPlatform.generic.exportDelivery(canvas: square).orientationWarning == nil)
    }

    @Test("Square is acceptable to generic and YouTube but not to a vertical platform")
    func squareTreatment() {
        // A square canvas is not portrait, so Shorts and Reels should hear about it: they are
        // delivered 9:16 and a square upload letterboxes.
        #expect(DeliveryPlatform.generic.exportDelivery(canvas: square).orientationWarning == nil)
        #expect(DeliveryPlatform.youtube.exportDelivery(canvas: square).orientationWarning == nil)
        #expect(DeliveryPlatform.tiktokShorts.exportDelivery(canvas: square).orientationWarning != nil)
        #expect(DeliveryPlatform.instagramReels.exportDelivery(canvas: square).orientationWarning != nil)
    }
}