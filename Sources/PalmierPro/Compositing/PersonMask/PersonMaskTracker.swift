import CoreImage
import CoreVideo
import Vision

/// Tracks one person's identity across frames: a `TrackObjectRequest` predicts where they now
/// are, mask overlap resolves which fresh Vision instance label that corresponds to.
final class PersonMaskTracker {
    private let tracking: TrackObjectRequest
    private var lastGoodMask: CIImage

    private static let matchThreshold = 0.1
    private static let confidenceThreshold: Float = 0.3

    init(seedObservation: InstanceMaskObservation, label: Int) throws {
        let maskBuffer = try seedObservation.generateMask(for: IndexSet(integer: label))
        let mask = CIImage(cvPixelBuffer: maskBuffer)
        lastGoodMask = mask
        let box = PersonMaskGeometry.boundingBox(of: mask) ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let seed = DetectedObjectObservation(boundingBox: NormalizedRect(normalizedRect: box))
        tracking = TrackObjectRequest(detectedObject: seed)
    }

    /// Advances one frame and resolves which current-frame instance label this identity is now.
    func resolve(pixelBuffer: CVPixelBuffer, observation: InstanceMaskObservation) async -> Int? {
        let labels = Array(observation.allInstances)
        guard !labels.isEmpty else { return nil }

        var predictedBox: CGRect?
        if let result = try? await tracking.perform(on: pixelBuffer), result.confidence >= Self.confidenceThreshold {
            predictedBox = result.boundingBox.cgRect
        }

        if let predictedBox,
           let best = bestMatch(labels: labels, observation: observation, box: predictedBox),
           best.score > Self.matchThreshold {
            lastGoodMask = best.mask
            return best.label
        }
        if let best = bestMatch(labels: labels, observation: observation, referenceMask: lastGoodMask),
           best.score > Self.matchThreshold {
            lastGoodMask = best.mask
            return best.label
        }
        return nil
    }

    private func bestMatch(
        labels: [Int], observation: InstanceMaskObservation, box: CGRect
    ) -> (label: Int, mask: CIImage, score: Double)? {
        var best: (label: Int, mask: CIImage, score: Double)?
        for label in labels {
            guard let buffer = try? observation.generateMask(for: IndexSet(integer: label)) else { continue }
            let mask = CIImage(cvPixelBuffer: buffer)
            let score = PersonMaskGeometry.overlap(of: mask, with: box)
            if best == nil || score > best!.score { best = (label, mask, score) }
        }
        return best
    }

    private func bestMatch(
        labels: [Int], observation: InstanceMaskObservation, referenceMask: CIImage
    ) -> (label: Int, mask: CIImage, score: Double)? {
        var best: (label: Int, mask: CIImage, score: Double)?
        for label in labels {
            guard let buffer = try? observation.generateMask(for: IndexSet(integer: label)) else { continue }
            let mask = CIImage(cvPixelBuffer: buffer)
            let score = PersonMaskGeometry.overlap(mask, referenceMask)
            if best == nil || score > best!.score { best = (label, mask, score) }
        }
        return best
    }
}
