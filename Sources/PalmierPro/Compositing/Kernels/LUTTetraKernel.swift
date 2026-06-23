import CoreImage
import Foundation

/// Applies a 3D `.cube` LUT with tetrahedral interpolation via a Metal kernel
enum LUTTetraKernel {
    private static let kernel = CIKernelLoader.kernel("LUTTetra", "lutTetra")

    /// `key` (the LUT's file path) caches the strip image so it isn't re-wrapped/re-uploaded per frame.
    static func apply(_ image: CIImage, cube: LUTLoader.CubeLUT, key: String, intensity: Double) -> CIImage {
        guard let kernel else { return image }
        let lut = Cache.image(for: key, cube: cube)
        return kernel.apply(extent: image.extent,
                            roiCallback: { index, rect in index == 0 ? rect : lut.extent },
                            arguments: [image, lut, Float(cube.dimension), Float(intensity)]) ?? image
    }

    private enum Cache {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var store: [String: CIImage] = [:]

        static func image(for key: String, cube: LUTLoader.CubeLUT) -> CIImage {
            lock.lock(); defer { lock.unlock() }
            if let hit = store[key] { return hit }
            if store.count > 16 { store.removeAll() }
            let n = cube.dimension
            let img = CIImage(bitmapData: cube.data, bytesPerRow: n * 16,
                              size: CGSize(width: n, height: n * n), format: .RGBAf, colorSpace: nil)
            store[key] = img
            return img
        }
    }
}
