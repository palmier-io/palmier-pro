import Foundation

enum AudioSyncCorrelator {
    struct Result: Sendable, Equatable {
        let lagHops: Int
        let confidence: Double
    }

    static let minOverlap = 16

    static func correlate(reference: [Float], target: [Float], maxLagHops: Int) -> Result? {
        guard !reference.isEmpty, !target.isEmpty, maxLagHops >= 0 else { return nil }

        let ref = reference.map(Double.init)
        let tgt = target.map(Double.init)

        var best: Result?
        for lag in -maxLagHops...maxLagHops {
            let iStart = max(0, -lag)
            let iEnd = min(tgt.count, ref.count - lag)
            let n = iEnd - iStart
            guard n >= minOverlap else { continue }

            var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
            var i = iStart
            while i < iEnd {
                let x = tgt[i]
                let y = ref[i + lag]
                sx += x; sy += y
                sxx += x * x; syy += y * y
                sxy += x * y
                i += 1
            }
            let nD = Double(n)
            let cov = sxy - sx * sy / nD
            let vx = sxx - sx * sx / nD
            let vy = syy - sy * sy / nD
            let denom = (vx * vy).squareRoot()
            guard denom > 0 else { continue }

            let score = max(0, cov / denom)
            if best == nil || score > best!.confidence {
                best = Result(lagHops: lag, confidence: score)
            }
        }
        return best
    }
}
