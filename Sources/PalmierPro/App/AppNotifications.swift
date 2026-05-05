import Foundation
import UserNotifications

@MainActor
enum AppNotifications {
    static func configure() {
        guard canUseUserNotifications else {
            Log.app.notice("notifications disabled outside app bundle")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = AppNotificationDelegate.shared
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Log.app.error("notification authorization failed error=\(error.localizedDescription)")
            } else {
                Log.app.notice("notification authorization \(granted ? "granted" : "denied")")
            }
        }
    }

    static func generationComplete(
        assetId: String,
        projectURL: URL?,
        assetName: String,
        assetType: ClipType,
        count: Int
    ) {
        guard canUseUserNotifications else { return }

        let content = UNMutableNotificationContent()
        content.title = "Generation complete"
        content.body = body(assetName: assetName, assetType: assetType, count: count)
        content.sound = .default
        var userInfo = ["assetId": assetId]
        if let projectURL {
            userInfo["projectPath"] = projectURL.path
        }
        content.userInfo = userInfo

        let request = UNNotificationRequest(
            identifier: "generation-complete-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.app.error("notification delivery failed error=\(error.localizedDescription)")
            }
        }
    }

    private static var canUseUserNotifications: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
            && (Bundle.main.bundleIdentifier?.contains(".") ?? false)
    }

    private static func body(assetName: String, assetType: ClipType, count: Int) -> String {
        if count > 1 {
            return "\(count) \(assetType.rawValue)s are ready in Palmier Pro."
        }
        let name = assetName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Your \(assetType.rawValue) is ready." : "\(name) is ready."
    }
}

private final class AppNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    @MainActor
    static let shared = AppNotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let assetId = userInfo["assetId"] as? String
        let projectURL = (userInfo["projectPath"] as? String).map(URL.init(fileURLWithPath:))
        await AppState.shared.revealGeneratedAssetFromNotification(assetId: assetId, projectURL: projectURL)
    }
}
