import AVFoundation
import CoreVideo
import Testing
@testable import PalmierPro

/// Regression coverage: a clip whose video track carries rotation metadata (very common —
/// many cameras/phones tag "normal-looking" footage with a non-identity `preferredTransform`
/// rather than storing pre-rotated pixels) must not be rejected outright. Detection/baking both
/// operate in the track's raw (sensor) orientation and ignore `preferredTransform` — see
/// `PersonMaskAnalyzer.detectPeople(url:)` and `PersonMaskBaker.bake`.
@Suite("PersonMask — rotated source video")
struct PersonMaskRotationTests {

    /// Writes a tiny solid-color video whose track has a 90° `preferredTransform`, standing in
    /// for camera footage that looks upright/horizontal on playback via rotation metadata.
    private static func rotatedVideoURL() async throws -> URL {
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("personmask-rotated-\(UUID().uuidString).mov")

        let width = 64, height = 48
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
        #expect(status == kCVReturnSuccess)
        guard let buffer = pixelBuffer else { throw ImageVideoGenerator.ImageVideoError.pixelBufferCreationFailed }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 128, CVPixelBufferGetBytesPerRow(buffer) * height)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.transform = CGAffineTransform(rotationAngle: .pi / 2) // 90° — never identity
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        _ = adaptor.append(buffer, withPresentationTime: .zero)
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return outputURL
    }

    @Test func detectPeopleDoesNotRejectRotatedTrack() async throws {
        let url = try await Self.rotatedVideoURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first
        let transform = try await track?.load(.preferredTransform)
        #expect(transform != nil && transform! != .identity, "fixture must actually carry rotation metadata")

        // No real person in this solid-color fixture, so Vision typically finds nothing (or,
        // rarely, hallucinates on a flat image) — either way, the call must reach real Vision
        // processing instead of bailing synchronously on the rotation metadata.
        do {
            _ = try await PersonMaskAnalyzer.detectPeople(url: url)
        } catch let error as PersonMaskAnalyzer.AnalyzerError {
            #expect(error == .noPeople || error == .noFrame, "expected a Vision-content failure, got \(error)")
        } catch {
            Issue.record("expected a PersonMaskAnalyzer.AnalyzerError or success, got \(error)")
        }
    }

    @Test func bakeDoesNotRejectRotatedTrack() async throws {
        let url = try await Self.rotatedVideoURL()
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: PersonMaskBaker.BakerError.noPeopleFound) {
            _ = try await PersonMaskBaker.bake(
                sourceURL: url, mediaRef: "rotated-fixture", selectedLabels: [0], progress: { _ in }
            )
        }
    }
}
