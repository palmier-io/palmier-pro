import Combine
import Foundation
import Testing
@testable import CompositorPro

@Suite("Performance optimization audit", .serialized)
@MainActor
struct PerformanceOptimizationAuditTests {
    private func asset(_ id: String, width: Int = 1_920, height: Int = 1_080) -> MediaAsset {
        let asset = MediaAsset(id: id, url: URL(string: "https://example.invalid/synthetic.mov")!,
                               type: .video, name: id, duration: 30)
        asset.sourceWidth = width
        asset.sourceHeight = height
        asset.hasAudio = false
        return asset
    }

    @inline(never)
    private func baselineSourceDimensions(_ editor: EditorViewModel, _ clip: Clip) -> (width: Int, height: Int)? {
        if let asset = editor.mediaAssets.first(where: { $0.id == clip.mediaRef }),
           let width = asset.sourceWidth, let height = asset.sourceHeight, width > 0, height > 0 {
            return (width, height)
        }
        if clip.sourceClipType == .sequence, let child = editor.timeline(for: clip.mediaRef),
           child.width > 0, child.height > 0 {
            return (child.width, child.height)
        }
        return nil
    }

    private func medianMilliseconds(prepare: () -> Void = {}, operation: () throws -> Void) rethrows -> Double {
        prepare()
        try operation()
        var samples: [Double] = []
        for _ in 0..<5 {
            prepare()
            let start = ContinuousClock.now
            try operation()
            let elapsed = (ContinuousClock.now - start).components
            samples.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
        }
        return samples.sorted()[2]
    }

    @Test func lookupIndexFollowsReplacementRemovalAndDuplicateOrder() {
        let editor = EditorViewModel()
        let first = asset("shared")
        let second = asset("shared", width: 720, height: 480)
        let clip = Fixtures.clip(mediaRef: "shared", start: 0, duration: 30)
        for library in [[first, second], [second, first], [second], []] {
            editor.mediaAssets = library
            let current = editor.sourceDimensions(for: clip)
            let baseline = baselineSourceDimensions(editor, clip)
            #expect(current?.width == baseline?.width)
            #expect(current?.height == baseline?.height)
            #expect(editor.mediaAssetsById["shared"] === library.first)
        }
    }

    @Test func lookupIndexObservesMetadataChangesWithoutReplacingLibrary() {
        let editor = EditorViewModel()
        let source = asset("source")
        editor.mediaAssets = [source]
        let clip = Fixtures.clip(mediaRef: "source", start: 0, duration: 30)
        for dimensions in [(720, 480), (0, 480), (-1, 480), (720, 0), (3_840, 2_160)] {
            source.sourceWidth = dimensions.0
            source.sourceHeight = dimensions.1
            #expect(editor.sourceDimensions(for: clip)?.width == baselineSourceDimensions(editor, clip)?.width)
            #expect(editor.sourceDimensions(for: clip)?.height == baselineSourceDimensions(editor, clip)?.height)
        }
        source.sourceWidth = nil
        #expect(editor.sourceDimensions(for: clip) == nil)
    }

    @Test func lookupIndexDoesNotRetainRemovedAssets() {
        let editor = EditorViewModel()
        weak var retained: MediaAsset?
        autoreleasepool {
            let source = asset("removed")
            retained = source
            editor.mediaAssets = [source]
        }
        #expect(retained != nil)
        editor.mediaAssets.removeAll()
        #expect(editor.mediaAssetsById.isEmpty)
        #expect(retained == nil)
    }

    @Test func nestedSourceDimensionsFollowChildReframing() {
        let editor = EditorViewModel()
        var child = Fixtures.timeline()
        child.width = 720
        child.height = 480
        editor.timelines.append(child)
        let clip = Fixtures.clip(mediaRef: child.id, mediaType: .sequence, start: 0, duration: 30)
        #expect(editor.sourceDimensions(for: clip)?.width == 720)
        let index = editor.timelines.firstIndex { $0.id == child.id }!
        editor.timelines[index].width = 1_080
        editor.timelines[index].height = 1_920
        #expect(editor.sourceDimensions(for: clip)?.width == 1_080)
        #expect(baselineSourceDimensions(editor, clip)?.height == 1_920)
    }

