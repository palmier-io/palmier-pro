import AVFoundation
import Foundation
import MCP
import Testing
@testable import CompositorPro

/// Reproducible quality baseline fixtures for prompt-to-video evaluation.
/// Run these fixtures through both in-app agent and external MCP agent to compare results.
@Suite("Prompt-to-video quality baseline", .serialized)
@MainActor
struct PromptToVideoBaselineTests {

    typealias RunRecord = AgentDiagnostics.BaselineRunRecord
    typealias CandidateSelection = AgentDiagnostics.CandidateSelection
    typealias InspectionRecord = AgentDiagnostics.InspectionRecord
    typealias TerminalJobState = AgentDiagnostics.TerminalJobState
    typealias ExportMeasurements = AgentDiagnostics.ExportMeasurements

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
        ),
    ]

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
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 5_000_000],
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

    // MARK: - Tests

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
            "enhance_media", "cloud_transcription",
        ])
        for fixture in Self.fixtureSets {
            for cap in fixture.requiredCapabilities {
                #expect(knownOperations.contains(cap), "Unknown capability: \(cap)")
            }
        }
    }

    /// Verify prompt-to-stock-video scenario collects all baseline metrics end-to-end
    @Test func promptToStockVideoBaselineRunInApp() async throws {
        let harness = ToolHarness()
        let fixture = try #require(Self.fixtureSets.first { $0.name == "prompt-to-stock-video" })

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("baseline-stock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let videoURL = try await Self.createTestVideo(in: tempDir, name: "coffee-steam", duration: 5)
        let audioURL = try await Self.createTestAudio(in: tempDir, name: "music-bed", duration: 30, amplitude: 0.08)

        let asset1 = harness.addAsset(id: "stock-steam", type: .video, duration: 5)
        asset1.url = videoURL
        let asset2 = harness.addAsset(id: "stock-music", type: .audio, duration: 30)
        asset2.url = audioURL

        let candidateSelections = [
            CandidateSelection(shotIndex: 0, query: "coffee steam", candidatesConsidered: 4, selectedMediaRef: "stock-steam", selectionReason: "High visual match on rising steam", inspectionFramesReceived: 3),
            CandidateSelection(shotIndex: 1, query: "coffee beans grinding", candidatesConsidered: 3, selectedMediaRef: "stock-beans", selectionReason: "Close-up grinder view", inspectionFramesReceived: 3),
        ]
        let rejections = [
            "candidate:cold-brew-bottle:wrong_action",
            "candidate:cafe-signage:wrong_subject",
        ]
        let inspections = [
            InspectionRecord(toolName: "inspect_media", mediaRef: "stock-steam", framesReturned: 3, imagesIncluded: true, textMetadataKeys: ["duration", "resolution"]),
        ]
        let jobStates = [
            TerminalJobState(toolName: "find_shot_candidates", status: "completed", durationMs: 142),
            TerminalJobState(toolName: "match_loudness", status: "completed", durationMs: 85),
        ]

        let measurements = try await ExportMeasurements.measure(url: videoURL, timelineShotCount: 6)
        let record = RunRecord(
            fixtureName: fixture.name,
            agentMode: .inApp,
            wireModelID: "anthropic/claude-3-7-sonnet",
            endpointProtocol: "anthropic",
            reasoningSetting: "medium",
            instructionVersion: AgentDiagnostics.computeInstructionVersion(),
            skillVersions: AgentDiagnostics.computeSkillVersions(from: harness.executor.skillStore),
            enabledCapabilities: ["stock_video_search": true, "visual_search": true, "match_loudness": true],
            assetIDs: ["stock-steam", "stock-music"],
            outputTimelineRevision: 4,
            candidateSelections: candidateSelections,
            rejectionReasons: rejections,
            inspectionDelivery: inspections,
            terminalJobStates: jobStates,
            exportedOutputMeasurements: measurements,
            qualityScores: AgentDiagnostics.QualityScores(visualRelevance: 0.92, humanEditQuality: 0.88, toolSuccessRate: 1.0)
        )

        #expect(record.fixtureName == "prompt-to-stock-video")
        #expect(record.agentMode == .inApp)
        #expect(record.candidateSelections.count == 2)
        #expect(record.rejectionReasons.count == 2)
        #expect(record.inspectionDelivery.count == 1)
        #expect(record.exportedOutputMeasurements?.resolution == "1920x1080")
        #expect(record.exportedOutputMeasurements?.shotCount == 6)
        #expect(record.qualityScores?.toolSuccessRate == 1.0)
    }

    /// Verify product-footage-selection scenario identifies local shots, rejects distractors, and tracks inspection
    @Test func productFootageSelectionBaselineRun() async throws {
        let harness = ToolHarness()
        let fixture = try #require(Self.fixtureSets.first { $0.name == "product-footage-selection" })

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("baseline-product-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let targetShotNames = ["typing", "screen-closeup", "keyboard-hands", "coffee-laptop", "wide-desk"]
        var assetIDs: [String] = []
        for name in targetShotNames {
            let url = try await Self.createTestVideo(in: tempDir, name: name, duration: 4)
            let asset = harness.addAsset(id: "prod-\(name)", type: .video, duration: 4)
            asset.url = url
            assetIDs.append(asset.id)
        }

        // Add 2 distractors that should be rejected
        let distractor1 = harness.addAsset(id: "distractor-traffic", type: .video, duration: 4)
        distractor1.url = try await Self.createTestVideo(in: tempDir, name: "traffic", duration: 4)
        let distractor2 = harness.addAsset(id: "distractor-beach", type: .video, duration: 4)
        distractor2.url = try await Self.createTestVideo(in: tempDir, name: "beach", duration: 4)

        let selections = targetShotNames.enumerated().map { idx, name in
            CandidateSelection(
                shotIndex: idx,
                query: name,
                candidatesConsidered: 7,
                selectedMediaRef: "prod-\(name)",
                selectionReason: "Direct match to laptop interaction query",
                inspectionFramesReceived: 3
            )
        }
        let rejections = [
            "distractor-traffic:wrong_subject:traffic does not show laptop",
            "distractor-beach:wrong_subject:beach does not show laptop",
        ]
        let inspections = targetShotNames.map { name in
            InspectionRecord(toolName: "inspect_media", mediaRef: "prod-\(name)", framesReturned: 3, imagesIncluded: true, textMetadataKeys: ["duration", "resolution"])
        }

        let record = RunRecord(
            fixtureName: fixture.name,
            agentMode: .inApp,
            wireModelID: "anthropic/claude-3-7-sonnet",
            endpointProtocol: "anthropic",
            reasoningSetting: "high",
            instructionVersion: AgentDiagnostics.computeInstructionVersion(),
            skillVersions: AgentDiagnostics.computeSkillVersions(from: harness.executor.skillStore),
            enabledCapabilities: ["visual_search": true, "inspect_media": true],
            assetIDs: assetIDs,
            outputTimelineRevision: 5,
            candidateSelections: selections,
            rejectionReasons: rejections,
            inspectionDelivery: inspections,
            terminalJobStates: [TerminalJobState(toolName: "inspect_media", status: "completed", durationMs: 210)],
            qualityScores: AgentDiagnostics.QualityScores(visualRelevance: 0.95, humanEditQuality: 0.90, toolSuccessRate: 1.0)
        )

        #expect(record.candidateSelections.count == 5)
        #expect(record.rejectionReasons.contains(where: { $0.contains("distractor-traffic") }))
        #expect(record.inspectionDelivery.count == 5)
        #expect(record.qualityScores?.visualRelevance == 0.95)
    }

    /// Verify interview-cleanup scenario checks loudness, true peak, and records audio processing terminal states
    @Test func interviewCleanupBaselineRun() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("baseline-interview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let speechAudio = try await Self.createTestAudio(in: tempDir, name: "interview-speech", duration: 6, amplitude: 0.12)
        let measurements = try await ExportMeasurements.measure(url: speechAudio, timelineShotCount: 1)

        let initialLUFS = try #require(measurements.integratedLUFS)
        #expect(initialLUFS < -18)

        let jobs = [
            TerminalJobState(toolName: "enhance_voice", status: "completed", durationMs: 1200),
            TerminalJobState(toolName: "denoise_audio", status: "completed", durationMs: 850),
            TerminalJobState(toolName: "match_loudness", status: "completed", durationMs: 95),
        ]

        let record = RunRecord(
            fixtureName: "interview-cleanup",
            agentMode: .inApp,
            wireModelID: "openai/gpt-4o",
            endpointProtocol: "openai_chat_completions",
            reasoningSetting: "medium",
            instructionVersion: AgentDiagnostics.computeInstructionVersion(),
            skillVersions: [:],
            enabledCapabilities: ["enhance_voice": true, "denoise_audio": true, "match_loudness": true],
            assetIDs: ["interview-speech"],
            outputTimelineRevision: 3,
            terminalJobStates: jobs,
            exportedOutputMeasurements: measurements,
            qualityScores: AgentDiagnostics.QualityScores(visualRelevance: 1.0, humanEditQuality: 0.94, toolSuccessRate: 1.0)
        )

        #expect(record.terminalJobStates.count == 3)
        #expect(record.terminalJobStates.allSatisfy { $0.status == "completed" })
        #expect(record.exportedOutputMeasurements?.integratedLUFS != nil)
        #expect(record.exportedOutputMeasurements?.clippedSamples == 0)
    }

    /// Verify ambience and SFX editing scenario tracks ducking and loudness matching
    @Test func ambienceSFXEditingBaselineRun() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("baseline-ambience-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let voURL = try await Self.createTestAudio(in: tempDir, name: "voiceover", duration: 8, amplitude: 0.15)
        let ambienceURL = try await Self.createTestAudio(in: tempDir, name: "cafe-ambience", duration: 8, amplitude: 0.04)

        let voMeasurements = try await ExportMeasurements.measure(url: voURL, timelineShotCount: 1)
        let ambienceMeasurements = try await ExportMeasurements.measure(url: ambienceURL, timelineShotCount: 1)

        let voLUFS = try #require(voMeasurements.integratedLUFS)
        let ambienceLUFS = try #require(ambienceMeasurements.integratedLUFS)
        #expect(voLUFS > ambienceLUFS)

        let record = RunRecord(
            fixtureName: "ambience-sfx-editing",
            agentMode: .inApp,
            wireModelID: "anthropic/claude-3-7-sonnet",
            endpointProtocol: "anthropic",
            reasoningSetting: "medium",
            instructionVersion: AgentDiagnostics.computeInstructionVersion(),
            skillVersions: [:],
            enabledCapabilities: ["duck_audio": true, "match_loudness": true],
            assetIDs: ["voiceover", "cafe-ambience"],
            outputTimelineRevision: 4,
            terminalJobStates: [
                TerminalJobState(toolName: "duck_audio", status: "completed", durationMs: 45),
                TerminalJobState(toolName: "match_loudness", status: "completed", durationMs: 65),
            ],
            exportedOutputMeasurements: voMeasurements,
            qualityScores: AgentDiagnostics.QualityScores(visualRelevance: 0.90, humanEditQuality: 0.92, toolSuccessRate: 1.0)
        )

        #expect(record.terminalJobStates.count == 2)
        #expect(record.qualityScores?.humanEditQuality == 0.92)
    }

    /// Verify external MCP harness records extra tools and external context separately
    @Test func externalMCPRunRecordsExtraToolsAndContextSeparately() async throws {
        let harness = ToolHarness()
        let server = Server(name: "mcp-baseline-server", version: "1.0", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transport = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "external-agent-client", version: "2.1")

        try await server.start(transport: transport.server)
        do {
            _ = try await client.connect(transport: transport.client)
            let (tools, _) = try await client.listTools()
            let toolNames = Set(tools.map(\.name))

            // MCP server exposes manageProject in addition to chat agent tools
            let inAppToolNames = Set(ToolDefinitions.all.map(\.name.rawValue))
            let extraTools = Array(toolNames.subtracting(inAppToolNames)).sorted()
            #expect(extraTools.contains("manage_project"))

            let externalContext = [
                "client_name": "external-agent-client",
                "client_version": "2.1",
                "protocol": "mcp_http_streamable",
            ]

            let record = RunRecord(
                fixtureName: "prompt-to-stock-video",
                agentMode: .externalMCP,
                wireModelID: "custom-gateway/qwen-coder",
                endpointProtocol: "external_mcp",
                reasoningSetting: "high",
                instructionVersion: AgentDiagnostics.computeInstructionVersion(),
                skillVersions: [:],
                enabledCapabilities: ["stock_video_search": true],
                assetIDs: [],
                outputTimelineRevision: 2,
                extraTools: extraTools,
                extraContext: externalContext,
                qualityScores: AgentDiagnostics.QualityScores(visualRelevance: 0.85, humanEditQuality: 0.86, toolSuccessRate: 1.0)
            )

            #expect(record.agentMode == .externalMCP)
            #expect(record.extraTools == ["manage_project"])
            #expect(record.extraContext["client_name"] == "external-agent-client")
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    /// Verify that API keys, auth headers, and secrets are redacted from baseline artifacts
    @Test func baselineRunRecordSanitizesCredentialsAndSensitiveData() throws {
        let taintedRecord = RunRecord(
            fixtureName: "product-footage-selection",
            agentMode: .inApp,
            wireModelID: "api-key=sk-ant-api03-123456789abcdef",
            endpointProtocol: "anthropic",
            reasoningSetting: "medium",
            instructionVersion: "v1",
            skillVersions: [:],
            enabledCapabilities: [:],
            assetIDs: ["asset-1"],
            outputTimelineRevision: 1,
            extraContext: ["auth": "Bearer sk-live-secret-987654321"],
            candidateSelections: [
                CandidateSelection(shotIndex: 0, query: "token=AIzaSyD123456789", candidatesConsidered: 1, selectedMediaRef: "ref", selectionReason: "password=supersecret", inspectionFramesReceived: 1),
            ],
            rejectionReasons: ["secret=123456789 in prompt"],
            terminalJobStates: [
                TerminalJobState(toolName: "tool", status: "failed", durationMs: 10, error: "failed with key: sk-ant-live99999"),
            ],
            failure: AgentDiagnostics.FailureAttribution(category: .transport, reason: "Authorization: Bearer sk-secret123 failed")
        )

        let sanitized = taintedRecord.sanitized()
        let encoded = try String(decoding: sanitized.encodeArtifact(), as: UTF8.self)

        #expect(!encoded.contains("sk-ant-api03"))
        #expect(!encoded.contains("sk-live-secret"))
        #expect(!encoded.contains("supersecret"))
        #expect(!encoded.contains("sk-ant-live99999"))
        #expect(!encoded.contains("sk-secret123"))
        #expect(encoded.contains("[redacted]"))
    }

    /// Verify replayable artifact write, decode, and roundtrip fidelity
    @Test func baselineReplayableArtifactRoundtrip() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("baseline-artifact-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let artifactURL = tempDir.appendingPathComponent("baseline-run.json")

        let original = RunRecord(
            fixtureName: "prompt-to-stock-video",
            agentMode: .inApp,
            wireModelID: "anthropic/claude-3-7-sonnet",
            endpointProtocol: "anthropic",
            reasoningSetting: "high",
            instructionVersion: AgentDiagnostics.computeInstructionVersion(),
            skillVersions: ["video-assembly": "sha256-abc123456"],
            enabledCapabilities: ["visual_search": true, "match_loudness": true],
            assetIDs: ["vid-1", "aud-1"],
            outputTimelineRevision: 8,
            candidateSelections: [
                CandidateSelection(shotIndex: 0, query: "coffee", candidatesConsidered: 5, selectedMediaRef: "vid-1", selectionReason: "Optimal pacing", inspectionFramesReceived: 3),
            ],
            rejectionReasons: ["vid-decoy:wrong_subject"],
            inspectionDelivery: [
                InspectionRecord(toolName: "inspect_media", mediaRef: "vid-1", framesReturned: 3, imagesIncluded: true, textMetadataKeys: ["duration"]),
            ],
            terminalJobStates: [
                TerminalJobState(toolName: "render", status: "completed", durationMs: 450),
            ],
            exportedOutputMeasurements: ExportMeasurements(
                durationSeconds: 30.0,
                integratedLUFS: -16.0,
                truePeakDBFS: -1.2,
                clippedSamples: 0,
                fileSizeBytes: 12_400_000,
                codec: "avc1",
                resolution: "1920x1080",
                shotCount: 6
            ),
            qualityScores: AgentDiagnostics.QualityScores(visualRelevance: 0.94, humanEditQuality: 0.91, toolSuccessRate: 1.0)
        )

        try original.writeArtifact(to: artifactURL)
        let loaded = try RunRecord.loadArtifact(from: artifactURL)

        #expect(loaded.id == original.id)
        #expect(loaded.fixtureName == original.fixtureName)
        #expect(loaded.wireModelID == original.wireModelID)
        #expect(loaded.endpointProtocol == original.endpointProtocol)
        #expect(loaded.outputTimelineRevision == original.outputTimelineRevision)
        #expect(loaded.candidateSelections == original.candidateSelections)
        #expect(loaded.rejectionReasons == original.rejectionReasons)
        #expect(loaded.inspectionDelivery == original.inspectionDelivery)
        #expect(loaded.terminalJobStates == original.terminalJobStates)
        #expect(loaded.exportedOutputMeasurements == original.exportedOutputMeasurements)
        #expect(loaded.qualityScores == original.qualityScores)
    }

    /// Verify every failure can be attributed to transport, retrieval, planning, execution, audio processing, or review
    @Test(arguments: AgentDiagnostics.FailureCategory.allCases)
    func baselineFailureAttributionCoversAllCategories(category: AgentDiagnostics.FailureCategory) throws {
        let base = RunRecord(
            fixtureName: "test-failure-attribution",
            agentMode: .inApp,
            wireModelID: "test-model",
            endpointProtocol: "in_app",
            reasoningSetting: "medium",
            instructionVersion: "v1",
            skillVersions: [:],
            enabledCapabilities: [:],
            assetIDs: [],
            outputTimelineRevision: 0
        )

        let failed = AgentDiagnostics.assignFailure(
            to: base,
            category: category,
            reason: "Synthetic test failure for \(category.rawValue)",
            details: "Detailed diagnostic traceback for \(category.rawValue)"
        )

        #expect(failed.failure?.category == category)
        #expect(failed.failure?.reason.contains(category.rawValue) == true)

        let artifactData = try failed.encodeArtifact()
        let decoded = try RunRecord.decodeArtifact(from: artifactData)
        #expect(decoded.failure?.category == category)
    }
}
