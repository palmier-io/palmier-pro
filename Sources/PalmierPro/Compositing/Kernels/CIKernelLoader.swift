import CoreImage
import Foundation

/// Loads Core Image kernels from the plugin-compiled `.metallib` resources.
/// Avoids `Bundle.module`, whose SwiftPM-generated accessor only checks the build-machine path
/// and the .app root, then fatalErrors — it crashed shipped builds (PALMIER-PRO-EN). Search the
/// places the metallibs actually live across the packaged .app, `swift run`, and `swift test`.
enum CIKernelLoader {
    private final class BundleToken {}

    private static func metallibURL(_ lib: String) -> URL? {
        let file = "\(lib).metallib"
        let resBundle = "PalmierPro_PalmierPro.bundle"
        var roots: [URL] = []
        if let r = Bundle.main.resourceURL { roots.append(r) }      // packaged .app: Contents/Resources
        roots.append(Bundle.main.bundleURL)                          // swift run: beside the executable
        roots.append(Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent())   // swift test: build-products dir
        let candidates = roots.flatMap {
            [$0.appendingPathComponent(file),                        // flattened by bundle.sh
             $0.appendingPathComponent("\(resBundle)/\(file)")]      // inside the SwiftPM resource bundle
        }
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
