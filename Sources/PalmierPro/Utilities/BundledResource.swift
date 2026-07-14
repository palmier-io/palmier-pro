import Foundation

enum BundledResource {
    static func url(_ path: String) -> URL? {
        guard let root = Bundle.main.resourceURL else { return nil }
        let candidates = [
            root.appendingPathComponent(path),
            root.appendingPathComponent("PalmierPro_PalmierPro.bundle/\(path)"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
