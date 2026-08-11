import Accelerate
import Foundation

enum AudioSyncCorrelator {
    struct Result: Sendable, Equatable {
        let lagHops: Int
        let confidence: Double
        let driftRatio: Double
        /// Fractional lag from the drift fit; use for placement so hop rounding
        /// cannot flip a near-half-frame result to the wrong frame.
        let exactLagHops: Double

        init(lagHops: Int, confidence: Double, driftRatio: Double = 0, exactLagHops: Double? = nil) {
            self.lagHops = lagHops
            self.confidence = confidence
            self.driftRatio = driftRatio
            self.exactLagHops = exactLagHops ?? Double(lagHops)
        }
    }

    static let minOverlap = 16
    private static let pyramidStride = 2
    /// Lag ranges up to this size are searched exactly; larger ones go through the pyramid.
    private static let maxExactLagCount = 4_096
    private static let maxCandidates = 16
    // Consensus constants assume the 2.5 ms sync envelope hop.
    /// 60-second chunks: long enough to correlate reliably, short enough that drift stays sub-hop within one.
    private static let consensusChunkHops = 24_000
    private static let consensusChunkCount = 5
    /// Chunk lags within 1 s of each other count as agreeing.
    private static let consensusToleranceHops = 400
    /// Search radius around the previous chunk's lag before rescanning the full windows.
    private static let reacquireRadiusHops = 800
    /// Below this chunk spread (2.5 min) the fitted slope is dominated by hop quantization.
    private static let driftFitMinSpanHops = 60_000
    /// Recorder crystals disagree by tens of ppm; a larger fitted slope means mismatched content, not drift.
    private static let maxDriftRatio = 0.0005
    /// Slopes below ~one frame per hour are quantization noise, not drift.
    private static let minDriftRatio = 0.00002

    @concurrent
    static func seededCorrelate(
        reference: [Float], target: [Float], seedHops: Int?, seedWindowHops: Int,
        maxLagHops: Int, minOverlapHops: Int, minConfidence: Double
    ) async -> Result? {
        var windows = [(center: 0, radius: maxLagHops)]
        if let seedHops { windows.append((seedHops, seedWindowHops)) }
        return alignByConsensus(
            reference: reference, target: target, windows: windows,
            minOverlapHops: minOverlapHops, minConfidence: minConfidence
        )
    }

