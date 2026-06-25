import AppKit
import Foundation
import UserNotifications

@MainActor
enum AppNotifications {
    private static let enabledKey = "io.palmier.pro.notifications.enabled"

    static var isEnabled: Bool {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: enabledKey) == nil { return true }
            return defaults.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }

    static func configure() {
        guard canUseUserNotifications else {
            Log.app.notice("notifications disabled outside app bundle")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = AppNotificationDelegate.shared
        guard isEnabled else {
            Log.app.notice("notifications disabled in settings")
            return
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Log.app.warning("notification authorization failed error=\(error.localizedDescription)")
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
        guard canUseUserNotifications, isEnabled else { return }

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
                Log.app.warning("notification delivery failed error=\(error.localizedDescription)")
            }
        }
    }

    /// Agent-triggered exports run in the background
    static func exportComplete(name: String, outputURL: URL, size: CGSize?, warningCount: Int) {
        guard canUseUserNotifications, isEnabled else { return }

        var detail = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty { detail = "Export" }
        if let size { detail += " (\(Int(size.width))×\(Int(size.height)))" }

        let content = UNMutableNotificationContent()
        content.title = "Export complete"
        content.body = warningCount > 0
            ? "\(detail) exported with \(warningCount) warning\(warningCount == 1 ? "" : "s")."
            : "\(detail) is ready."
        content.sound = .default
        content.userInfo = ["exportPath": outputURL.path]

        let request = UNNotificationRequest(
            identifier: "export-complete-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.app.warning("notification delivery failed error=\(error.localizedDescription)")
            }
        }
    }

    static func exportFailed(name: String, reason: String) {
        guard canUseUserNotifications, isEnabled else { return }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = UNMutableNotificationContent()
        content.title = "Export failed"
        content.body = trimmedReason.isEmpty
            ? "\(trimmedName.isEmpty ? "The export" : trimmedName) could not be exported."
            : trimmedReason
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "export-failed-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.app.warning("notification delivery failed error=\(error.localizedDescription)")
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
        await AppNotifications.isEnabled ? [.banner, .sound] : []
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        if let exportPath = userInfo["exportPath"] as? String {
            let url = URL(fileURLWithPath: exportPath)
            await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            return
        }
        let assetId = userInfo["assetId"] as? String
        let projectURL = (userInfo["projectPath"] as? String).map(URL.init(fileURLWithPath:))
        await AppState.shared.revealGeneratedAssetFromNotification(assetId: assetId, projectURL: projectURL)
    }
}
