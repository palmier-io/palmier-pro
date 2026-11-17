import Foundation
import Testing
@testable import CompositorPro

@Suite("Agent inspection context")
@MainActor
struct AgentInspectionContextTests {
    @Test(arguments: [true, false])
    func consumedInspectionImagesDoNotAccumulateInLongEditingRequests(latestHasImages: Bool) async throws {
        try await withService { service in
            let image = String(repeating: "A", count: 1_000_000)
            service.messages = [AgentMessage(role: .user, blocks: [.text("Inspect the footage and finish the edit")])]
            for batch in 0..<2 {
                let ids = (0..<10).map { "inspection-\(batch)-\($0)" }
                service.messages.append(AgentMessage(role: .assistant, blocks: ids.map {
                    .toolUse(id: $0, name: "inspect_media", inputJSON: "{}")
                }))
                service.appendToolResults(ids.map {
                    .toolResult(toolUseId: $0, content: [.text("Metadata for \($0)"), .image(base64: image, mediaType: "image/jpeg")], isError: false)
                }, conversationID: service.currentSessionId!)
            }
            let ids = ["latest-a", "latest-b"]
            service.messages.append(AgentMessage(role: .assistant, blocks: ids.map {
                .toolUse(id: $0, name: "inspect_media", inputJSON: "{}")
            }))
            service.appendToolResults(ids.map {
                var blocks: [ToolResult.Block] = [.text("Metadata for \($0)")]
                if latestHasImages { blocks.append(.image(base64: "AA==", mediaType: "image/jpeg")) }
                return .toolResult(toolUseId: $0, content: blocks, isError: $0 == "latest-b")
            }, conversationID: service.currentSessionId!)
            let originalMessages = service.messages
            let client = InspectionContextClient(retryOnce: true)
            await service.kickOffStream(conversationID: service.currentSessionId!, traceID: UUID(),
                                        settings: service.snapshotRunSettings(), client: client).value

            let requests = await client.requests
            try #require(requests.count == 2)
            for request in requests {
                let results = toolResults(request)
                #expect(results.count == 22)
                for result in results {
                    #expect(result.blocks.contains { if case .text(let value) = $0 { value == "Metadata for \(result.id)" } else { false } })
                    let images = result.blocks.compactMap { if case .image(let value, _) = $0 { value } else { nil } }
                    #expect(images.count == (latestHasImages && ids.contains(result.id) ? 1 : 0))
                    if ids.contains(result.id), latestHasImages { #expect(images == ["AA=="]) }
                    if !ids.contains(result.id) {
                        #expect(result.blocks.contains { if case .text(let value) = $0 { value.contains("Inspection image omitted") } else { false } })
                    }
                    #expect(result.isError == (result.id == "latest-b"))
                }
                let calls = request.flatMap(\.content).compactMap { block -> String? in
                    if case .content(.toolUse(let id, _, _)) = block { return id }
                    return nil
                }
                #expect(Set(calls) == Set(results.map(\.id)))
                let wireByteCount = try await Self.wireByteCount(request)
                #expect(wireByteCount < 1_000_000)
            }
            let retained = Array(service.messages.prefix(originalMessages.count))
            #expect(retained.map(\.id) == originalMessages.map(\.id))
            #expect(retained.map(\.role) == originalMessages.map(\.role))
            #expect(try await Self.blocksUnchanged(retained.map(\.blocks), originalMessages.map(\.blocks)))
            #expect(service.streamError == nil)
        }
    }

    @Test func firstInspectionBatchReachesTheProviderIntact() async throws {
        try await withService { service in
            service.messages = [
                AgentMessage(role: .user, blocks: [.text("Inspect this shot")]),
                AgentMessage(role: .assistant, blocks: [.toolUse(id: "first", name: "inspect_media", inputJSON: "{}")]),
                AgentMessage(role: .user, blocks: [.toolResult(toolUseId: "first", content: [
                    .image(base64: "aW1hZ2U=", mediaType: "image/png"), .text("Frame at 0 seconds"),
                ], isError: false)]),
            ]
            let client = InspectionContextClient()
            await service.kickOffStream(conversationID: service.currentSessionId!, traceID: UUID(),
                                        settings: service.snapshotRunSettings(), client: client).value
            let request = try #require(await client.requests.first)
            let result = try #require(toolResults(request).first)
            #expect(result.id == "first")
            #expect(result.blocks.count == 2)
            if case .image(let base64, let mediaType) = result.blocks[0] {
                #expect(base64 == "aW1hZ2U=")
                #expect(mediaType == "image/png")
            } else { Issue.record("The initial inspection image was discarded") }
        }
    }

    private func toolResults(_ messages: [AgentRequestMessage]) -> [(id: String, blocks: [ToolResult.Block], isError: Bool)] {
        messages.flatMap(\.content).compactMap {
            if case .content(.toolResult(let id, let blocks, let isError)) = $0 { return (id, blocks, isError) }
            return nil
        }
    }

    @concurrent private static func wireByteCount(_ messages: [AgentRequestMessage]) async throws -> Int {
        let body = OpenAIChatCompletionsRequestBody.build(modelID: "fixture", system: "", tools: [], messages: messages)
        return try JSONSerialization.data(withJSONObject: body).count
    }

    @concurrent private static func blocksUnchanged(_ retained: [[AgentContentBlock]], _ original: [[AgentContentBlock]]) async throws -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(retained) == encoder.encode(original)
    }

    private func withService(_ operation: (AgentService) async throws -> Void) async throws {
        let suite = "inspection-context-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let skills = SkillStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(suite), includeBuiltins: false)
        let service = AgentService(userDefaults: defaults, skillStore: skills, credentialLoader: { AgentCredentialSnapshot() },
                                   customKeyLoader: { _ in "" }, sessionLoader: { _ in [] })
        do { try await operation(service) }
        catch { await service.cancelAndWait(); throw error }
        await service.cancelAndWait()
    }
}

private actor InspectionContextClient: AgentClient {
    let retryOnce: Bool
    private(set) var requests: [[AgentRequestMessage]] = []

    init(retryOnce: Bool = false) { self.retryOnce = retryOnce }

    nonisolated func stream(system: String, tools: [AgentToolSchema], messages: [AgentRequestMessage],
                            context: AgentRequestContext) -> AgentStreamOperation {
        makeAgentStream { continuation in
            let retry = await self.record(messages)
            if retry { throw URLError(.timedOut) }
            continuation.yield(.textDelta("Inspected"))
            continuation.yield(.messageStop(stopReason: .endTurn))
        }
    }

    private func record(_ messages: [AgentRequestMessage]) -> Bool {
        requests.append(messages)
        return retryOnce && requests.count == 1
    }
}
