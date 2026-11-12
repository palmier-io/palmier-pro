import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import CompositorPro

/// Proves a freeze actually holds in the rendered output, not only in the model. A clip whose
/// colour changes every half second is composed, and the rendered frames are measured: the held
/// frames must be identical while the frames after the hold differ.
@Suite("Freeze frame renders a held picture")
struct FreezeFrameRenderTests {
    private static let fps = 30
    private static let holdFrames = 20
    /// The hold always sits at the clip's head; `atFrame` chooses which source frame it shows.
    private static let freezeStart = 0

    /// Eight half-second colour steps: a hold on any of them is unmistakable.
    private func makeCountingClip() async throws -> URL {
        var scenes: [FixtureVideo.Scene] = []
        for index in 0 ..< 8 {
            let r = UInt8((index * 31) % 256)
            let b = UInt8((200 - index * 20) % 200)
            scenes.append(FixtureVideo.Scene(rgb: (r, 40, b), seconds: 0.5))
        }
        return try await FixtureVideo.write(
            scenes: scenes, fps: Int32(Self.fps), size: 64, fileType: .mov
        )
    }

    private func meanLuma(of image: CGImage) throws -> Double {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        try #require(context).draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var sum: Double = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let r = Double(bytes[index])
            let g = Double(bytes[index + 1])
            let b = Double(bytes[index + 2])
            sum += (r + g + b) / 3
        }
        return sum / Double(width * height)
    }

    private func frameLuma(at frame: Int, of composition: AVMutableComposition) async throws -> Double {
        let track = try #require(composition.tracks(withMediaType: .video).first)
        let generator = AVAssetImageGenerator(asset: composition)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let seconds = Double(frame) / Double(Self.fps)
        let rendered = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        return try meanLuma(of: rendered.image)
    }

    @Test func frozenFramesAreIdenticalAndTheTailStillMoves() async throws {
        let url = try await makeCountingClip()
        defer { try? FileManager.default.removeItem(at: url) }
        let sourceAsset = AVURLAsset(url: url)
        let sourceSeconds = try await sourceAsset.load(.duration).seconds
        let sourceFrames = Int((sourceSeconds * Double(Self.fps)).rounded())

        // Head plays, then the hold, then the rest: same source, longer timeline.
        var clip = Fixtures.clip(
            id: "hold", mediaRef: "src", start: 0,
            duration: sourceFrames + Self.holdFrames, trimStart: 0
        )
        clip.freezeFrames = Self.holdFrames

        let result = try await CompositionBuilder.build(
            timeline: Fixtures.timeline(fps: Self.fps, tracks: [Fixtures.videoTrack(clips: [clip])]),
            resolveURL: { $0 == "src" ? url : nil },
            renderSize: CGSize(width: 64, height: 64)
        )
        let mapping = try #require(result.trackMappings.first { $0.isVideo })
        let segments = try await mapping.compositionTrack.load(.segments)

        // The hold is one source frame stretched across the whole hold.
        let holdStartSeconds = Double(Self.freezeStart) / Double(Self.fps)
        let holdEndSeconds = Double(Self.freezeStart + Self.holdFrames) / Double(Self.fps)
        let holdSegment = try #require(segments.first { segment in
            let start = segment.timeMapping.target.start.seconds
            return start >= holdStartSeconds - 0.06 && start < holdEndSeconds
        })
        let sourceSpan = holdSegment.timeMapping.source.duration.seconds
        let targetSpan = holdSegment.timeMapping.target.duration.seconds
        #expect(sourceSpan < 0.2, "hold should read about one source frame, got \(sourceSpan)s")
        #expect(abs(targetSpan - Double(Self.holdFrames) / Double(Self.fps)) < 0.06)

        // The rendered picture does not change across the hold...
        let first = try await frameLuma(at: Self.freezeStart + 2, of: result.composition)
        let last = try await frameLuma(at: Self.freezeStart + Self.holdFrames - 2, of: result.composition)
        #expect(abs(first - last) < 0.75, "held frames should match, got \(first) vs \(last)")

        // ...and it resumes afterwards. The fixture changes colour every 15 frames, so sample
        // well past the next boundary rather than just past the hold.
        let resumed = try await frameLuma(at: 34, of: result.composition)
        #expect(abs(resumed - first) > 0.75, "picture should move again after the hold")
    }

    @Test func aClipWithoutAFreezeHasNoHoldSegment() async throws {
        let url = try await makeCountingClip()
        defer { try? FileManager.default.removeItem(at: url) }
        let sourceAsset = AVURLAsset(url: url)
        let sourceSeconds = try await sourceAsset.load(.duration).seconds
        let sourceFrames = Int((sourceSeconds * Double(Self.fps)).rounded())
        let clip = Fixtures.clip(
            id: "plain", mediaRef: "src", start: 0, duration: sourceFrames, trimStart: 0
        )
        let result = try await CompositionBuilder.build(
            timeline: Fixtures.timeline(fps: Self.fps, tracks: [Fixtures.videoTrack(clips: [clip])]),
            resolveURL: { $0 == "src" ? url : nil },
            renderSize: CGSize(width: 64, height: 64)
        )
        let mapping = try #require(result.trackMappings.first { $0.isVideo })
        let segments = try await mapping.compositionTrack.load(.segments)
        #expect(segments.count == 1)
        #expect(abs(segments[0].timeMapping.source.duration.seconds - sourceSeconds) < 0.2)
    }
}