    private static func alignByConsensus(
        reference: [Float], target: [Float], windows: [(center: Int, radius: Int)],
        minOverlapHops: Int, minConfidence: Double
    ) -> Result? {
        func bestAcrossWindows(_ chunk: [Float], chunkStart: Int, overlap: Int) -> Result? {
            var best: Result?
            for window in windows {
                guard !Task.isCancelled else { return nil }
                let candidate = correlate(
                    reference: reference, target: chunk, maxLagHops: window.radius,
                    centerLagHops: window.center + chunkStart, minOverlapHops: overlap
                )
                if let candidate, candidate.confidence > (best?.confidence ?? -.infinity) {
                    best = candidate
                }
            }
            return best
        }

        let chunkHops = min(target.count, consensusChunkHops)
        var starts: [Int] = [0]
        if target.count > chunkHops {
            let maxStart = target.count - chunkHops
            starts = Array(Set((0..<consensusChunkCount).map {
                maxStart * $0 / (consensusChunkCount - 1)
            })).sorted()
        }

        var hits: [(start: Int, center: Double, clipLag: Int, confidence: Double)] = []
        for start in starts {
            guard !Task.isCancelled else { return nil }
            let chunk = Array(target[start..<start + chunkHops])
            guard chunk.min() != chunk.max() else { continue }
            let overlap = min(max(minOverlapHops, chunk.count / 2), chunk.count)

            var best: Result?
            if let prev = hits.last {
                best = correlate(
                    reference: reference, target: chunk, maxLagHops: reacquireRadiusHops,
                    centerLagHops: prev.clipLag + start, minOverlapHops: overlap
                )
                if let found = best, found.confidence < minConfidence { best = nil }
            }
            if best == nil { best = bestAcrossWindows(chunk, chunkStart: start, overlap: overlap) }
            guard let best, best.confidence >= minConfidence else { continue }
            hits.append((start, Double(start) + Double(chunk.count) / 2, best.lagHops - start, best.confidence))
        }

        guard !hits.isEmpty else {
            guard let best = bestAcrossWindows(target, chunkStart: 0, overlap: minOverlapHops),
                  best.confidence >= minConfidence else { return nil }
            return best
        }

        let sorted = hits.sorted { $0.clipLag < $1.clipLag }
        var cluster = ArraySlice(sorted)
        var clusterScore = -Double.infinity
        for i in sorted.indices {
            var j = i
            while j + 1 < sorted.count,
                  sorted[j + 1].clipLag - sorted[i].clipLag <= consensusToleranceHops { j += 1 }
            let candidate = sorted[i...j]
            let score = candidate.reduce(0) { $0 + $1.confidence }
            if score > clusterScore {
                clusterScore = score
                cluster = candidate
            }
        }
        let confidence = cluster.reduce(0) { $0 + $1.confidence } / Double(cluster.count)

        let span = (cluster.map(\.center).max() ?? 0) - (cluster.map(\.center).min() ?? 0)
        if cluster.count >= 3, span >= Double(driftFitMinSpanHops) {
            let n = Double(cluster.count)
            let meanX = cluster.reduce(0) { $0 + $1.center } / n
            let meanY = cluster.reduce(0) { $0 + Double($1.clipLag) } / n
            let varX = cluster.reduce(0) { $0 + ($1.center - meanX) * ($1.center - meanX) }
            let cov = cluster.reduce(0) { $0 + ($1.center - meanX) * (Double($1.clipLag) - meanY) }
            let slope = varX > 0 ? cov / varX : 0
            if abs(slope) >= minDriftRatio, abs(slope) <= maxDriftRatio {
                let maxResidual = cluster.map { abs(Double($0.clipLag) - (meanY + slope * ($0.center - meanX))) }.max() ?? 0
                if maxResidual <= Double(consensusToleranceHops) {
                    let lagAtHead = meanY - slope * meanX
                    return Result(
                        lagHops: Int(lagAtHead.rounded()), confidence: confidence,
                        driftRatio: slope, exactLagHops: lagAtHead
                    )
                }
            }
        }
        guard let anchor = cluster.min(by: { $0.start < $1.start }) else { return nil }
        return Result(lagHops: anchor.clipLag, confidence: confidence)
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
        let lower = max(validLags.lowerBound, centerLagHops.subtractingClamped(maxLagHops))
        let upper = min(validLags.upperBound, centerLagHops.addingClamped(maxLagHops))
        guard lower <= upper else { return nil }

        return correlateCandidates(
            reference: reference, target: target,
            lagRange: lower...upper, minOverlapHops: requiredOverlap
        ).first
    }

    private static func correlateCandidates(
        reference: [Float], target: [Float],
        lagRange: ClosedRange<Int>, minOverlapHops: Int
    ) -> [Result] {
        guard lagRange.count > maxExactLagCount,
              reference.count >= pyramidStride * minOverlap,
              target.count >= pyramidStride * minOverlap else {
            return exactCandidates(
                reference: reference, target: target,
                lagRanges: [lagRange], minOverlapHops: minOverlapHops
            )
        }

        let coarseTarget = downsample(target, stride: pyramidStride)
        var mappedCandidates: [Result] = []
        for phase in 0..<pyramidStride {
            let coarseLower = Int(ceil(Double(lagRange.lowerBound - phase) / Double(pyramidStride)))
            let coarseUpper = Int(floor(Double(lagRange.upperBound - phase) / Double(pyramidStride)))
            guard coarseLower <= coarseUpper else { continue }
            let candidates = correlateCandidates(
                reference: downsample(reference, stride: pyramidStride, offset: phase),
                target: coarseTarget,
                lagRange: coarseLower...coarseUpper,
                minOverlapHops: max(4, (minOverlapHops + pyramidStride - 1) / pyramidStride)
            )
            mappedCandidates.append(contentsOf: candidates.map {
                Result(lagHops: $0.lagHops * pyramidStride + phase, confidence: $0.confidence)
            })
        }
        let coarseCandidates = rankedCandidates(mappedCandidates)
        guard !coarseCandidates.isEmpty else { return [] }

        let radius = pyramidStride * 2
        let ranges = coarseCandidates.map { candidate in
            max(lagRange.lowerBound, candidate.lagHops - radius)...min(lagRange.upperBound, candidate.lagHops + radius)
        }
        return exactCandidates(
            reference: reference, target: target,
            lagRanges: merged(ranges), minOverlapHops: minOverlapHops
        )
    }

