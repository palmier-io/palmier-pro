import CoreGraphics
import Foundation
import MCP
import Testing

@testable import CompositorPro

@Suite("Add clips atomic batch undo through MCP")
@MainActor
struct AddClipsBatchUndoMCPTests {
    @Test func adjacentReplacementsRestoreExactTimelineAndSelectionWithUndoAndRedo() async throws {
        try await withClient { client, harness, undo, refs in
            let editor = harness.editor
            var before = editor.timelines
            let selectionBefore = editor.selectedClipIds
            let readBefore = try await readback(client)
            let added = try await client.callTool(name: "add_clips", arguments: ["entries": .array((0..<3).map { index in
                .object([
                    "mediaRef": .string(refs[index]), "trackIndex": .int(1),
                    "startFrame": .int(index * 30),
                    "source": .array([.double(Double(index)), .double(Double(index + 1))]),
                ])
            })])
            try #require(added.isError != true)
            var after = editor.timelines
            let selectionAfter = editor.selectedClipIds
            let replacements = editor.timeline.tracks[1].clips
            #expect(replacements.map(\.mediaRef) == Array(refs.prefix(3)))
            #expect(replacements.map(\.startFrame) == [0, 30, 60])
            #expect(replacements.map(\.durationFrames) == [30, 30, 30])
            #expect(replacements.map(\.trimStartFrame) == [0, 30, 60])
            #expect(Set(replacements.map(\.id)).count == 3)
            #expect(editor.timeline.tracks[0] == before[0].tracks[0])
            #expect(editor.timeline.tracks[2] == before[0].tracks[2])
            #expect(editor.timeline.tracks.filter { $0.type == .audio }.flatMap(\.clips).count == 1)
            #expect(editor.timeline.width == 1280)
            #expect(editor.timeline.height == 720)
            #expect(editor.timelines[1].settingsConfigured)
            #expect(selectionAfter == ["caption", "music"])
            #expect(undo.groupingLevel == 0)
            let readAfter = try await readback(client)
            #expect(readAfter != readBefore)

            editor.timelines[1].folderId = "retained-sibling-folder"
            before[1].folderId = "retained-sibling-folder"
            after[1].folderId = "retained-sibling-folder"

            let reverted = try await client.callTool(name: "undo")
            #expect(reverted.isError != true)
            #expect(editor.timelines == before)
            #expect(editor.selectedClipIds == selectionBefore)
            #expect(try await readback(client) == readBefore)
            #expect(!undo.canUndo)
            #expect(undo.canRedo)
            #expect(!editor.timelines[1].settingsConfigured)

            undo.redo()
            #expect(editor.timelines == after)
            #expect(editor.selectedClipIds == selectionAfter)
            #expect(try await readback(client) == readAfter)
            #expect(!undo.canRedo)

            #expect(try await client.callTool(name: "undo").isError != true)
            #expect(editor.timelines == before)
            #expect(editor.selectedClipIds == selectionBefore)
            #expect(try await readback(client) == readBefore)
            #expect(!undo.canUndo)
        }
    }

    @Test(arguments: [false, true])
    func laterInvalidOrUnplaceableEntryLeavesNoMutationOrUndo(failsDuringPlacement: Bool) async throws {
        try await withClient { client, harness, undo, refs in
            let editor = harness.editor
            let before = editor.timelines
            let selection = editor.selectedClipIds
            let readBefore = try await readback(client)
            let laterRef = failsDuringPlacement ? refs[3] : "missing-source"
            let refused = try await client.callTool(name: "add_clips", arguments: ["entries": .array([
                .object(["mediaRef": .string(refs[0]), "trackIndex": .int(1), "startFrame": .int(0), "endFrame": .int(30)]),
                .object(["mediaRef": .string(laterRef), "trackIndex": .int(1), "startFrame": .int(30), "endFrame": .int(60)]),
            ])])
            #expect(refused.isError == true)
            #expect(editor.timelines == before)
            #expect(editor.selectedClipIds == selection)
            #expect(try await readback(client) == readBefore)
            #expect(!undo.canUndo)
            #expect(!undo.canRedo)
            #expect(undo.groupingLevel == 0)
        }
    }

    private func readback(_ client: Client) async throws -> Data {
        let result = try await client.callTool(name: "get_timeline", arguments: ["captionDetail": .bool(true)])
        try #require(result.isError != true)
        let content = try #require(result.content.first)
        guard case .text(let text, _, _) = content else { throw CocoaError(.coderReadCorrupt) }
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func withClient(
        _ body: @MainActor (Client, ToolHarness, UndoManager, [String]) async throws -> Void
    ) async throws {
        try await withPackageTestFixture { fixture in
            let caption = Fixtures.clip(id: "caption", mediaType: .text, start: 0, duration: 90)
            let original = Fixtures.clip(id: "original", mediaRef: "old-source", start: 0, duration: 90)
            let music = Fixtures.clip(id: "music", mediaRef: "music-source", mediaType: .audio, start: 0, duration: 90)
            let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
                Fixtures.videoTrack(id: "captions", clips: [caption]),
                Fixtures.videoTrack(id: "picture", clips: [original]),
                Fixtures.audioTrack(id: "A1", clips: [music]),
            ]))
            harness.editor.timelines.append(Fixtures.timeline())
            harness.editor.selectedClipIds = ["original", "caption", "music"]
            let defaultsName = "AddClipsBatchUndoMCPTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: defaultsName))
            defer { defaults.removePersistentDomain(forName: defaultsName) }
            let pixel = try #require(CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage())
            var refs: [String] = []
            for index in 0..<4 {
                let url = try await fixture.stage()
                let asset = MediaAsset(id: "replacement-\(index)", url: url, type: .video,
                                       name: "Replacement \(index)", duration: index == 3 ? 0 : 3)
                asset.sourceWidth = 1280
                asset.sourceHeight = 720
                asset.hasAudio = false
                harness.editor.mediaAssets.append(asset)
                let cache = harness.editor.mediaVisualCache
                cache.knownAssetURLs[asset.id] = url
                let generation = cache.startVisualGeneration(key: asset.id, kind: .videoThumbnails)
                #expect(cache.commitVideoThumbnails([(0, pixel)], key: asset.id, url: url, generation: generation))
                refs.append(asset.id)
            }
            let undo = UndoManager()
            harness.editor.undo.attach(undo)
            let executor = ToolExecutor(editor: harness.editor, exportQueue: harness.exportQueue, userDefaults: defaults)
            let server = Server(name: "batch-undo", version: "1", capabilities: .init(tools: .init(listChanged: false)))
            await MCPService.registerTools(on: server, executor: executor)
            let transports = await InMemoryTransport.createConnectedPair()
            let client = Client(name: "batch-undo-test", version: "1")
            try await server.start(transport: transports.server)
            do {
                _ = try await client.connect(transport: transports.client)
                try await body(client, harness, undo, refs)
            } catch {
                await client.disconnect()
                await server.stop()
                throw error
            }
            await client.disconnect()
            await server.stop()
        }
    }
}
