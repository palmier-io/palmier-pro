import AppKit
import AVFoundation
import CoreGraphics
import ImageIO
import Foundation

/// 64-bit difference hash over a 9×8 grayscale reduction plus mean luma. Hamming distance catches
/// structural repeats; the luma term keeps two flat frames of different brightness apart, which a
/// pure average or difference hash cannot separate.
struct PerceptualFingerprint: Hashable, Sendable {
    static let nearDuplicateDistance = 6

    let bits: UInt64
    let meanLuma: Int

    init(bits: UInt64, meanLuma: Int) {
        self.bits = bits
        self.meanLuma = meanLuma
    }

    init?(image: CGImage) {
        guard let value = Self.hash(image) else { return nil }
        self.bits = value.bits
        self.meanLuma = value.meanLuma
    }

    func distance(to other: PerceptualFingerprint) -> Int {
        (bits ^ other.bits).nonzeroBitCount + abs(meanLuma - other.meanLuma) / 4
    }

    var hex: String { String(format: "%016llx-%02x", bits, meanLuma) }

    private static func hash(_ image: CGImage) -> (bits: UInt64, meanLuma: Int)? {
        let columns = 9, rows = 8
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 0, count: columns * rows)
        guard let context = CGContext(
            data: &pixels, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: columns,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))

        var bits: UInt64 = 0
        var bitIndex = 0
        for row in 0..<rows {
            for column in 0..<(columns - 1) {
                let left = pixels[row * columns + column]
                let right = pixels[row * columns + column + 1]
                if left > right { bits |= 1 << UInt64(bitIndex) }
                bitIndex += 1
            }
        }
        let total = pixels.reduce(0) { $0 + Int($1) }
        return (bits, total / pixels.count)
    }
}

/// Samples one frame per source and reports perceptually similar pairs. Extraction is bounded and
/// runs off-main; callers pass occurrences from `VisualUniqueness`.
enum PerceptualSimilarity {
    static let maximumSampledSources = 24
    static let maximumReportedPairs = 16

    struct Pair: Sendable, Equatable {
        let firstMediaRef: String
        let secondMediaRef: String
        let distance: Int
    }

    struct Report: Sendable, Equatable {
        var sampled: Int = 0
        var skipped: Int = 0
        var pairs: [Pair] = []

        var status: String { sampled == 0 ? "not_checked" : "measured" }
        var receipt: [String: Any] {
            [
                "status": status,
                "sampledSources": sampled,
                "skippedSources": skipped,
                "distanceThreshold": PerceptualFingerprint.nearDuplicateDistance,
                "nearDuplicates": pairs.prefix(maximumReportedPairs).map {
                    ["firstMediaRef": $0.firstMediaRef, "secondMediaRef": $0.secondMediaRef,
                     "distance": $0.distance] as [String: Any]
                },
            ]
        }
    }

    /// Ordered unique source refs from the report, bounded so one review cannot decode endlessly.
    static func sampledSources(from occurrences: [VisualOccurrence]) -> [String] {
        var seen = Set<String>()
        var refs: [String] = []
        for occurrence in occurrences where seen.insert(occurrence.mediaRef).inserted {
            refs.append(occurrence.mediaRef)
            if refs.count == maximumSampledSources { break }
        }
        return refs
    }

    /// Pairs whose fingerprints are within `nearDuplicateDistance`, deterministically ordered.
    static func nearDuplicates(_ fingerprints: [String: PerceptualFingerprint]) -> [Pair] {
        let keys = fingerprints.keys.sorted()
        var pairs: [Pair] = []
        for i in keys.indices {
            for j in keys.index(after: i)..<keys.endIndex {
                let first = keys[i], second = keys[j]
                guard let a = fingerprints[first], let b = fingerprints[second] else { continue }
                let distance = a.distance(to: b)
                if distance <= PerceptualFingerprint.nearDuplicateDistance {
                    pairs.append(Pair(firstMediaRef: first, secondMediaRef: second, distance: distance))
                }
            }
        }
        return pairs.sorted {
            ($0.distance, $0.firstMediaRef, $0.secondMediaRef) < ($1.distance, $1.firstMediaRef, $1.secondMediaRef)
        }
    }

    /// Fingerprints all sampled sources, skipping unreadable media instead of failing the review.
    @concurrent
    static func audit(
        occurrences: [VisualOccurrence],
        manifest: MediaManifest,
        fingerprint: @escaping @Sendable (URL, Double) async -> PerceptualFingerprint? = MediaFrameSampler.fingerprint
    ) async -> Report {
        let refs = sampledSources(from: occurrences)
        guard !refs.isEmpty else { return Report() }
        let urls = MediaResolver(manifest: { manifest }, projectURL: { nil }).expectedURLMap()
        var fingerprints: [String: PerceptualFingerprint] = [:]
        var skipped = 0
        for ref in refs {
            guard let url = urls[ref] else {
                skipped += 1
                continue
            }
            let seconds = occurrences.first { $0.mediaRef == ref }.map { max(0, $0.sourceStart) } ?? 0
            if let value = await fingerprint(url, seconds) {
                fingerprints[ref] = value
            } else {
                skipped += 1
            }
        }
        return Report(sampled: fingerprints.count, skipped: skipped, pairs: nearDuplicates(fingerprints))
    }
}

/// Extracts one small frame from a media file for fingerprinting. Runs off-main.
enum MediaFrameSampler {
    @concurrent
    static func fingerprint(url: URL, atSeconds seconds: Double) async -> PerceptualFingerprint? {
        if let image = imageFromFile(url: url) {
            return PerceptualFingerprint(image: image)
        }
        let asset = AVURLAsset(url: url)
        guard (try? await asset.loadTracks(withMediaType: .video).first) != nil else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 64, height: 64)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        let time = CMTime(seconds: max(0, seconds.isFinite ? seconds : 0), preferredTimescale: 600)
        guard let image = try? await generator.image(at: time).image else { return nil }
        return PerceptualFingerprint(image: image)
    }

    private static func imageFromFile(url: URL) -> CGImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
    }
}
