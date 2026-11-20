import CoreImage
import Foundation

/// Per-pixel tone curves via a Metal CI kernel
enum GradeCurveKernel {
    static let lutWidth = 256

    private static let kernel = CIKernelLoader.kernel("GradeCurves", "gradeCurves")

    static func apply(_ image: CIImage, curve: GradeCurve) -> CIImage {
        guard !curve.isIdentity, let kernel else { return image }
        let lut = Cache.luts(for: curve)
        return kernel.apply(extent: image.extent,
                            roiCallback: { index, rect in index == 0 ? rect : lut.channels.extent },
                            arguments: [image, lut.channels, lut.master]) ?? image
    }

    private static func buildLUTs(_ c: GradeCurve) -> (channels: CIImage, master: CIImage) {
        let w = lutWidth
        var ch = [Float](repeating: 0, count: w * 4)
        var ms = [Float](repeating: 0, count: w * 4)
        func cl(_ v: Double) -> Float { Float(min(1, max(0, v))) }
        for x in 0..<w {
            let t = Double(x) / Double(w - 1)
            ch[x * 4] = cl(GradeCurve.eval(c.red, t))
            ch[x * 4 + 1] = cl(GradeCurve.eval(c.green, t))
            ch[x * 4 + 2] = cl(GradeCurve.eval(c.blue, t))
            ch[x * 4 + 3] = 1
            let m = cl(GradeCurve.eval(c.master, t))
            ms[x * 4] = m; ms[x * 4 + 1] = m; ms[x * 4 + 2] = m; ms[x * 4 + 3] = 1
        }
        func image(_ a: [Float]) -> CIImage {
            a.withUnsafeBytes {
                CIImage(bitmapData: Data($0), bytesPerRow: w * 16,
                        size: CGSize(width: w, height: 1), format: .RGBAf, colorSpace: nil)
            }
        }
        return (image(ch), image(ms))
    }

    /// Caches the two LUT images per curve so they build once per grade, not per frame.
    private enum Cache {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var store: [String: (channels: CIImage, master: CIImage)] = [:]

        static func luts(for curve: GradeCurve) -> (channels: CIImage, master: CIImage) {
            let key = curve.encoded() ?? ""
            lock.lock(); defer { lock.unlock() }
            if let hit = store[key] { return hit }
            if store.count > 64 { store.removeAll() }
            let luts = buildLUTs(curve)
            store[key] = luts
            return luts
        }
    }
}
