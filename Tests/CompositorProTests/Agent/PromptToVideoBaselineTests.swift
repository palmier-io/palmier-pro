import AVFoundation
import Foundation
import Testing
@testable import CompositorPro

/// Reproducible quality baseline fixtures for prompt-to-video evaluation.
/// Run these fixtures through both in-app agent and external MCP agent to compare results.
@Suite("Prompt-to-video quality baseline", .serialized)
struct PromptToVideoBaselineTests {

    /// Fixture set covering: prompt-to-stock-video, product footage selection, interview cleanup, ambience/SFX editing
    struct FixtureSet: Sendable {
        let name: String
        let prompt: String
        let expectedShots: Int
        let expectedDuration: ClosedRange<Double>
        let requiredCapabilities: Set<String>
        let stockQueries: [String]
        let audioRequirements: AudioRequirements

        struct AudioRequirements: Sendable {
            let needsDenoise: Bool
            let needsDebreath: Bool
            let needsLoudnessMatch: Bool
            let targetLUFS: Double?
        }
    }

    static let fixtureSets: [FixtureSet] = [
        FixtureSet(
            name: "prompt-to-stock-video",
            prompt: "Create a 30-second product intro for a coffee brand. Opening with steam rising from a cup, then beans grinding, then pouring into a mug. Upbeat music, captions for each step.",
            expectedShots: 6,
            expectedDuration: 28...32,
            requiredCapabilities: ["stock_video_search", "generate_speech", "generate_drone", "visual_search"],
            stockQueries: ["coffee steam", "coffee beans grinding", "pouring coffee", "coffee mug closeup"],
            audioRequirements: .init(needsDenoise: false, needsDebreath: false, needsLoudnessMatch: true, targetLUFS: -16)
        ),
        FixtureSet(
            name: "product-footage-selection",
            prompt: "From the provided library, select the best 5 shots showing a laptop in use: typing, screen closeup, hands on keyboard, coffee beside laptop, wide desk setup. No stock footage, only local library.",
            expectedShots: 5,
            expectedDuration: 20...30,
            requiredCapabilities: ["visual_search", "inspect_media", "inspect_timeline"],
            stockQueries: [],
            audioRequirements: .init(needsDenoise: false, needsDebreath: false, needsLoudnessMatch: true, targetLUFS: -16)
        ),
        FixtureSet(
            name: "interview-cleanup",
            prompt: "Clean up this interview clip: remove background noise, reduce breaths, match loudness to -16 LUFS, add subtle room tone. Keep natural pauses.",
            expectedShots: 1,
            expectedDuration: 58...62,
            requiredCapabilities: ["enhance_voice", "denoise_audio", "debreath_audio", "match_loudness", "generate_drone"],
            stockQueries: [],
            audioRequirements: .init(needsDenoise: true, needsDebreath: true, needsLoudnessMatch: true, targetLUFS: -16)
        ),
        FixtureSet(
            name: "ambience-sfx-editing",
            prompt: "Add ambient coffee shop sounds to this voiceover: gentle clatter, steam wand hiss, quiet chatter. Duck ambience during speech. Match -16 LUFS.",
            expectedShots: 2,
            expectedDuration: 28...32,
            requiredCapabilities: ["stock_audio_search", "match_loudness", "duck_audio"],
            stockQueries: ["coffee shop ambience", "steam wand", "cup clatter"],
            audioRequirements: .init(needsDenoise: false, needsDebreath: false, needsLoudnessMatch: true, targetLUFS: -16)
        )
    ]

    /// Record of a single fixture run for comparison
    struct RunRecord: Codable, Sendable {
        let fixtureName: String
        let timestamp: Date
        let modelID: String
        let endpointProtocol: String
        let reasoningEffort: String
        let instructionVersion: String
        let skillVersions: [String: String]
        let enabledCapabilities: [String: Bool]
        let assetIDs: [String]
        let outputTimelineRevision: Int
        let candidateSelections: [CandidateSelection]
        let rejectionReasons: [String]
        let inspectionDelivery: [InspectionRecord]
        let terminalJobStates: [TerminalJobState]
        let exportedOutputMeasurements: ExportMeasurements
    }

    struct CandidateSelection: Codable, Sendable {
        let shotIndex: Int
        let query: String
        let candidatesConsidered: Int
        let selectedMediaRef: String
        let selectionReason: String
        let inspectionFramesReceived: Int
    }

