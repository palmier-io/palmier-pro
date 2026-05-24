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
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    @objc func checkForUpdates(_ sender: Any?) {
        controller?.checkForUpdates(sender)
    }

    func dismissUpdate() {
        updateAvailable = false
    }
}

extension Updater: SPUUpdaterDelegate {
    @objc func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        updateAvailable = true
        updateVersion = item.displayVersionString
    }

    @objc func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        updateAvailable = false
        updateVersion = nil
    }
}
