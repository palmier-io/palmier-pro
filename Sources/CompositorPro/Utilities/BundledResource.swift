import Foundation

private final class BundledResourceToken {}

enum BundledResource {
    static let bundle: Bundle = {
        guard Bundle.main.bundleURL.pathExtension != "app" else { return .main }
        let buildDirectory = Bundle(for: BundledResourceToken.self).bundleURL.deletingLastPathComponent()
        let resourceBundleURL = buildDirectory.appendingPathComponent("CompositorPro_CompositorPro.bundle")
        return Bundle(url: resourceBundleURL) ?? .main
    }()

    static func url(_ path: String) -> URL? {
        let tokenBundle = Bundle(for: BundledResourceToken.self)
        let buildDirectory = tokenBundle.bundleURL.deletingLastPathComponent()
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(path),
            bundle.resourceURL?.appendingPathComponent(path),
            bundle.resourceURL?.appendingPathComponent("Contents/Resources/\(path)"),
            tokenBundle.resourceURL?.appendingPathComponent("CompositorPro_CompositorPro.bundle/Contents/Resources/\(path)"),
            tokenBundle.resourceURL?.appendingPathComponent("CompositorPro_CompositorPro.bundle/\(path)"),
            buildDirectory.appendingPathComponent("CompositorPro_CompositorPro.bundle/Contents/Resources/\(path)"),
            buildDirectory.appendingPathComponent("CompositorPro_CompositorPro.bundle/\(path)"),
            Bundle.main.resourceURL?.appendingPathComponent("CompositorPro_CompositorPro.bundle/Contents/Resources/\(path)"),
            Bundle.main.resourceURL?.appendingPathComponent("CompositorPro_CompositorPro.bundle/\(path)"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
