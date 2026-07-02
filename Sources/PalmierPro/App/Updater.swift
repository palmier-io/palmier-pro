import AppKit
import Sparkle

@MainActor @Observable
final class Updater: NSObject {
    static let shared = Updater()

    private(set) var updateAvailable = false
    private(set) var updateVersion: String?

    private var controller: SPUStandardUpdaterController?
    private var lastBackgroundCheck: Date?
    private var notificationObservers: [NSObjectProtocol] = []

    private override init() {
        super.init()
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        self.controller = controller
        installObservers(updater: controller.updater)
        checkForUpdateInformation()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        controller?.checkForUpdates(sender)
    }

    private func checkForUpdateInformation() {
        lastBackgroundCheck = Date()
        controller?.updater.checkForUpdateInformation()
    }

    private func checkForUpdateIfStale() {
        guard controller != nil else { return }
        let now = Date()
        if let lastBackgroundCheck, now.timeIntervalSince(lastBackgroundCheck) < 3600 { return }
        checkForUpdateInformation()
    }

    private func installObservers(updater: SPUUpdater) {
        let center = NotificationCenter.default

        notificationObservers.append(
            center.addObserver(
                forName: .SUUpdaterDidFindValidUpdate,
                object: updater,
                queue: .main
            ) { [weak self] notification in
                guard let item = notification.userInfo?[SUUpdaterAppcastItemNotificationKey] as? SUAppcastItem else {
                    return
                }
                Task { @MainActor in
                    self?.markUpdateAvailable(item)
                }
            }
        )

        notificationObservers.append(
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.checkForUpdateIfStale()
                }
            }
        )
    }

    private func markUpdateAvailable(_ item: SUAppcastItem) {
        updateAvailable = true
        updateVersion = item.displayVersionString
    }

    private func clearUpdateAvailability() {
        updateAvailable = false
        updateVersion = nil
    }

    private func shouldClearAfterNoUpdateFound(_ error: NSError) -> Bool {
        let reasonRaw = (error.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue
            ?? Int(SPUNoUpdateFoundReason.unknown.rawValue)
        switch SPUNoUpdateFoundReason(rawValue: Int32(reasonRaw)) {
        case .onLatestVersion, .onNewerThanLatestVersion:
            return true
        default:
            return false
        }
    }
}

extension Updater: SPUUpdaterDelegate {
    @objc func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        markUpdateAvailable(item)
    }

    @objc func updaterDidNotFindUpdate(_ updater: SPUUpdater) {}

    @objc func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        guard let error = error as NSError?, shouldClearAfterNoUpdateFound(error) else { return }
        clearUpdateAvailability()
    }
}