    @Test func layoutPlacementTracksSlotAndCanvasChanges() {
        let editor = EditorViewModel()
        editor.timeline.width = 1_920
        editor.timeline.height = 1_080
        editor.mediaAssets = [asset("source")]
        let clip = Fixtures.clip(mediaRef: "source", start: 0, duration: 30)
        let full = LayoutRect(x: 0, y: 0, w: 1, h: 1)
        let left = editor.layoutPlacement(for: clip, in: .init(x: 0, y: 0, w: 0.5, h: 1), fit: .fill)
        let top = editor.layoutPlacement(for: clip, in: .init(x: 0, y: 0, w: 1, h: 0.5), fit: .fill)
        #expect(abs(left.crop.left - 0.25) < 1e-6)
        #expect(abs(top.crop.top - 0.25) < 1e-6)
        #expect(editor.layoutPlacement(for: clip, in: full, fit: .fill).crop == Crop())
        editor.timeline.width = 1_080
        editor.timeline.height = 1_920
        let portrait = editor.layoutPlacement(for: clip, in: full, fit: .fill)
        #expect(abs(portrait.crop.left - 0.341796875) < 1e-6)
        #expect(abs(portrait.transform.width * portrait.crop.visibleWidthFraction - 1) < 1e-6)
    }

    @Test func benchmarkSourceLookupAgainstLinearBaseline() {
        let editor = EditorViewModel()
        for count in [100, 1_000, 10_000] {
            editor.mediaAssets = (0..<count).map { asset("asset-\($0)") }
            let clips = (0..<1_000).map { Fixtures.clip(mediaRef: "asset-\(($0 * 37) % count)", start: 0, duration: 30) }
            var productionChecksum = 0
            let production = medianMilliseconds {
                productionChecksum = 0
                for clip in clips { productionChecksum += editor.sourceDimensions(for: clip)?.width ?? 0 }
            }
            var baselineChecksum = 0
            let baseline = medianMilliseconds {
                baselineChecksum = 0
                for clip in clips { baselineChecksum += baselineSourceDimensions(editor, clip)?.width ?? 0 }
            }
            #expect(productionChecksum == baselineChecksum)
            print("AUDIT_LOOKUP assets=\(count) lookups=1000 samples=5 current_index_ms=\(production) baseline_linear_ms=\(baseline)")
        }
    }

