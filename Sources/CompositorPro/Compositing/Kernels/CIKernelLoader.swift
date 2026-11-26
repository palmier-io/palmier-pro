import CoreImage
import Foundation

/// Loads Core Image kernels from the plugin-compiled `.metallib` resources.
enum CIKernelLoader {
    private static func data(_ lib: String) -> Data? {
        BundledResource.url("\(lib).metallib").flatMap { try? Data(contentsOf: $0) }
    }

    static func kernel(_ lib: String, _ function: String) -> CIKernel? {
        data(lib).flatMap { try? CIKernel(functionName: function, fromMetalLibraryData: $0) }
    }

    static func colorKernel(_ lib: String, _ function: String) -> CIColorKernel? {
        data(lib).flatMap { try? CIColorKernel(functionName: function, fromMetalLibraryData: $0) }
    }
}
