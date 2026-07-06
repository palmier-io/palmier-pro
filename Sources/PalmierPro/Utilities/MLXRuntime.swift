import Foundation

// Skip MLX model loads in unbundled builds to avoid a fatal mlx.metallib error.
enum MLXRuntime {
    static let isAvailable = Bundle.main.bundleURL.pathExtension == "app"

    struct Unavailable: Error, LocalizedError {
        var errorDescription: String? {
            "MLX analysis is unavailable in unbundled builds (missing mlx.metallib)"
        }
    }

    static func requireAvailable() throws {
        guard isAvailable else { throw Unavailable() }
    }
}