    @Test func benchmarkBatchLayoutWithGrowingUnselectedTimeline() throws {
        for count in [256, 2_048, 8_192] {
            let clips = (0..<(count - 1)).map { Fixtures.clip(id: "clip-\($0)", mediaRef: "left", start: $0 * 30, duration: 30) }
            let carrier = Fixtures.clip(id: "right", mediaRef: "right", start: 0, duration: (count - 1) * 30)
            var timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: clips), Fixtures.videoTrack(clips: [carrier])])
            timeline.width = 1_920
            timeline.height = 1_080
            timeline.settingsConfigured = true
            let editor = EditorViewModel()
            editor.mediaAssets = [asset("left"), asset("right")]
            let undo = UndoManager()
            editor.undo.attach(undo)
            let executor = ToolExecutor(editor: editor)
            let args: [String: Any] = ["layout": "side_by_side", "slots": [
                ["slot": "left", "clipIds": Array(clips.prefix(128).map(\.id))],
                ["slot": "right", "clipIds": ["right"]],
            ]]
            let elapsed = try medianMilliseconds(prepare: {
                undo.removeAllActions()
                editor.timeline = timeline
            }) {
                _ = try executor.applyLayout(editor, args)
            }
            #expect(editor.timeline.tracks[0].clips[127].transform.centerX == 0.25)
            print("AUDIT_LAYOUT timeline_clips=\(count) edited_clips=129 samples=5 median_ms=\(elapsed)")
        }
    }

    @Test func markerSnapFramesAreOrderedUniqueAndExcludeRanges() {
        let editor = EditorViewModel()
        let point = TimelineMarker(id: "point", name: "Point", startFrame: 40)
        let range = TimelineMarker(id: "range", name: "Range", startFrame: 10, durationFrames: 30)
        editor.timeline.markers = [point, range]
        #expect(editor.timelineMarkerSnapFrames() == [10, 40])
        #expect(editor.timelineMarkerSnapFrames(excludingMarkerIds: ["range"]) == [40])
        editor.timeline.markers[0].startFrame = 80
        #expect(editor.timelineMarkerSnapFrames() == [10, 40, 80])
    }

    @Test func benchmarkRepeatedMarkerSnapFrameConstruction() {
        let editor = EditorViewModel()
        for count in [100, 1_000, 10_000] {
            editor.timeline.markers = (0..<count).map {
                TimelineMarker(id: "marker-\($0)", name: "Marker", startFrame: (($0 * 37) % count) * 30,
                               durationFrames: $0.isMultiple(of: 2) ? 15 : 0)
            }
            var checksum = 0
            let elapsed = medianMilliseconds {
                checksum = 0
                for _ in 0..<120 { checksum += editor.timelineMarkerSnapFrames().count }
            }
            #expect(checksum == (count + count / 2) * 120)
            print("AUDIT_MARKERS markers=\(count) snap_rebuilds=120 samples=5 median_ms=\(elapsed) per_rebuild_ms=\(elapsed / 120)")
        }
    }

    @Test func cancelingGenerationSubscriptionCancelsInFlightPollingTask() async throws {
        let previousProvider = GenerationBackend.provider
        let provider = AuditPollingProvider()
        GenerationBackend.provider = provider
        defer { GenerationBackend.provider = previousProvider }
        let publisher = try #require(GenerationBackend.subscribe(jobId: UUID().uuidString))
        let subscription = publisher.sink { _ in }
        await provider.waitUntilStarted()
        subscription.cancel()
        let canceled = await provider.releaseAndObserveCancellation()
        #expect(canceled, "Publisher cancellation leaves the generation polling task uncanceled")
        print("AUDIT_POLL publisher_canceled=true polling_task_canceled=\(canceled)")
    }

    @Test(arguments: [
        ("Generate an image of a harbor", "generate_image"),
        ("Create background music for this scene", "generate_audio"),
        ("Generate narration for the intro", "generate_speech"),
        ("Create an image of a harbor", "generate_image"),
        ("Create a soundtrack for this scene", "generate_audio"),
        ("Add a voiceover to the intro", "generate_speech"),
    ])
    func generativeRequestsKeepRequiredTools(request: String, requiredTool: String) async throws {
        let record = try await advertisedTools([AgentMessage(role: .user, blocks: [.text(request)])])
        #expect(record.names.contains(requiredTool), "\(request) omits \(requiredTool)")
    }

    @Test func resumedProductionAfterToolResultKeepsGenerationTools() async throws {
        let record = try await advertisedTools([
            AgentMessage(role: .user, blocks: [.text("Make a video about sailing")]),
            AgentMessage(role: .assistant, blocks: [.toolUse(id: "read", name: "get_timeline", inputJSON: "{}")]),
            AgentMessage(role: .user, blocks: [.toolResult(toolUseId: "read", content: [.text("{}")], isError: false)]),
        ])
        #expect(record.names.contains("generate_video"))
    }

    @Test func productionFollowUpKeepsRequiredTools() async throws {
        let record = try await advertisedTools([
            AgentMessage(role: .user, blocks: [.text("Make a video about sailing")]),
            AgentMessage(role: .assistant, blocks: [.text("I can create the shots and soundtrack. Proceed?")]),
            AgentMessage(role: .user, blocks: [.text("Yes, do it")]),
        ])
        #expect(record.names.contains("generate_video"))
        #expect(record.names.contains("generate_audio"))
    }

    @Test func productionAndEditingSchemaPayloadMeasurements() async throws {
        let full = try await advertisedTools([AgentMessage(role: .user, blocks: [.text("Make a video about sailing")])])
        let edit = try await advertisedTools([AgentMessage(role: .user, blocks: [.text("Trim the selected clip")])])
        #expect(full.names.contains("generate_video"))
        #expect(edit.names.contains("set_clip_properties"))
        #expect(edit.names.contains("manage_markers"))
        #expect(edit.bytes < full.bytes)
        print("AUDIT_SCHEMAS full_tools=\(full.names.count) full_json_bytes=\(full.bytes) full_system_bytes=\(full.systemBytes) edit_tools=\(edit.names.count) edit_json_bytes=\(edit.bytes) edit_system_bytes=\(edit.systemBytes)")
    }

    private func advertisedTools(_ messages: [AgentMessage]) async throws -> AuditToolRecord {
        let suite = "performance-audit-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try await Task.detached {
            let directory = URL(fileURLWithPath: "/private/var/folders/3v/qg3xv_lj5wz8_83qnp3zz6yc0000gn/T/opencode")
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }.value
        let service = AgentService(userDefaults: defaults, skillStore: SkillStore(directory: directory))
        let session = ChatSession(messages: messages)
        service.sessions = [session]
        service.currentSessionId = session.id
        service.messages = messages
        let client = AuditToolClient()
        await service.kickOffStream(conversationID: session.id, traceID: UUID(),
                                   settings: .init(model: .defaultModel, reasoningEffort: .low), client: client).value
        await service.cancelAndWait()
        try await Task.detached { try FileManager.default.removeItem(at: directory) }.value
        return try #require(await client.record)
    }
}