    struct InspectionRecord: Codable, Sendable {
        let toolName: String
        let mediaRef: String
        let framesReturned: Int
        let imagesIncluded: Bool
        let textMetadataKeys: [String]
    }

    struct TerminalJobState: Codable, Sendable {
        let toolName: String
        let status: String
        let durationMs: Int64
        let error: String?
    }

    struct ExportMeasurements: Codable, Sendable {
        let durationSeconds: Double
        let integratedLUFS: Double?
        let truePeakDBFS: Double?
        let clippedSamples: Int
        let fileSizeBytes: Int64
        let codec: String
        let resolution: String
    }

    /// Create test video asset with known content
    @concurrent
    static func createTestVideo(
        in directory: URL,
        name: String,
        duration: Double,
        color: CGColor = CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
    ) async throws -> URL {
        let url = directory.appendingPathComponent("\(name).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1920,
            AVVideoHeightKey: 1080,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 5_000_000]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 1920,
            kCVPixelBufferHeightKey as String: 1080,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        defer {
            if writer.status == .writing { writer.cancelWriting() }
        }
        let pool = try #require(adaptor.pixelBufferPool)
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess else {
            throw CocoaError(.fileWriteUnknown)
        }
        let pixelBuffer = try #require(buffer)
        let fps = 30
        let frameCount = Int(duration * Double(fps))
        for frame in 0..<frameCount {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                try await Task.sleep(for: .milliseconds(1))
            }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let base = CVPixelBufferGetBaseAddress(pixelBuffer)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            )!
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            let presTime = CMTime(value: Int64(frame), timescale: CMTimeScale(fps))
            guard adaptor.append(pixelBuffer, withPresentationTime: presTime) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        writer.endSession(atSourceTime: CMTime(value: Int64(frameCount), timescale: CMTimeScale(fps)))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return url
    }

    /// Create test audio asset with known loudness
    @concurrent
    static func createTestAudio(
        in directory: URL,
        name: String,
        duration: Double,
        amplitude: Float = 0.1,
        frequency: Double = 440
    ) async throws -> URL {
        let url = directory.appendingPathComponent("\(name).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = AVAudioFrameCount(duration * 48_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        let twoPi = 2.0 * Double.pi
        for i in 0..<Int(frameCount) {
            let t = Double(i) / 48_000
            let value = amplitude * Float(sin(twoPi * frequency * t))
            samples[i] = value
        }
        try file.write(from: buffer)
        return url
    }

    /// Baseline test: verify fixture assets can be created and measured
    @Test func baselineFixtureAssetsAreMeasurable() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("baseline-fixtures-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let audio = try await Self.createTestAudio(in: tempDir, name: "test-audio", duration: 5, amplitude: 0.1)

        let cache = tempDir.appendingPathComponent("loudness-cache", isDirectory: true)
        let audioMeasurement = try await LoudnessAnalyzer.integratedLoudness(for: audio, mediaRef: "audio-1", cacheDirectory: cache)

        #expect(audioMeasurement.status == LoudnessMeasurement.Status.measured)
        let lufs = try #require(audioMeasurement.integratedLUFS)
        #expect(lufs > -25 && lufs < -20)
    }

    /// Verify all fixture sets have valid configurations
    @Test func fixtureSetsHaveValidConfiguration() {
        for fixture in Self.fixtureSets {
            #expect(!fixture.name.isEmpty)
            #expect(!fixture.prompt.isEmpty)
            #expect(fixture.expectedShots > 0)
            #expect(fixture.expectedDuration.lowerBound > 0)
            #expect(fixture.expectedDuration.upperBound >= fixture.expectedDuration.lowerBound)
            #expect(!fixture.requiredCapabilities.isEmpty || fixture.stockQueries.isEmpty)
            if let target = fixture.audioRequirements.targetLUFS {
                #expect(target >= -30 && target <= -14)
            }
        }
    }

    /// Verify capability names match known operations
    @Test func fixtureCapabilitiesAreKnownOperations() {
        let knownOperations = Set([
            "stock_video_search", "generate_speech", "generate_drone", "visual_search",
            "inspect_media", "inspect_timeline", "enhance_voice", "denoise_audio",
            "debreath_audio", "match_loudness", "stock_audio_search", "duck_audio",
            "generate_video", "generate_image", "generate_audio", "upscale_media",
            "enhance_media", "cloud_transcription"
        ])
        for fixture in Self.fixtureSets {
            for cap in fixture.requiredCapabilities {
                #expect(knownOperations.contains(cap), "Unknown capability: \(cap)")
            }
        }
    }
}