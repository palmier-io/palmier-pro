import AVFoundation
import CoreImage
import Vision

/// Detects people in a clip's first frame; the bake pass then tracks forward from there.
enum PersonMaskAnalyzer {
    struct Candidate: Identifiable, Sendable {
        let id: Int   // Vision instance label — only meaningful within one seed-frame observation
        let thumbnail: CGImage
    }

    enum AnalyzerError: LocalizedError, Equatable {
        case noFrame
        case noPeople

        var errorDescription: String? {
            switch self {
            case .noFrame: "Could not read a frame to analyze."
            case .noPeople: "No people detected in this clip's first frame."
            }
        }
    }

    private static let thumbnailContext = CIContext(options: [.workingColorSpace: NSNull()])
    private static let thumbnailMaxDimension: CGFloat = 160

    /// Detects people in the first frame of `url`'s video track, in raw sensor orientation to
    /// match `PersonMaskBaker`'s per-frame Vision passes regardless of rotation metadata.
    static func detectPeople(url: URL) async throws -> [Candidate] {
        guard let frame = await frameImage(url: url) else { throw AnalyzerError.noFrame }
        return try await detectPeople(in: frame)
    }

    static func detectPeople(in image: CIImage) async throws -> [Candidate] {
        guard let observation = try await observation(in: image) else { throw AnalyzerError.noPeople }
        var candidates: [Candidate] = []
        for label in observation.allInstances.sorted() {
            guard let maskBuffer = try? observation.generateMask(for: IndexSet(integer: label)) else { continue }
            let mask = CIImage(cvPixelBuffer: maskBuffer)
            guard let thumbnail = thumbnail(of: image, mask: mask) else { continue }
            candidates.append(Candidate(id: label, thumbnail: thumbnail))
        }
        guard !candidates.isEmpty else { throw AnalyzerError.noPeople }
        return candidates
    }

    static func observation(in image: CIImage) async throws -> InstanceMaskObservation? {
        let request = GeneratePersonInstanceMaskRequest()
        return try await request.perform(on: image)
    }

    private static func thumbnail(of image: CIImage, mask: CIImage) -> CGImage? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else { return nil }
        let maskExtent = mask.extent
        let scaledMask = mask.transformed(by: CGAffineTransform(
            scaleX: extent.width / max(1, maskExtent.width),
            y: extent.height / max(1, maskExtent.height)
        ))
        let cutout = image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: extent),
            kCIInputMaskImageKey: scaledMask,
        ])
        let scale = min(1, thumbnailMaxDimension / max(extent.width, extent.height))
        let scaled = cutout.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return thumbnailContext.createCGImage(scaled, from: scaled.extent)
    }

    private static func frameImage(url: URL) async -> CIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = false // raw orientation — see detectPeople(url:)
        let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        guard let cg = try? await generator.image(at: .zero).image else { return nil }
        return CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
    }
}
