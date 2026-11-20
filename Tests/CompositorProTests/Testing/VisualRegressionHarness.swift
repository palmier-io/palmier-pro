import Foundation
import AppKit
import AVFoundation
import CoreGraphics
import Testing
@testable import CompositorPro

/// Deterministic rendering test harness for visual regression testing.
/// Compares rendered frames against golden reference PNGs stored in Git LFS.
@MainActor
final class VisualRegressionHarness {
    static let shared = VisualRegressionHarness()

    private let baselineDirectory: URL
    private let tolerance: Double
    private let maxPixelDifference: Int

    private init(
        baselineDirectory: URL? = nil,
        tolerance: Double = 0.01,
        maxPixelDifference: Int = 100
    ) {
        let base = baselineDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("CompositorPro/VisualBaselines", isDirectory: true)
        self.baselineDirectory = base
        self.tolerance = tolerance
        self.maxPixelDifference = maxPixelDifference

        try? FileManager.default.createDirectory(at: self.baselineDirectory, withIntermediateDirectories: true)
    }

    /// Captures a frame from the timeline at the given frame and compares it to a baseline.
    /// If no baseline exists, creates one (record mode).
    /// Returns true if the frame matches the baseline (or was created as new baseline).
    func assertFrameMatches(
        _ timeline: Timeline,
        resolver: MediaResolver,
        atFrame frame: Int,
        testName: String,
        recordMode: Bool = false,
        renderSize: CGSize? = nil,
        missingMediaRefs: Set<String> = [],
        file: StaticString = #file,
        line: Int = #line
    ) async throws -> Bool {
        let canvas = renderSize ?? CGSize(width: timeline.width, height: timeline.height)
        let renderedFrame = try await FrameCaptureRenderer.timeline(
            timeline,
            frame: frame,
            mediaURLs: resolver.expectedURLMap(),
            resolveTimeline: { _ in nil },
            missingMediaRefs: missingMediaRefs
        )
        var loadedImage: CGImage? = renderedFrame.thumbnail
        if loadedImage == nil {
            loadedImage = try? loadPNG(from: renderedFrame.stagedURL)
        }
        if loadedImage == nil {
            loadedImage = try? await captureFrameDirect(timeline: timeline, resolver: resolver, atFrame: frame, renderSize: canvas, missingMediaRefs: missingMediaRefs)
        }
        guard let image = loadedImage else {
            throw VisualRegressionError.pngDecodingFailed
        }

        let baselineURL = baselineDirectory.appendingPathComponent("\(testName)_f\(frame).png")

        if recordMode || !FileManager.default.fileExists(atPath: baselineURL.path) {
            try savePNG(image, to: baselineURL)
            if recordMode {
                Issue.record("Recorded new baseline: \(baselineURL.lastPathComponent)", sourceLocation: SourceLocation(fileID: String(describing: file), filePath: String(describing: file), line: line, column: 0))
            }
            return true
        }

        let baselineImage = try loadPNG(from: baselineURL)
        let matches = try compareImages(image, baselineImage, tolerance: tolerance, maxPixelDifference: maxPixelDifference)

        if !matches {
            let diffURL = baselineDirectory.appendingPathComponent("\(testName)_f\(frame)_diff.png")
            try saveDiff(image, baselineImage, to: diffURL)
            Issue.record(
                "Visual regression detected for \(testName) at frame \(frame). Diff saved to \(diffURL.lastPathComponent)",
                sourceLocation: SourceLocation(fileID: String(describing: file), filePath: String(describing: file), line: line, column: 0)
            )
        }

        return matches
    }

    /// Asserts a sequence of frames matches baselines.
    func assertFrameSequenceMatches(
        _ timeline: Timeline,
        resolver: MediaResolver,
        frames: [Int],
        testName: String,
        recordMode: Bool = false,
        renderSize: CGSize? = nil,
        missingMediaRefs: Set<String> = [],
        file: StaticString = #file,
        line: Int = #line
    ) async throws {
        for frame in frames {
            let _ = try await assertFrameMatches(
                timeline, resolver: resolver, atFrame: frame,
                testName: "\(testName)_frame\(frame)",
                recordMode: recordMode,
                renderSize: renderSize,
                missingMediaRefs: missingMediaRefs,
                file: file, line: line
            )
        }
    }