    static func exactCandidates(
        reference: [Float], target: [Float],
        lagRanges: [ClosedRange<Int>], minOverlapHops: Int
    ) -> [Result] {
        let ref = reference.map(Double.init)
        let tgt = target.map(Double.init)
        var results: [Result] = []
        ref.withUnsafeBufferPointer { refBuf in
            tgt.withUnsafeBufferPointer { tgtBuf in
                let refBase = refBuf.baseAddress!
                let tgtBase = tgtBuf.baseAddress!
                for lagRange in lagRanges {
                    for lag in lagRange {
                        guard !Task.isCancelled else { return }
                        let iStart = max(0, -lag)
                        let iEnd = min(tgt.count, ref.count - lag)
                        let n = iEnd - iStart
                        guard n >= minOverlapHops else { continue }

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
                        results.append(Result(lagHops: lag, confidence: max(0, cov / denom)))
                    }
                }
            }
        }
        guard !Task.isCancelled else { return [] }
        let peaks = results.indices.filter { index in
            let result = results[index]
            let leftIsLower = index == 0
                || results[index - 1].lagHops != result.lagHops - 1
                || result.confidence >= results[index - 1].confidence
            let rightIsLower = index == results.count - 1
                || results[index + 1].lagHops != result.lagHops + 1
                || result.confidence >= results[index + 1].confidence
            return leftIsLower && rightIsLower
        }.map { results[$0] }
        return rankedCandidates(peaks.isEmpty ? results : peaks)
    }

    private static func rankedCandidates(_ candidates: [Result]) -> [Result] {
        let ranked = candidates.sorted {
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            let lhsDistance = $0.lagHops.magnitude
            let rhsDistance = $1.lagHops.magnitude
            return lhsDistance == rhsDistance ? $0.lagHops < $1.lagHops : lhsDistance < rhsDistance
        }
        var selected: [Result] = []
        for candidate in ranked where selected.allSatisfy({
            $0.lagHops.distance(to: candidate.lagHops).magnitude > UInt(2)
        }) {
            selected.append(candidate)
            if selected.count == maxCandidates { break }
        }
        return selected
    }

    private static func downsample(_ samples: [Float], stride: Int, offset: Int = 0) -> [Float] {
        guard offset < samples.count else { return [] }
        guard stride > 1 else { return Array(samples.dropFirst(offset)) }
        return Swift.stride(from: offset, to: samples.count, by: stride).map { start in
            let end = min(start + stride, samples.count)
            return samples[start..<end].reduce(0, +) / Float(end - start)
        }
    }

    private static func merged(_ ranges: [ClosedRange<Int>]) -> [ClosedRange<Int>] {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        guard var current = sorted.first else { return [] }
        var result: [ClosedRange<Int>] = []
        for range in sorted.dropFirst() {
            if range.lowerBound <= current.upperBound.addingClamped(1) {
                current = current.lowerBound...max(current.upperBound, range.upperBound)
            } else {
                result.append(current)
                current = range
            }
        }
        result.append(current)
        return result
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
