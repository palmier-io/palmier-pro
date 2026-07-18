import Accelerate
import Foundation

enum AudioSyncCorrelator {
    struct Result: Sendable, Equatable {
        let lagHops: Int
        let confidence: Double
    }

    static let minOverlap = 16
    private static let coarseStride = 4

    static func seededCorrelate(
        reference: [Float], target: [Float], seedHops: Int?, seedWindowHops: Int,
        maxLagHops: Int, minOverlapHops: Int, minConfidence: Double,
        additionalSearchCenterHops: [Int] = []
    ) async -> Result? {
        let result = await Task.detached(priority: .userInitiated) { () -> Result? in
            var best = correlate(
                reference: reference, target: target, maxLagHops: maxLagHops,
                minOverlapHops: minOverlapHops
            )
            for center in Set(additionalSearchCenterHops) where center != 0 {
                guard !Task.isCancelled else { return nil }
                let candidate = correlate(
                    reference: reference, target: target, maxLagHops: maxLagHops,
                    centerLagHops: center, minOverlapHops: minOverlapHops
                )
                if let candidate, candidate.confidence > (best?.confidence ?? -.infinity) {
                    best = candidate
                }
            }
            if let seedHops {
                guard !Task.isCancelled else { return nil }
                let seeded = correlate(
                    reference: reference, target: target, maxLagHops: seedWindowHops,
                    centerLagHops: seedHops, minOverlapHops: minOverlapHops
                )
                if let seeded, seeded.confidence > (best?.confidence ?? -.infinity) {
                    best = seeded
                }
            }
            return best
        }.value
        guard let result, result.confidence >= minConfidence else { return nil }
        return result
    }

    static func correlate(
        reference: [Float], target: [Float], maxLagHops: Int,
        centerLagHops: Int = 0, minOverlapHops: Int = minOverlap
    ) -> Result? {
        guard !reference.isEmpty, !target.isEmpty, maxLagHops >= 0 else { return nil }
        let shorterCount = min(reference.count, target.count)
        let adaptiveOverlap = max(minOverlap, shorterCount / 2)
        let requiredOverlap = min(max(minOverlap, minOverlapHops), adaptiveOverlap)
        guard shorterCount >= requiredOverlap else { return nil }

        let validLags = (requiredOverlap - target.count)...(reference.count - requiredOverlap)
        let requestedLower = centerLagHops.subtractingClamped(maxLagHops)
        let requestedUpper = centerLagHops.addingClamped(maxLagHops)
        let lower = max(validLags.lowerBound, requestedLower)
        let upper = min(validLags.upperBound, requestedUpper)
        guard lower <= upper else { return nil }

        let lagRange = lower...upper
        guard lagRange.count > coarseStride * 8,
              reference.count >= coarseStride * minOverlap,
              target.count >= coarseStride * minOverlap else {
            return correlateExact(
                reference: reference, target: target,
                lagRange: lagRange, minOverlapHops: requiredOverlap
            )
        }

        let coarseReference = downsample(reference, stride: coarseStride)
        let coarseTarget = downsample(target, stride: coarseStride)
        let coarseLower = Int(floor(Double(lower) / Double(coarseStride)))
        let coarseUpper = Int(ceil(Double(upper) / Double(coarseStride)))
        let coarseOverlap = max(minOverlap, (requiredOverlap + coarseStride - 1) / coarseStride)
        guard let coarse = correlateExact(
            reference: coarseReference, target: coarseTarget,
            lagRange: coarseLower...coarseUpper, minOverlapHops: coarseOverlap
        ) else { return nil }

        let coarseLag = coarse.lagHops * coarseStride
        let refinementRadius = coarseStride * 2
        let refinementRange = max(lower, coarseLag - refinementRadius)...min(upper, coarseLag + refinementRadius)
        return correlateExact(
            reference: reference, target: target,
            lagRange: refinementRange, minOverlapHops: requiredOverlap
        )
    }

    private static func correlateExact(
        reference: [Float], target: [Float],
        lagRange: ClosedRange<Int>, minOverlapHops: Int
    ) -> Result? {
        let ref = reference.map(Double.init)
        let tgt = target.map(Double.init)
        var best: Result?
        ref.withUnsafeBufferPointer { refBuf in
            tgt.withUnsafeBufferPointer { tgtBuf in
                let refBase = refBuf.baseAddress!
                let tgtBase = tgtBuf.baseAddress!
                for lag in lagRange {
                    guard !Task.isCancelled else { return }
                    let iStart = max(0, -lag)
                    let iEnd = min(tgt.count, ref.count - lag)
                    let n = iEnd - iStart
                    guard n >= minOverlapHops else { continue }

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

    private static func downsample(_ samples: [Float], stride: Int) -> [Float] {
        guard stride > 1 else { return samples }
        return Swift.stride(from: 0, to: samples.count, by: stride).map { start in
            let end = min(start + stride, samples.count)
            return samples[start..<end].reduce(0, +) / Float(end - start)
        }
    }
}

private extension Int {
    func addingClamped(_ other: Int) -> Int {
        let (result, overflow) = addingReportingOverflow(other)
        return overflow ? .max : result
    }

    func subtractingClamped(_ other: Int) -> Int {
        let (result, overflow) = subtractingReportingOverflow(other)
        return overflow ? .min : result
    }
}