    /// Fallback direct frame capture using AVAssetImageGenerator
    private func captureFrameDirect(
        timeline: Timeline,
        resolver: MediaResolver,
        atFrame frame: Int,
        renderSize: CGSize,
        missingMediaRefs: Set<String>
    ) async throws -> CGImage {
        let mediaURLs = resolver.expectedURLMap()
        let result = try await CompositionBuilder.build(
            timeline: timeline,
            resolveURL: { mediaURLs[$0] },
            resolveTimeline: { _ in nil },
            missingMediaRefs: missingMediaRefs,
            renderSize: renderSize
        )

        let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(timeline.fps))
        let generator = AVAssetImageGenerator(asset: result.composition)
        generator.videoComposition = result.videoComposition
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = renderSize
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let generated = try await generator.image(at: time)
        return generated.image
    }

    private func savePNG(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw VisualRegressionError.pngEncodingFailed
        }
        try data.write(to: url)
    }

    private func loadPNG(from url: URL) throws -> CGImage {
        guard let data = try? Data(contentsOf: url),
              let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw VisualRegressionError.pngDecodingFailed
        }
        return image
    }

    private func compareImages(_ a: CGImage, _ b: CGImage, tolerance: Double, maxPixelDifference: Int) throws -> Bool {
        guard a.width == b.width && a.height == b.height else {
            throw VisualRegressionError.dimensionMismatch("\(a.width)x\(a.height) vs \(b.width)x\(b.height)")
        }

        let width = a.width
        let height = a.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        var diffCount = 0
        var totalDiff: Double = 0

        // Create contexts for both images
        guard let ctxA = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo.rawValue),
              let ctxB = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo.rawValue) else {
            throw VisualRegressionError.contextCreationFailed
        }

        ctxA.draw(a, in: CGRect(x: 0, y: 0, width: width, height: height))
        ctxB.draw(b, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let dataA = ctxA.data, let dataB = ctxB.data else {
            throw VisualRegressionError.pixelDataAccessFailed
        }

        let ptrA = dataA.assumingMemoryBound(to: UInt8.self)
        let ptrB = dataB.assumingMemoryBound(to: UInt8.self)

        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * bytesPerPixel
                let r1 = Double(ptrA[idx]) / 255.0
                let g1 = Double(ptrA[idx + 1]) / 255.0
                let b1 = Double(ptrA[idx + 2]) / 255.0
                let a1 = Double(ptrA[idx + 3]) / 255.0

                let r2 = Double(ptrB[idx]) / 255.0
                let g2 = Double(ptrB[idx + 1]) / 255.0
                let b2 = Double(ptrB[idx + 2]) / 255.0
                let a2 = Double(ptrB[idx + 3]) / 255.0

                let diff = abs(r1 - r2) + abs(g1 - g2) + abs(b1 - b2) + abs(a1 - a2)
                totalDiff += diff
                if diff > tolerance {
                    diffCount += 1
                }
            }
        }

        let avgDiff = totalDiff / Double(width * height * 4)
        return avgDiff <= tolerance && diffCount <= maxPixelDifference
    }

    private func saveDiff(_ a: CGImage, _ b: CGImage, to url: URL) throws {
        let width = a.width
        let height = a.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let ctxA = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo.rawValue),
              let ctxB = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo.rawValue),
              let ctxDiff = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo.rawValue) else {
            throw VisualRegressionError.contextCreationFailed
        }

        ctxA.draw(a, in: CGRect(x: 0, y: 0, width: width, height: height))
        ctxB.draw(b, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let dataA = ctxA.data, let dataB = ctxB.data, let dataDiff = ctxDiff.data else {
            throw VisualRegressionError.pixelDataAccessFailed
        }

        let ptrA = dataA.assumingMemoryBound(to: UInt8.self)
        let ptrB = dataB.assumingMemoryBound(to: UInt8.self)
        let ptrDiff = dataDiff.assumingMemoryBound(to: UInt8.self)

        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * bytesPerPixel
                for c in 0..<3 {
                    let diff = abs(Int(ptrA[idx + c]) - Int(ptrB[idx + c]))
                    ptrDiff[idx + c] = UInt8(min(diff * 4, 255)) // Amplify difference for visibility
                }
                ptrDiff[idx + 3] = 255
            }
        }

        guard let diffImage = ctxDiff.makeImage() else {
            throw VisualRegressionError.diffImageCreationFailed
        }
        try savePNG(diffImage, to: url)
    }
}

enum VisualRegressionError: LocalizedError {
    case pngEncodingFailed
    case pngDecodingFailed
    case dimensionMismatch(String)
    case contextCreationFailed
    case pixelDataAccessFailed
    case diffImageCreationFailed

    var errorDescription: String? {
        switch self {
        case .pngEncodingFailed: return "Failed to encode PNG"
        case .pngDecodingFailed: return "Failed to decode PNG"
        case .dimensionMismatch(let msg): return "Image dimension mismatch: \(msg)"
        case .contextCreationFailed: return "Failed to create CGContext"
        case .pixelDataAccessFailed: return "Failed to access pixel data"
        case .diffImageCreationFailed: return "Failed to create diff image"
        }
    }
}

/// Test helper for creating baseline tests
struct VisualRegressionTest {
    let harness: VisualRegressionHarness
    let timeline: Timeline
    let resolver: MediaResolver
    let renderSize: CGSize?
    let missingMediaRefs: Set<String>

    func assertFrame(_ frame: Int, name: String, recordMode: Bool = false) async throws {
        _ = try await harness.assertFrameMatches(
            timeline, resolver: resolver, atFrame: frame,
            testName: name, recordMode: recordMode,
            renderSize: renderSize, missingMediaRefs: missingMediaRefs
        )
    }

    func assertFrames(_ frames: [Int], name: String, recordMode: Bool = false) async throws {
        try await harness.assertFrameSequenceMatches(
            timeline, resolver: resolver, frames: frames,
            testName: name, recordMode: recordMode,
            renderSize: renderSize, missingMediaRefs: missingMediaRefs
        )
    }
}

/// Extension to make it easy to use in tests
extension VisualRegressionHarness {
    /// Creates a test helper for a given timeline
    func test(
        _ timeline: Timeline,
        resolver: MediaResolver,
        renderSize: CGSize? = nil,
        missingMediaRefs: Set<String> = []
    ) -> VisualRegressionTest {
        VisualRegressionTest(
            harness: self,
            timeline: timeline,
            resolver: resolver,
            renderSize: renderSize,
            missingMediaRefs: missingMediaRefs
        )
    }
}