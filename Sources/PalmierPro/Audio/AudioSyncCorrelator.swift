import Accelerate
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
        ref.withUnsafeBufferPointer { refBuf in
            tgt.withUnsafeBufferPointer { tgtBuf in
                let refBase = refBuf.baseAddress!
                let tgtBase = tgtBuf.baseAddress!
                for lag in -maxLagHops...maxLagHops {
                    let iStart = max(0, -lag)
                    let iEnd = min(tgt.count, ref.count - lag)
                    let n = iEnd - iStart
                    guard n >= minOverlap else { continue }

                    // x = tgt[iStart ..< iEnd], y = ref[iStart+lag ..< iEnd+lag]
                    let x = tgtBase + iStart
                    let y = refBase + iStart + lag
                    let count = vDSP_Length(n)

                    var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
                    vDSP_sveD(x, 1, &sx, count)
                    vDSP_svesqD(x, 1, &sxx, count)
                    vDSP_sveD(y, 1, &sy, count)
                    vDSP_svesqD(y, 1, &syy, count)
                    vDSP_dotprD(x, 1, y, 1, &sxy, count)

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
            }
        }
        return best
    }
}
