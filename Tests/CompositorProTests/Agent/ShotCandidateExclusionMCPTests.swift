import AppKit
import Foundation
import MCP
import Testing
@testable import CompositorPro

private actor ShotCandidateMCPRequestProbe {
    private(set) var pages: [Int] = []

    func record(_ query: StockMediaQuery) { pages.append(query.page) }
}

private actor ShotCandidateMCPProviderGate {
    private var started = false
    private var finished = false
    private var isOpen = false
    private(set) var cancelled = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<Void, any Error>?

    func hold() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if isOpen {
                    continuation.resume()
                } else {
                    completion = continuation
                    started = true
                    startWaiters.forEach { $0.resume() }
                    startWaiters.removeAll()
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitUntilFinished() async {
        if finished { return }
        await withCheckedContinuation { finishWaiters.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = completion
        completion = nil
        waiting?.resume()
    }

    func finish(cancelled: Bool) {
        self.cancelled = cancelled
        finished = true
        finishWaiters.forEach { $0.resume() }
        finishWaiters.removeAll()
    }

    private func cancel() {
        let waiting = completion
        completion = nil
        waiting?.resume(throwing: CancellationError())
    }
}

private struct ShotCandidateMCPStockProvider: StockMediaProvider {
    let id = "pexels"
    let displayName = "Fixture"
    let supportedKinds: Set<StockMediaKind> = [.video]
    let pages: [Int: StockMediaPage]
    let probe: ShotCandidateMCPRequestProbe
    var gate: ShotCandidateMCPProviderGate? = nil
    var expectedExclusions: Set<String> = ["stock:pexels:used"]

    func search(_ query: StockMediaQuery) async throws -> StockMediaPage {
        #expect(query.excludedSourceIds == expectedExclusions)
        #expect(query.excludedSourceIds.allSatisfy { $0.hasPrefix("stock:") })
        await probe.record(query)
        do {
            if let gate { try await gate.hold() }
            try Task.checkCancellation()
            guard let page = pages[query.page] else { throw StockMediaError.undecodable(provider: displayName) }
            if let gate { await gate.finish(cancelled: false) }
            return page
        } catch {
            if let gate { await gate.finish(cancelled: error is CancellationError) }
            throw error
        }
    }
}

@Suite("Shot candidate canonical exclusions MCP", .serialized)
@MainActor
struct ShotCandidateExclusionMCPTests {
    private struct Readback: Equatable {
        let plan: Data
        let inventory: Data
        let timeline: Data
    }

    @Test func discoveryAndPlanAliasReadbackRemainReadOnly() async throws {
        try await withClient { client, harness in
            let origin = MediaImportOrigin(provider: "pexels", assetId: "pexels-photo-42", landingPageURL: nil)
            let source = harness.addAsset(id: "selected", type: .image)
            source.inputIdentity = .init(contentSHA256: String(repeating: "a", count: 64), byteCount: 100)
            let copy = harness.addAsset(id: "copy", type: .image)
            copy.inputIdentity = .init(contentSHA256: String(repeating: "b", count: 64), byteCount: 100)
            copy.importInput = MediaImportInput(origin: origin)
            var bridge = MediaManifestEntry(id: "bridge", name: "bridge", type: .image,
                source: .external(absolutePath: "/fixture/bridge"), duration: 0)
            bridge.inputIdentity = source.inputIdentity
            bridge.importInput = MediaImportInput(origin: origin)
            harness.editor.mediaManifest.entries = [source.toManifestEntry(projectURL: nil), bridge, copy.toManifestEntry(projectURL: nil)]
            let plan = EditPlan(id: "board", name: "Board", timelineId: harness.editor.activeTimelineId,
                fps: 30, width: 1920, height: 1080, status: .approved, shots: [
                    .init(id: "shot", title: "Selected", startFrame: 0, endFrame: 30, mediaRef: source.id),
                ])
            harness.editor.editPlans = [plan]
            let timeline = harness.editor.timeline
            let manifest = harness.editor.mediaManifest
            let undo = UndoManager()
            harness.editor.undo.attach(undo)
            var checkpoints = 0
            harness.editor.onProjectCheckpointRequired = { checkpoints += 1 }

            let (tools, _) = try await client.listTools()
            let tool = try #require(tools.first { $0.name == "find_shot_candidates" })
            let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
            #expect(properties["excludedSourceIds"]?.objectValue?["maxItems"]?.intValue == 256)
            #expect(properties["excludedSourceIds"]?.objectValue?["uniqueItems"]?.boolValue == true)
            #expect(properties["planId"] != nil)

            for _ in 0..<2 {
                let result = try await client.callTool(name: "find_shot_candidates", arguments: [
                    "query": .string("harbor"), "kind": .string("image"), "includeRemote": .bool(false),
                    "planId": .string("board"), "excludedSourceIds": .array([]), "limit": .int(2),
                ])
                #expect(result.isError != true)
                let receipt = try json(result)
                #expect(receipt["noOp"] as? Bool == true)
                #expect(receipt["count"] as? Int == 0)
                let exclusions = try #require(receipt["exclusions"] as? [String: Any])
                #expect(exclusions["selectedMediaRefs"] as? [String] == ["selected"])
                let ids = try #require(exclusions["sourceIds"] as? [String])
                #expect(ids.contains("media:copy"))
                #expect(ids.contains("media:bridge"))
                #expect(ids.contains(origin.sourceId))
                #expect((exclusions["unresolved"] as? [Any])?.isEmpty == true)
            }
            let read = try json(try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("read"), "planId": .string("board"),
            ]))
            #expect(read["status"] as? String == "approved")
            #expect((read["shots"] as? [[String: Any]])?.first?["mediaRef"] as? String == "selected")
            #expect(harness.editor.editPlans == [plan])
            #expect(harness.editor.timeline == timeline)
            #expect(harness.editor.mediaManifest == manifest)
            #expect(!undo.canUndo)
            #expect(checkpoints == 0)
        }
    }

    @Test func parserRejectsInvalidExclusionSetsBeforeSearchWithoutUndo() async throws {
        try await withClient { client, harness in
            let undo = UndoManager()
            harness.editor.undo.attach(undo)
            let timeline = harness.editor.timeline
            let cases: [[String: Value]] = [
                ["excludedSourceIds": .string("media:one")],
                ["excludedSourceIds": .array([.int(1)])],
                ["excludedSourceIds": .array([.string("https://example.test/source.mp4")])],
                ["excludedSourceIds": .array([.string("media:one"), .string("media:one")])],
                ["excludedSourceIds": .array((0...256).map { .string("media:\($0)") })],
                ["planId": .string("unknown")],
                ["planId": .string("bad id")],
                ["planId": .int(1)],
                ["limit": .int(0)],
                ["limit": .int(21)],
            ]
            for invalid in cases {
                let arguments: [String: Value] = ["query": .string("harbor"), "kind": .string("image"),
                    "includeRemote": .bool(false)]
                let result = try await client.callTool(name: "find_shot_candidates",
                    arguments: arguments.merging(invalid, uniquingKeysWith: { _, new in new }))
                #expect(result.isError == true)
                #expect(harness.editor.timeline == timeline)
                #expect(harness.editor.editPlans.isEmpty)
                #expect(!undo.canUndo)
            }
            let empty = try await client.callTool(name: "find_shot_candidates", arguments: [
                "query": .string("harbor"), "kind": .string("image"), "includeRemote": .bool(false),
                "excludedSourceIds": .array([]),
            ])
            #expect(empty.isError != true)
            #expect(try json(empty)["noOp"] as? Bool == true)
        }
    }

    @Test func remoteAliasExclusionsRefillBeforeLimitAndRepeatWithoutEdits() async throws {
        let probe = ShotCandidateMCPRequestProbe()
        let provider = ShotCandidateMCPStockProvider(pages: [
            1: .init(hits: [stockHit("used")], nextPage: 2, totalResults: 4),
            2: .init(hits: [stockHit("used"), stockHit("first"), stockHit("first")], nextPage: 3, totalResults: 4),
            3: .init(hits: [stockHit("second")], nextPage: nil, totalResults: 4),
        ], probe: probe)
        try await withClient(stockProviders: [provider]) { client, harness in
            seedRemotePlan(harness.editor)
            let baseline = try await readback(client)
            let plan = harness.editor.editPlans
            let manifest = harness.editor.mediaManifest
            let timeline = harness.editor.timeline
            let undo = UndoManager()
            harness.editor.undo.attach(undo)
            var checkpoints = 0
            harness.editor.onProjectCheckpointRequired = { checkpoints += 1 }

            for _ in 0..<2 {
                let response = try await client.callTool(name: "find_shot_candidates", arguments: remoteArguments(limit: 2))
                #expect(response.isError != true)
                let receipt = try json(response)
                #expect(receipt["noOp"] as? Bool == true)
                #expect(receipt["count"] as? Int == 2)
                let candidates = try #require(receipt["candidates"] as? [[String: Any]])
                #expect(candidates.compactMap { $0["candidateId"] as? String } == ["stock:pexels:first", "stock:pexels:second"])
                #expect(candidates.compactMap { $0["rank"] as? Int } == [1, 2])
                #expect(candidates.allSatisfy { $0["license"] as? String == "CC0" })
                let outcome = try providerOutcome(receipt)
                #expect(outcome["provider"] as? String == "pexels")
                #expect(outcome["status"] as? String == "ok")
                #expect(outcome["count"] as? Int == 2)
                #expect(outcome["pagesFetched"] as? Int == 3)
                #expect(outcome["exhausted"] as? Bool == true)
                #expect(outcome["totalResults"] as? Int == 4)
                #expect(outcome["nextPage"] == nil)
                #expect(try await readback(client) == baseline)
                #expect(harness.editor.editPlans == plan)
                #expect(harness.editor.mediaManifest == manifest)
                #expect(harness.editor.timeline == timeline)
                #expect(!undo.canUndo)
            }
            #expect(await probe.pages == [1, 2, 3, 1, 2, 3])
            try await expectEmptyUndo(client)
            #expect(try await readback(client) == baseline)
            #expect(checkpoints == 0)
        }
    }

    @Test func selectedSourceExpansionBeyond256AliasesReachesRemoteSearchIntact() async throws {
        let probe = ShotCandidateMCPRequestProbe()
        let excluded = Set((0...256).map { "stock:pexels:used-\($0)" })
        let provider = ShotCandidateMCPStockProvider(pages: [
            1: .init(hits: [stockHit("used-256"), stockHit("fresh")], nextPage: nil, totalResults: 2),
        ], probe: probe, expectedExclusions: excluded)
        try await withClient(stockProviders: [provider]) { client, harness in
            let source = seedRemotePlan(harness.editor)
            harness.editor.mediaManifest.entries = [source.toManifestEntry(projectURL: nil)] + (0...256).map { index in
                var entry = MediaManifestEntry(id: "alias-\(index)", name: "Alias", type: .video,
                    source: .external(absolutePath: "/fixture/alias-\(index).mov"), duration: 10)
                entry.inputIdentity = source.inputIdentity
                entry.importInput = MediaImportInput(origin: .init(provider: "pexels", assetId: "used-\(index)", landingPageURL: nil))
                return entry
            }
            let baseline = try await readback(client)
            let undo = UndoManager()
            harness.editor.undo.attach(undo)
            let response = try await client.callTool(name: "find_shot_candidates", arguments: remoteArguments(limit: 1))
            #expect(response.isError != true)
            let receipt = try json(response)
            let candidates = try #require(receipt["candidates"] as? [[String: Any]])
            #expect(candidates.compactMap { $0["candidateId"] as? String } == ["stock:pexels:fresh"])
            let exclusions = try #require(receipt["exclusions"] as? [String: Any])
            let sourceIds = try #require(exclusions["sourceIds"] as? [String])
            #expect(Set(sourceIds.filter { $0.hasPrefix("stock:") }) == excluded)
            #expect(await probe.pages == [1])
            #expect(try await readback(client) == baseline)
            #expect(!undo.canUndo)
        }
    }

    @Test func remotePaginationStopsAtBoundAndReportsRemainingPage() async throws {
        let probe = ShotCandidateMCPRequestProbe()
        let excluded = stockHit("used")
        let provider = ShotCandidateMCPStockProvider(pages: [
            1: .init(hits: [excluded], nextPage: 2, totalResults: 4),
            2: .init(hits: [excluded], nextPage: 3, totalResults: 4),
            3: .init(hits: [excluded], nextPage: 4, totalResults: 4),
            4: .init(hits: [stockHit("not-fetched")], nextPage: nil, totalResults: 4),
        ], probe: probe)
        try await withClient(stockProviders: [provider]) { client, harness in
            seedRemotePlan(harness.editor)
            let baseline = try await readback(client)
            let undo = UndoManager()
            harness.editor.undo.attach(undo)
            let response = try await client.callTool(name: "find_shot_candidates", arguments: remoteArguments(limit: 1))
            #expect(response.isError != true)
            let receipt = try json(response)
            #expect(receipt["count"] as? Int == 0)
            #expect(receipt["noOp"] as? Bool == true)
            let outcome = try providerOutcome(receipt)
            #expect(outcome["status"] as? String == "ok")
            #expect(outcome["count"] as? Int == 0)
            #expect(outcome["pagesFetched"] as? Int == 3)
            #expect(outcome["exhausted"] as? Bool == false)
            #expect(outcome["nextPage"] as? Int == 4)
            #expect(await probe.pages == [1, 2, 3])
            #expect(try await readback(client) == baseline)
            #expect(!undo.canUndo)
            try await expectEmptyUndo(client)
        }
    }

    @Test(arguments: ["project", "plan", "source", "sourceURL"])
    func changedStateRejectsProviderCompletionWithoutOverwritingChange(change: String) async throws {
        let gate = ShotCandidateMCPProviderGate()
        let provider = ShotCandidateMCPStockProvider(pages: [
            1: .init(hits: [stockHit("alternative")], nextPage: nil, totalResults: 1),
        ], probe: .init(), gate: gate)
        try await withClient(stockProviders: [provider]) { client, harness in
            let source = seedRemotePlan(harness.editor)
            let undo = UndoManager()
            harness.editor.undo.attach(undo)
            try await withProviderRequest(client, gate: gate) { request in
                switch change {
                case "project": harness.editor.projectURL = URL(fileURLWithPath: "/fixture/\(UUID().uuidString).compositorpro")
                case "plan": harness.editor.editPlans[0].notes = "Changed during retrieval"
                case "source": source.inputIdentity = .init(contentSHA256: String(repeating: "c", count: 64), byteCount: 100)
                default: source.url = URL(fileURLWithPath: "/fixture/\(UUID().uuidString).mov")
                }
                let expected = try await readback(client)
                let plan = harness.editor.editPlans
                let manifest = harness.editor.mediaManifest
                let projectURL = harness.editor.projectURL
                await gate.open()
                let response = try await request.value
                #expect(response.isError == true)
                #expect(text((response.content, response.isError)).contains("Project, plan, or library changed during shot retrieval"))
                #expect(try await readback(client) == expected)
                #expect(harness.editor.editPlans == plan)
                #expect(harness.editor.mediaManifest == manifest)
                #expect(harness.editor.projectURL == projectURL)
                #expect(!undo.canUndo)
                try await expectEmptyUndo(client)
            }
        }
    }

    @Test func clientCancellationReachesProviderGateAndPreservesReadback() async throws {
        let gate = ShotCandidateMCPProviderGate()
        let probe = ShotCandidateMCPRequestProbe()
        let provider = ShotCandidateMCPStockProvider(pages: [
            1: .init(hits: [stockHit("alternative")], nextPage: nil, totalResults: 1),
        ], probe: probe, gate: gate)
        try await withClient(stockProviders: [provider]) { client, harness in
            seedRemotePlan(harness.editor)
            let baseline = try await readback(client)
            let undo = UndoManager()
            harness.editor.undo.attach(undo)
            try await withProviderRequest(client, gate: gate) { request in
                try await client.cancelRequest(request.requestID, reason: "Fixture cancellation")
                await #expect(throws: CancellationError.self) { try await request.value }
                await gate.waitUntilFinished()
                #expect(await gate.cancelled)
                #expect(await probe.pages == [1])
                #expect(try await readback(client) == baseline)
                #expect(!undo.canUndo)
                try await expectEmptyUndo(client)
            }
        }
    }

    @Test func executorRebindingRejectsOldProjectCompletionThroughMCP() async throws {
        let first = VideoProject()
        let second = VideoProject()
        first.editorViewModel.timeline.name = "First"
        second.editorViewModel.timeline.name = "Second"
        seedRemotePlan(first.editorViewModel)
        seedRemotePlan(second.editorViewModel)
        let documents = NSDocumentController.shared
        documents.addDocument(first)
        documents.addDocument(second)
        defer {
            documents.removeDocument(first)
            documents.removeDocument(second)
        }
        let gate = ShotCandidateMCPProviderGate()
        let provider = ShotCandidateMCPStockProvider(pages: [
            1: .init(hits: [stockHit("alternative")], nextPage: nil, totalResults: 1),
        ], probe: .init(), gate: gate)
        var visible: VideoProject? = first
        let executor = ToolExecutor(projectProvider: { visible }, exportQueue: ExportQueue(), stockProviders: [provider])
        let firstUndo = UndoManager()
        let secondUndo = UndoManager()
        first.editorViewModel.undo.attach(firstUndo)
        second.editorViewModel.undo.attach(secondUndo)
        let firstPlan = first.editorViewModel.editPlans
        let firstManifest = first.editorViewModel.mediaManifest
        let firstTimeline = first.editorViewModel.timeline
        try await withClient(executor: executor) { client in
            try await withProviderRequest(client, gate: gate) { request in
                visible = second
                executor.bindProject(second)
                #expect(executor.editor === second.editorViewModel)
                let expected = try await readback(client)
                await gate.open()
                let response = try await request.value
                #expect(response.isError == true)
                #expect(text((response.content, response.isError)).contains("Project, plan, or library changed during shot retrieval"))
                #expect(try await readback(client) == expected)
                #expect(first.editorViewModel.editPlans == firstPlan)
                #expect(first.editorViewModel.mediaManifest == firstManifest)
                #expect(first.editorViewModel.timeline == firstTimeline)
                #expect(!firstUndo.canUndo)
                #expect(!secondUndo.canUndo)
                try await expectEmptyUndo(client)
            }
        }
    }

    @discardableResult
    private func seedRemotePlan(_ editor: EditorViewModel) -> MediaAsset {
        let directory = URL(fileURLWithPath: "/fixture/\(UUID().uuidString)")
        let source = MediaAsset(id: "selected", url: directory.appendingPathComponent("selected.mov"),
            type: .video, name: "Selected", duration: 10)
        source.inputIdentity = .init(contentSHA256: String(repeating: "a", count: 64), byteCount: 100)
        let origin = MediaImportOrigin(provider: "pexels", assetId: "used", landingPageURL: nil)
        let copy = MediaAsset(id: "copy", url: directory.appendingPathComponent("copy.mov"),
            type: .video, name: "Copy", duration: 10)
        copy.inputIdentity = .init(contentSHA256: String(repeating: "b", count: 64), byteCount: 100)
        copy.importInput = MediaImportInput(origin: origin)
        var bridge = MediaManifestEntry(id: "bridge", name: "Bridge", type: .video,
            source: .external(absolutePath: directory.appendingPathComponent("bridge.mov").path), duration: 10)
        bridge.inputIdentity = source.inputIdentity
        bridge.importInput = MediaImportInput(origin: origin)
        editor.mediaAssets = [source, copy]
        editor.mediaManifest.entries = [source.toManifestEntry(projectURL: nil), bridge, copy.toManifestEntry(projectURL: nil)]
        editor.editPlans = [EditPlan(id: "board", name: "Board", timelineId: editor.activeTimelineId,
            fps: editor.timeline.fps, width: editor.timeline.width, height: editor.timeline.height, status: .approved,
            shots: [.init(id: "shot", title: "Selected", startFrame: 0, endFrame: 30, mediaRef: source.id)])]
        return source
    }

    private func stockHit(_ id: String) -> StockMediaHit {
        StockMediaHit(id: id, kind: .video, title: id, url: "https://example.test/\(id).mp4",
            thumbnailURL: nil, creator: "Creator", creatorURL: nil, license: "CC0", licenseURL: nil,
            providerID: "pexels", landingPageURL: nil, width: 1920, height: 1080,
            durationSeconds: 10, fileSizeBytes: nil, attributionText: "Creator, CC0")
    }

    private func remoteArguments(limit: Int) -> [String: Value] {
        ["query": .string("harbor"), "kind": .string("video"), "includeLibrary": .bool(false),
         "planId": .string("board"), "excludedSourceIds": .array([]), "limit": .int(limit)]
    }

    private func providerOutcome(_ receipt: [String: Any]) throws -> [String: Any] {
        let remote = try #require(receipt["remote"] as? [String: Any])
        let outcomes = try #require(remote["providers"] as? [[String: Any]])
        #expect(outcomes.count == 1)
        return try #require(outcomes.first)
    }

    private func readback(_ client: Client) async throws -> Readback {
        let plan = try await client.callTool(name: "plan_edit", arguments: ["action": .string("read"), "planId": .string("board")])
        let inventory = try await client.callTool(name: "get_media", arguments: [:])
        let timeline = try await client.callTool(name: "get_timeline", arguments: [:])
        #expect(plan.isError != true)
        #expect(inventory.isError != true)
        #expect(timeline.isError != true)
        return try Readback(plan: JSONSerialization.data(withJSONObject: json(plan), options: [.sortedKeys]),
            inventory: JSONSerialization.data(withJSONObject: json(inventory), options: [.sortedKeys]),
            timeline: JSONSerialization.data(withJSONObject: json(timeline), options: [.sortedKeys]))
    }

    private func expectEmptyUndo(_ client: Client) async throws {
        let response = try await client.callTool(name: "undo", arguments: [:])
        #expect(response.isError == true)
        #expect(text(response).contains("Nothing to undo."))
    }

    private func text(_ result: (content: [Tool.Content], isError: Bool?)) -> String {
        result.content.compactMap { block in
            if case .text(let value, _, _) = block { return value }
            return nil
        }.joined()
    }

    private func json(_ result: (content: [Tool.Content], isError: Bool?)) throws -> [String: Any] {
        for block in result.content {
            if case .text(let value, _, _) = block {
                return try #require(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
            }
        }
        throw CocoaError(.coderReadCorrupt)
    }

    private func withProviderRequest(_ client: Client, gate: ShotCandidateMCPProviderGate,
        _ operation: @MainActor (RequestContext<CallTool.Result>) async throws -> Void) async throws {
        let request: RequestContext<CallTool.Result> = try await client.callTool(
            name: "find_shot_candidates", arguments: remoteArguments(limit: 1))
        await gate.waitUntilStarted()
        do {
            try await operation(request)
        } catch {
            do {
                try await client.cancelRequest(request.requestID, reason: "Fixture cleanup")
            } catch {
                Issue.record(error)
            }
            await gate.open()
            await gate.waitUntilFinished()
            throw error
        }
    }

    private func withClient(stockProviders: [any StockMediaProvider] = [],
                            _ operation: @MainActor (Client, ToolHarness) async throws -> Void) async throws {
        let harness = ToolHarness()
        let executor = ToolExecutor(editor: harness.editor, exportQueue: harness.exportQueue, stockProviders: stockProviders)
        try await withClient(executor: executor) { client in try await operation(client, harness) }
    }

    private func withClient(executor: ToolExecutor, _ operation: @MainActor (Client) async throws -> Void) async throws {
        let server = Server(name: "shot-exclusions", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "shot-exclusions", version: "1")
        do {
            try await server.start(transport: transports.server)
            _ = try await client.connect(transport: transports.client)
            try await operation(client)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }
}