private struct AuditToolRecord: Sendable {
    let names: [String]
    let bytes: Int
    let systemBytes: Int
}

private actor AuditToolClient: AgentClient {
    private(set) var record: AuditToolRecord?

    nonisolated func stream(system: String, tools: [AgentToolSchema], messages: [AgentRequestMessage],
                            context: AgentRequestContext) -> AgentStreamOperation {
        makeAgentStream { continuation in
            try await self.capture(tools, system: system)
            continuation.yield(.textDelta("Verified"))
            continuation.yield(.messageStop(stopReason: .endTurn))
        }
    }

    private func capture(_ tools: [AgentToolSchema], system: String) throws {
        let schemas = tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.inputSchema] as [String: Any] }
        record = AuditToolRecord(names: tools.map(\.name), bytes: try JSONSerialization.data(withJSONObject: schemas, options: [.sortedKeys]).count,
                                 systemBytes: system.utf8.count)
    }
}

private actor AuditPollingProvider: GenerationProvider {
    let id = "audit-polling"
    let displayName = "Audit polling"
    let supportedModalities: Set<String> = ["video"]
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var statusGate: CheckedContinuation<Void, Never>?
    private var canceledWaiter: CheckedContinuation<Bool, Never>?
    private var canceled: Bool?

    func waitUntilStarted() async {
        guard statusGate == nil else { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func releaseAndObserveCancellation() async -> Bool {
        statusGate?.resume()
        statusGate = nil
        if let canceled { return canceled }
        return await withCheckedContinuation { canceledWaiter = $0 }
    }

    func status(jobId: String) async throws -> BackendGenerationJob? {
        await withCheckedContinuation {
            statusGate = $0
            startedWaiter?.resume()
            startedWaiter = nil
        }
        let observedCancellation = Task.isCancelled
        canceled = observedCancellation
        canceledWaiter?.resume(returning: observedCancellation)
        canceledWaiter = nil
        return nil
    }

    func submit(model: String, params: BackendGenerationParams, projectId: String?) async throws -> String {
        throw BackendUnavailableError.hostedServicesRemoved
    }

    func cancel(jobId: String) async throws {}

    func uploadReference(fileURL: URL, contentType: String) async throws -> String {
        throw BackendUnavailableError.hostedServicesRemoved
    }
}
