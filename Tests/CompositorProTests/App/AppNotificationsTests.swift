import Foundation
import Testing
@testable import CompositorPro

@Suite("App notifications", .serialized)
@MainActor
struct AppNotificationsTests {
    @Test(arguments: [
        (ClipType.video, "2 videos are ready in Compositor Pro."),
        (.audio, "2 audio clips are ready in Compositor Pro."),
        (.image, "2 images are ready in Compositor Pro."),
        (.text, "2 text clips are ready in Compositor Pro."),
        (.lottie, "2 Lottie animations are ready in Compositor Pro."),
        (.sequence, "2 videos are ready in Compositor Pro."),
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

    @Test("The completion sound is on until the user turns it off")
    func agentSoundDefaultsOnAndPersists() {
        let key = "io.compositor.pro.agent.sound.enabled"
        let existing = UserDefaults.standard.object(forKey: key)
        defer {
            if let existing {
                UserDefaults.standard.set(existing, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        UserDefaults.standard.removeObject(forKey: key)
        #expect(AppNotifications.agentSoundEnabled)

        AppNotifications.agentSoundEnabled = false
        #expect(!AppNotifications.agentSoundEnabled)

        AppNotifications.agentSoundEnabled = true
        #expect(AppNotifications.agentSoundEnabled)
    }
}
