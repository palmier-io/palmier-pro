import AppKit
import Sparkle

@MainActor @Observable
final class Updater: NSObject {
    static let shared = Updater()

    private(set) var updateAvailable = false
    private(set) var updateVersion: String?

    private var controller: SPUStandardUpdaterController?

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
        controller.updater.checkForUpdateInformation()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        controller?.checkForUpdates(sender)
    }

    func dismissUpdate() {
        clearUpdateAvailability()
    }

    private func markUpdateAvailable(_ item: SUAppcastItem) {
        updateAvailable = true
        updateVersion = item.displayVersionString
    }

    private func clearUpdateAvailability() {
        updateAvailable = false
        updateVersion = nil
    }
}

extension Updater: SPUUpdaterDelegate {
    @objc func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        markUpdateAvailable(item)
    }

    @objc func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        clearUpdateAvailability()
    }
}
