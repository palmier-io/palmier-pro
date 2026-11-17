import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import CompositorPro

@Suite("Perceptual fingerprints")
struct PerceptualFingerprintTests {
    private func image(color: NSColor, size: Int = 32) -> CGImage {
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        )!
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()!
    }

    private func halfSplit(left: NSColor, right: NSColor, size: Int = 32) -> CGImage {
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        )!
        context.setFillColor(left.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: size / 2, height: size))
        context.setFillColor(right.cgColor)
        context.fill(CGRect(x: size / 2, y: 0, width: size / 2, height: size))
        return context.makeImage()!
    }

    private func occurrence(_ ref: String) -> VisualOccurrence {
        VisualOccurrence(mediaRef: ref, clipIds: [ref], lane: ["t", "track"], startFrame: 0, endFrame: 30,
                         sourceStart: 0, sourceEnd: 1, isImage: true)
    }

    @Test func identicalImagesHaveZeroDistance() throws {
        let a = try #require(PerceptualFingerprint(image: image(color: .systemBlue)))
        let b = try #require(PerceptualFingerprint(image: image(color: .systemBlue)))
        #expect(a.distance(to: b) == 0)
    }

    @Test func clearlyDifferentImagesExceedTheThreshold() throws {
        let blue = try #require(PerceptualFingerprint(image: image(color: .systemBlue)))
        let white = try #require(PerceptualFingerprint(image: image(color: .white)))
        #expect(blue.distance(to: white) > PerceptualFingerprint.nearDuplicateDistance)
    }

    @Test func scaledCopiesStayWithinTheThreshold() throws {
        let base = try #require(PerceptualFingerprint(image: image(color: .systemGreen, size: 32)))
        let scaled = try #require(PerceptualFingerprint(image: image(color: .systemGreen, size: 97)))
        #expect(base.distance(to: scaled) <= PerceptualFingerprint.nearDuplicateDistance)
    }

    @Test func nearDuplicatePairsAreReportedDeterministically() throws {
        let same = try #require(PerceptualFingerprint(image: image(color: .systemPink)))
        let split = try #require(PerceptualFingerprint(image: halfSplit(left: .white, right: .black)))
        let report = PerceptualSimilarity.nearDuplicates(["b": same, "a": same, "c": split])

        #expect(report.count == 1)
        #expect(report.first?.firstMediaRef == "a")
        #expect(report.first?.secondMediaRef == "b")
        #expect(report.first?.distance == 0)
    }

    @Test func auditReportsMeasuredStatusAndSkipsMissingMedia() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fingerprint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("a.png")
        let second = directory.appendingPathComponent("b.png")
        for url in [first, second] {
            let data = NSBitmapImageRep(cgImage: image(color: .systemTeal, size: 24)).representation(using: .png, properties: [:])!
            try data.write(to: url)
        }
        var manifest = MediaManifest()
        manifest.entries = [
            .init(id: "a", name: "A", type: .image, source: .external(absolutePath: first.path), duration: 1),
            .init(id: "b", name: "B", type: .image, source: .external(absolutePath: second.path), duration: 1),
            .init(id: "c", name: "C", type: .image, source: .external(absolutePath: directory.appendingPathComponent("missing.png").path), duration: 1),
        ]

        let report = await PerceptualSimilarity.audit(
            occurrences: [occurrence("a"), occurrence("b"), occurrence("c")], manifest: manifest
        )
        #expect(report.status == "measured")
        #expect(report.sampled >= 2)
        #expect(report.skipped >= 1)
        #expect(report.pairs.contains { $0.distance == 0 })
        #expect(report.receipt["status"] as? String == "measured")
    }

    @Test func samplingIsBoundedAndDeduplicated() {
        let occurrences = (0..<40).map { occurrence("ref-\($0)") } + [occurrence("ref-0")]
        let refs = PerceptualSimilarity.sampledSources(from: occurrences)
        #expect(refs.count == PerceptualSimilarity.maximumSampledSources)
        #expect(Set(refs).count == refs.count)
    }
}
