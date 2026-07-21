// Speech-model install root, separate from the search embedder's tree — Search's "Remove model"
// deletes its whole directory, and multi-GB ASR installs must not ride along (nor be attributed
// to the search model's size in Storage settings).
import Foundation

enum SpeechModels {
    static let dir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PalmierPro/SpeechModels")

    /// Resolve an install directory, migrating a pre-split install from the shared models tree
    /// so existing users don't re-download. Call from off-main contexts only (engine actors).
    static func installDir(named name: String) -> URL {
        let target = dir.appendingPathComponent(name, isDirectory: true)
        let legacy = ModelDownloader.modelsDir.appendingPathComponent(name, isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: target.path), fm.fileExists(atPath: legacy.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? fm.moveItem(at: legacy, to: target)
        }
        return target
    }
}
