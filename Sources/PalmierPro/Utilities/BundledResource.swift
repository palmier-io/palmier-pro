import Foundation

private final class BundledResourceToken {}

enum BundledResource {
    static func url(_ path: String) -> URL? {
        let buildDirectory = Bundle(for: BundledResourceToken.self).bundleURL.deletingLastPathComponent()
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(path),
            Bundle.main.resourceURL?.appendingPathComponent("PalmierPro_PalmierPro.bundle/\(path)"),
            buildDirectory.appendingPathComponent("PalmierPro_PalmierPro.bundle/\(path)"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
