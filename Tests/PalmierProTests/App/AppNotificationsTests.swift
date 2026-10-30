import Testing
@testable import PalmierPro

@Suite("App notifications")
@MainActor
struct AppNotificationsTests {
    @Test(arguments: [
        (ClipType.video, "2 videos are ready in Palmier Pro."),
        (.audio, "2 audio clips are ready in Palmier Pro."),
        (.image, "2 images are ready in Palmier Pro."),
        (.text, "2 text clips are ready in Palmier Pro."),
        (.lottie, "2 Lottie animations are ready in Palmier Pro."),
        (.sequence, "2 videos are ready in Palmier Pro."),
    ])
    func generatedAssetCountsUseCompleteMessages(type: ClipType, expected: String) {
        #expect(AppNotifications.generationBody(assetName: "", assetType: type, count: 2) == expected)
    }

    @Test(arguments: [
        (ClipType.video, "Your video is ready."),
        (.audio, "Your audio clip is ready."),
        (.image, "Your image is ready."),
        (.text, "Your text clip is ready."),
        (.lottie, "Your Lottie animation is ready."),
        (.sequence, "Your video is ready."),
    ])
    func unnamedGeneratedAssetsUseCompleteMessages(type: ClipType, expected: String) {
        #expect(AppNotifications.generationBody(assetName: " ", assetType: type, count: 1) == expected)
    }
}
