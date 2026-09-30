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
        let buildDirectory = Bundle(for: BundledResourceToken.self).bundleURL.deletingLastPathComponent()
        // `bundle.resourceURL` is the only candidate that survives a resource bundle that nests
        // its payload under Contents/Resources, which is how newer SwiftPM emits them.
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(path),
            bundle.resourceURL?.appendingPathComponent(path),
            Bundle.main.resourceURL?.appendingPathComponent("CompositorPro_CompositorPro.bundle/\(path)"),
            buildDirectory.appendingPathComponent("CompositorPro_CompositorPro.bundle/\(path)"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
