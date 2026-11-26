import CoreImage
import Foundation

/// Per-pixel hue curves via a runtime Core Image kernel.
/// Three hue curves are combined into a 256-wide LUT (R=Δhue, G=satScale, B=Δlum),
/// sampled per-pixel by the kernel at pixel hue. This reduces lookup cost and ensures smooth gradients.
/// Shifts are gated by saturation, keeping near-grays neutral. Operates in display-space HSV,
/// avoiding luma rescale artifacts. Kernel source: `Metal/HueCurves.metal`, compiled and loaded here.
enum HueCurveKernel {
    static let lutWidth = 256
    private static let maxHueShift = 1.0 / 12   // ±30° at a full push
    private static let maxLumShift = 0.5

    private static let kernel = CIKernelLoader.kernel("HueCurves", "hueCurves")

    static func apply(_ image: CIImage, curves: HueCurves) -> CIImage {
        guard !curves.isIdentity, let kernel else { return image }
        let lut = Cache.lut(for: curves)
        return kernel.apply(extent: image.extent,
                            roiCallback: { index, rect in index == 0 ? rect : lut.extent },
                            arguments: [image, lut]) ?? image
    }

    private static func buildLUT(_ curves: HueCurves) -> CIImage {
        let w = lutWidth
        var px = [Float](repeating: 0, count: w * 4)
        for i in 0..<w {
            let hue = (Double(i) + 0.5) / Double(w)
            let dHue = (HueCurves.eval(curves.hueVsHue, hue) - 0.5) * 2 * maxHueShift
            let satScale = (HueCurves.eval(curves.hueVsSat, hue) - 0.5) * 2
            let dLum = (HueCurves.eval(curves.hueVsLum, hue) - 0.5) * 2 * maxLumShift
            px[i * 4] = Float(dHue)
            px[i * 4 + 1] = Float(satScale)
            px[i * 4 + 2] = Float(dLum)
            px[i * 4 + 3] = 1
        }
        return px.withUnsafeBytes {
            CIImage(bitmapData: Data($0), bytesPerRow: w * 16,
                    size: CGSize(width: w, height: 1), format: .RGBAf, colorSpace: nil)
        }
    }

    /// Caches one LUT image per curve set so the table builds once per grade, not per frame.
    private enum Cache {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var store: [String: CIImage] = [:]

        static func lut(for curves: HueCurves) -> CIImage {
            let key = curves.encoded() ?? ""
            lock.lock(); defer { lock.unlock() }
            if let hit = store[key] { return hit }
            if store.count > 64 { store.removeAll() }
            let lut = buildLUT(curves)
            store[key] = lut
            return lut
        }
    }
}
