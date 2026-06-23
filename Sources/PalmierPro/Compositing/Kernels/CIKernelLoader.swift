import CoreImage
import Foundation

/// Loads Core Image kernels from the plugin-compiled `.metallib` resources.
enum CIKernelLoader {
    private static func metallibURL(_ lib: String) -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let candidates = [
            resourceURL.appendingPathComponent("\(lib).metallib"),
            resourceURL.appendingPathComponent("PalmierPro_PalmierPro.bundle/\(lib).metallib"),
        ]
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
