import CoreImage
import Foundation

/// Lift/Gamma/Gain primary color wheels. Each wheel is a luma-neutral chroma offset (its pad
/// position) plus a master luma scalar; the per-channel coefficients feed a per-pixel kernel
/// applying `((in·(1−L) + L) · Gain) ^ (1/Gamma)`.
enum ColorWheels {
    private static let chromaLift = 0.2
    private static let chromaGain = 0.35
    private static let chromaGamma = 0.35

    /// Fully-saturated hue at `h ∈ [0,1)`.
    static func hueRGB(_ h: Double) -> (Double, Double, Double) {
        let x = (h - floor(h)) * 6
        let f = x - floor(x)
        switch Int(x) % 6 {
        case 0: return (1, f, 0)
        case 1: return (1 - f, 1, 0)
        case 2: return (0, 1, f)
        case 3: return (0, 1 - f, 1)
        case 4: return (f, 0, 1)
        default: return (1, 0, 1 - f)
        }
    }

    /// Luma-neutral per-channel offset for a pad position (angle = hue, radius = strength).
    static func chromaOffset(x: Double, y: Double) -> (Double, Double, Double) {
        let r = min(1, (x * x + y * y).squareRoot())
        guard r > 1e-6 else { return (0, 0, 0) }
        let (cr, cg, cb) = hueRGB(atan2(y, x) / (2 * .pi))
        let mean = (cr + cg + cb) / 3
        return ((cr - mean) * r, (cg - mean) * r, (cb - mean) * r)
    }

    /// Wheel-face color — a dark, lightly tinted body fading to a vivid saturated rim
    static func displayColor(x: Double, y: Double) -> (Double, Double, Double) {
        let r = min(1, (x * x + y * y).squareRoot())
        let (hr, hg, hb) = hueRGB(atan2(y, x) / (2 * .pi))
        let v = 0.08 + 0.5 * pow(r, 1.7)
        let s = pow(r, 1.4)
        let rim = rimRamp((r - 0.86) / 0.14)
        func face(_ h: Double) -> Double {
            let body = v * ((1 - s) + h * s)
            return body + (h - body) * rim
        }
        return (face(hr), face(hg), face(hb))
    }

    private static func rimRamp(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        return x * x * (3 - 2 * x)
    }

    static func isNeutral(_ p: ResolvedEffectParams) -> Bool {
        p.value("lift_x") == 0 && p.value("lift_y") == 0 && p.value("lift_m") == 0 &&
        p.value("gamma_x") == 0 && p.value("gamma_y") == 0 && p.value("gamma_m") == 1 &&
        p.value("gain_x") == 0 && p.value("gain_y") == 0 && p.value("gain_m") == 1
    }

    /// Per-channel lift / gain / inverse-gamma for the resolved wheel params
    static func coefficients(for p: ResolvedEffectParams)
        -> (lift: SIMD3<Float>, gain: SIMD3<Float>, invGamma: SIMD3<Float>) {
        let lift = chromaOffset(x: p.value("lift_x"), y: p.value("lift_y"))
        let gamma = chromaOffset(x: p.value("gamma_x"), y: p.value("gamma_y"))
        let gain = chromaOffset(x: p.value("gain_x"), y: p.value("gain_y"))
        let liftM = p.value("lift_m"), gammaM = p.value("gamma_m"), gainM = p.value("gain_m")
        func l(_ c: Double) -> Float { Float(liftM + c * chromaLift) }
        func g(_ c: Double) -> Float { Float(gainM * (1 + c * chromaGain)) }
        func ig(_ c: Double) -> Float { Float(1 / max(0.01, gammaM * (1 + c * chromaGamma))) }
        return (SIMD3(l(lift.0), l(lift.1), l(lift.2)),
                SIMD3(g(gain.0), g(gain.1), g(gain.2)),
                SIMD3(ig(gamma.0), ig(gamma.1), ig(gamma.2)))
    }
}
