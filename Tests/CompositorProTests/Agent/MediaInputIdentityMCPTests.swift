import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("Media input identity MCP")
@MainActor
struct MediaInputIdentityMCPTests {
    @Test func copiedImportsExposeOneInputIDAndDistinctPlacementIDsPersistAndUndo() async throws {
        try await withClient { client, harness, directory in
            let (tools, _) = try await client.listTools()
            let importer = try #require(tools.first { $0.name == "import_media" })
            #expect(importer.inputSchema.objectValue?["properties"]?.objectValue?["source"]?.objectValue?["properties"]?.objectValue?["origin"] != nil)
            var refs: [String] = []
            var inputIds: [String] = []
            for filename in ["original.png", "renamed.png"] {
                let result = try await client.callTool(name: "import_media", arguments: [
                    "source": .object(["path": .string(directory.appendingPathComponent(filename).path)]),
                ])
                let receipt = try json(result.content)
                try #require(result.isError != true)
                refs.append(try #require(receipt["mediaRef"] as? String))
                inputIds.append(try #require(receipt["inputId"] as? String))
                #expect(receipt["inputIdentityState"] as? String == "verified")
            }
            #expect(Set(refs).count == 2)
            #expect(Set(inputIds).count == 1)
            let inventory = try await client.callTool(name: "get_media")
            let assets = try #require(try json(inventory.content)["assets"] as? [[String: Any]])
            #expect(assets.count == 2)
            #expect(Set(assets.compactMap { $0["inputId"] as? String }) == Set(inputIds))

            let manifest = harness.editor.mediaManifest
            let persisted = try await Task.detached {
                let url = directory.appendingPathComponent("manifest.json")
                try JSONEncoder().encode(manifest).write(to: url)
                return try JSONDecoder().decode(MediaManifest.self, from: Data(contentsOf: url))
            }.value
            #expect(persisted == manifest)
            #expect(persisted.entries.compactMap(\.inputIdentity).count == 2)

            let undo = UndoManager()
            harness.editor.undo.attach(undo)
            let baseline = harness.editor.timeline
            let added = try await client.callTool(name: "add_clips", arguments: ["entries": .array(refs.enumerated().map { index, ref in
                .object(["mediaRef": .string(ref), "startFrame": .int(index * 60), "endFrame": .int(index * 60 + 30)])
            })])
            try #require(added.isError != true)
            let delta = try #require(try json(added.content)["clips"] as? [[String: Any]])
            #expect(Set(delta.compactMap { $0["inputId"] as? String }) == Set(inputIds))
            let read = try await client.callTool(name: "get_timeline")
            let tracks = try #require(try json(read.content)["tracks"] as? [[String: Any]])
            let clips = tracks.flatMap { $0["clips"] as? [[String: Any]] ?? [] }
            #expect(clips.count == 2)
            #expect(Set(clips.compactMap { $0["id"] as? String }).count == 2)
            #expect(Set(clips.compactMap { $0["inputId"] as? String }) == Set(inputIds))
            _ = try await client.callTool(name: "undo")
            #expect(harness.editor.timeline == baseline)
            #expect(!undo.canUndo)
        }
    }

    @Test func invalidOriginClaimsAreRefusedWithoutDownloadOrMutation() async throws {
        try await withClient { client, harness, _ in
            let undo = UndoManager()
            harness.editor.undo.attach(undo)
            let origins: [Value] = [
                .string("invalid"),
                .object(["provider": .string("unknown"), "assetId": .string("42")]),
                .object(["provider": .string("pexels"), "assetId": .int(42)]),
                .object(["provider": .string("pexels"), "assetId": .string("42"), "sourceId": .string("different")]),
                .object(["provider": .string("pexels"), "assetId": .string("42"), "landingPageUrl": .string("http://example.com/42")]),
            ]
            for origin in origins {
                let refused = try await client.callTool(name: "import_media", arguments: [
                    "source": .object(["url": .string("https://example.invalid/stock.mp4"), "origin": origin]),
                ])
                #expect(refused.isError == true)
            }
            #expect(harness.editor.mediaAssets.isEmpty)
            #expect(harness.editor.mediaManifest.entries.isEmpty)
            #expect(!undo.canUndo)
        }
    }

    @Test func corruptByteImportReportsFailureAndRetainsFailedRecord() async throws {
        try await withClient { client, harness, _ in
            let result = try await client.callTool(name: "import_media", arguments: [
                "source": .object(["bytes": .string(Data("not an image".utf8).base64EncodedString()), "mimeType": .string("image/png")]),
            ])
            #expect(result.isError == true)
            let asset = try #require(harness.editor.mediaAssets.first)
            #expect(asset.inputIdentity == nil)
            #expect(asset.generationStatus == .failed("Could not read media file."))
            let inventory = try await client.callTool(name: "get_media")
            let assets = try #require(try json(inventory.content)["assets"] as? [[String: Any]])
            #expect(assets.count == 1)
            #expect(assets.first?["inputIdentityState"] as? String == "unresolved")
            #expect(harness.editor.unprocessableMediaRefs.contains(asset.id))
        }
    }

    private func withClient(_ operation: @MainActor (Client, ToolHarness, URL) async throws -> Void) async throws {
        let directory = try await MediaInputIdentityFixtures.makeFiles()
        let harness = ToolHarness()
        harness.editor.timeline.settingsConfigured = true
        harness.editor.projectURL = directory.appendingPathComponent("Identity.palmier")
        let server = Server(name: "media-identity", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "media-identity-tests", version: "1")
        do {
            try await server.start(transport: transports.server)
            _ = try await client.connect(transport: transports.client)
            try await operation(client, harness, directory)
        } catch {
            await server.stop()
            await client.disconnect()
            try await MediaInputIdentityFixtures.remove(directory)
            throw error
        }
        await server.stop()
        await client.disconnect()
        try await MediaInputIdentityFixtures.remove(directory)
    }

    private func json(_ content: [Tool.Content]) throws -> [String: Any] {
        for block in content {
            if case .text(let text, _, _) = block {
                return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            }
        }
        throw CocoaError(.coderReadCorrupt)
    }
}
