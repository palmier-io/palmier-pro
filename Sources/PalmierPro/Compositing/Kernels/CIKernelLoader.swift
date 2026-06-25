import CoreImage
import Foundation

private final class CIKernelBundleToken {}

/// Loads Core Image kernels from the plugin-compiled `.metallib` resources.
enum CIKernelLoader {
    private static func metallibURL(_ lib: String) -> URL? {
        let buildDir = Bundle(for: CIKernelBundleToken.self).bundleURL.deletingLastPathComponent()
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("\(lib).metallib"),                             // packaged .app
            Bundle.main.resourceURL?.appendingPathComponent("PalmierPro_PalmierPro.bundle/\(lib).metallib"), // swift run
            buildDir.appendingPathComponent("PalmierPro_PalmierPro.bundle/\(lib).metallib"),                 // swift test
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func data(_ lib: String) -> Data? {
        metallibURL(lib).flatMap { try? Data(contentsOf: $0) }
    }

    static func kernel(_ lib: String, _ function: String) -> CIKernel? {
        data(lib).flatMap { try? CIKernel(functionName: function, fromMetalLibraryData: $0) }
    }

    static func colorKernel(_ lib: String, _ function: String) -> CIColorKernel? {
        data(lib).flatMap { try? CIColorKernel(functionName: function, fromMetalLibraryData: $0) }
    }
}
