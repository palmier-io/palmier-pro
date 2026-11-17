import AppKit
import Foundation
import MCP
import Testing
@testable import CompositorPro

@MainActor
private final class PackageImportDownloadGate {
    let entered = PackageTestSignal()
    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var stage: URL?

    func recordStage(_ url: URL) { stage = url }

    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            entered.signal()
        }
    }

    func complete(_ error: Error? = nil) {
        let waiting = continuation
        continuation = nil
        if let error { waiting?.resume(throwing: error) }
        else { waiting?.resume() }
    }
}

@Suite("Project package imports through MCP", .serialized)
@MainActor
struct ProjectPackageImportMCPTests {
    @Test(arguments: ["", "???", "VA==!", "VA==\n"])
    func malformedBase64NeverMutatesLibraryOrUndo(bytes: String) async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let undo = UndoManager()
            document.editorViewModel.undo.attach(undo)
            try await withClient(editor: document.editorViewModel) { client in
                let result = try await client.callTool(name: "import_media", arguments: [
                    "source": .object(["bytes": .string(bytes), "mimeType": .string("image/png")]),
                ])
                #expect(result.isError == true)
                #expect(try await inventory(client).isEmpty)
                #expect(!undo.canUndo)
                try await savePackageTestDocument(document)
                #expect(try await fixture.readPackage().manifest?.entries.isEmpty == true)
            }
        }
    }

    @Test(arguments: [false, true])
    func importPersistenceAndUndoIndependentlyPreserveSourceBytes(fromPath: Bool) async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let data = try await MediaInputIdentityFixtures.imageData()
            let path = fixture.root.appendingPathComponent("source.png")
            try await fixture.io.perform { try data.write(to: path) }
            let editor = document.editorViewModel
            let folderId = editor.createFolder(name: "Proof")
            let undo = UndoManager()
            editor.undo.attach(undo)
            try await withClient(editor: editor) { client in
                let (tools, _) = try await client.listTools()
                #expect(tools.contains { $0.name == "import_media" })
                let source: [String: Value] = fromPath ? ["path": .string(path.path)] : [
                    "bytes": .string(data.base64EncodedString()), "mimeType": .string("image/png"),
                ]
                let result = try await client.callTool(name: "import_media", arguments: [
                    "source": .object(source), "name": .string("Named Image"), "folder": .string("Proof"),
                ])
                try #require(result.isError != true)
                let mediaRef = try #require(try json(result)["mediaRef"] as? String)
                let readback = try await inventory(client)
                #expect(readback.count == 1)
                #expect(readback.first?["id"] as? String == mediaRef)
                #expect(readback.first?["inputIdentityState"] as? String == "verified")
                try await savePackageTestDocument(document)
                let persisted = try await fixture.readPackage()
                let id = try #require(persisted.manifest?.entries.first?.id)
                #expect(id.hasPrefix(mediaRef))
                #expect(persisted.manifest?.entries.first?.name == "Named Image")
                #expect(persisted.manifest?.entries.first?.folderId == folderId)
                let installed = try #require(editor.mediaAssetsById[id]?.url)
                #expect(try await fixture.contents(of: installed) == data)
                let undone = try await client.callTool(name: "undo")
                #expect(undone.isError != true)
                #expect(try await inventory(client).isEmpty)
                #expect(!undo.canUndo)
                #expect(try await fixture.contents(of: installed) == data)
                #expect(undo.canRedo)
                undo.redo()
                #expect(try await inventory(client).count == 1)
                try await savePackageTestDocument(document)
                #expect(try await fixture.readPackage().manifest?.entries.first?.id == id)
            }
        }
    }

    @Test func repeatedLibraryImportDoesNotDuplicateMediaOrUndo() async throws {
        try await withPackageTestFixture { fixture in
            let editor = fixture.document().editorViewModel
            let undo = UndoManager()
            undo.groupsByEvent = false
            editor.undo.attach(undo)
            let asset = MediaAsset(url: try await fixture.stage(), type: .image, name: "Input")
            editor.importMediaAssetUndoably(asset)
            editor.importMediaAssetUndoably(asset)
            #expect(editor.mediaAssets.map(\.id) == [asset.id])
            #expect(editor.mediaManifest.entries.map(\.id) == [asset.id])
            undo.undo()
            #expect(editor.mediaAssets.isEmpty)
            #expect(editor.mediaManifest.entries.isEmpty)
            #expect(!undo.canUndo)
            #expect(try await fixture.exists(asset.url))
            undo.redo()
            #expect(editor.mediaAssets.map(\.id) == [asset.id])
            #expect(editor.mediaManifest.entries.map(\.id) == [asset.id])
            await editor.missingMediaRefreshTask?.value
        }
    }

    @Test func closeDrainsGrantedURLImportBeforeFinalSave() async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let data = try await MediaInputIdentityFixtures.imageData()
            let gate = PackageImportDownloadGate()
            defer { gate.complete(CancellationError()) }
            let download: ImportMediaDownload = { request, maxBytes in
                #expect(maxBytes == ToolExecutor.remoteImportMaxBytes)
                try await gate.wait()
                let stage = try await fixture.stage(data)
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(url: url, statusCode: 200,
                    httpVersion: nil, headerFields: nil))
                return (stage, response)
            }
            try await withClient(editor: document.editorViewModel, download: download) { client in
                let result = try await client.callTool(name: "import_media", arguments: [
                    "source": .object(["url": .string("https://fixture.invalid/image.png")]),
                ])
                try #require(result.isError != true)
                let mediaRef = try #require(try json(result)["mediaRef"] as? String)
                await gate.entered.wait()
                let close = try #require(document.beginClosing())
                defer { document.editorViewModel.projectPackageCoordinator.cancelClosing(close) }
                let closing = Task { try await document.saveBeforeClosing(using: close) }
                let refused = try await client.callTool(name: "import_media", arguments: [
                    "source": .object(["bytes": .string(data.base64EncodedString()), "mimeType": .string("image/png")]),
                ])
                #expect(refused.isError == true)
                gate.complete()
                try await closing.value
                let fencedRead = try await client.callTool(name: "get_media")
                #expect(fencedRead.isError == true)
                document.editorViewModel.projectPackageCoordinator.cancelClosing(close)
                let readback = try await inventory(client)
                #expect(readback.count == 1)
                #expect(readback.first?["inputIdentityState"] as? String == "verified")
                let persisted = try await fixture.readPackage()
                let id = try #require(persisted.manifest?.entries.first?.id)
                #expect(id.hasPrefix(mediaRef))
                #expect(persisted.manifest?.entries.first?.generationStatus == nil)
                let installed = try #require(document.editorViewModel.mediaAssetsById[id]?.url)
                #expect(try await fixture.contents(of: installed) == data)
            }
        }
    }

    @Test(arguments: [false, true])
    func removedOrCancelledURLImportCannotPublishSuccess(removed: Bool) async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let editor = document.editorViewModel
            let baseline = editor.mediaLibraryUndoSnapshot()
            let data = try await MediaInputIdentityFixtures.imageData()
            let gate = PackageImportDownloadGate()
            defer { gate.complete(CancellationError()) }
            let download: ImportMediaDownload = { request, _ in
                try await gate.wait()
                let output = try await fixture.stage(data)
                await gate.recordStage(output)
                return (output, URLResponse(url: try #require(request.url), mimeType: "image/png",
                    expectedContentLength: data.count, textEncodingName: nil))
            }
            try await withClient(editor: editor, download: download) { client in
                let result = try await client.callTool(name: "import_media", arguments: [
                    "source": .object(["url": .string("https://fixture.invalid/image.png")]),
                ])
                try #require(result.isError != true)
                await gate.entered.wait()
                if removed { editor.restoreMediaLibraryUndoSnapshot(baseline, actionName: "Remove") }
                gate.complete(removed ? nil : CancellationError())
                await editor.projectPackageCoordinator.waitUntilIdle()
                let readback = try await inventory(client)
                if removed {
                    #expect(readback.isEmpty)
                    #expect(editor.mediaManifest.entries.isEmpty)
                    #expect(try await !fixture.exists(try #require(gate.stage)))
                } else {
                    #expect(readback.count == 1)
                    #expect((readback.first?["generationStatus"] as? String)?.hasPrefix("failed:") == true)
                }
                try await savePackageTestDocument(document)
                let persisted = try await fixture.readPackage()
                #expect(persisted.manifest?.entries.count == (removed ? 0 : 1))
                let files = try await fixture.io.perform {
                    try FileManager.default.contentsOfDirectory(atPath: fixture.package.appendingPathComponent("media").path)
                }
                #expect(files.isEmpty)
            }
        }
    }

    private final class DownloadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return _count
        }
        func increment() {
            lock.lock()
            _count += 1
            lock.unlock()
        }
    }

    @Test func duplicateImportReusesExistingAssetWithoutDownloadingAgain() async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let editor = document.editorViewModel
            let counter = DownloadCounter()
            let countingDownload: ImportMediaDownload = { req, _ in
                counter.increment()
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
                let data = try await MediaInputIdentityFixtures.imageData()
                try data.write(to: temp)
                let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!
                return (temp, resp)
            }
            try await withClient(editor: editor, download: countingDownload) { client in
                let originArg: [String: Value] = [
                    "provider": .string("pixabay"),
                    "assetId": .string("123456"),
                ]
                let firstRes = try await client.callTool(name: "import_media", arguments: [
                    "source": .object([
                        "url": .string("https://pixabay.com/get/sample.png"),
                        "origin": .object(originArg),
                    ]),
                ])
                #expect(firstRes.isError != true)
                let firstJson = try json(firstRes)
                let firstRef = try #require(firstJson["mediaRef"] as? String)

                await editor.projectPackageCoordinator.waitUntilIdle()
                #expect(counter.count == 1)

                // Import the same origin again
                let secondRes = try await client.callTool(name: "import_media", arguments: [
                    "source": .object([
                        "url": .string("https://pixabay.com/get/sample_different_query.png"),
                        "origin": .object(originArg),
                    ]),
                ])
                #expect(secondRes.isError != true)
                let secondJson = try json(secondRes)
                let secondRef = try #require(secondJson["mediaRef"] as? String)

                #expect(secondRef == firstRef)
                #expect(counter.count == 1)
                #expect(secondJson["note"] as? String == "Reused existing imported media (already in project).")
                #expect(editor.mediaAssets.count == 1)
            }
        }
    }

    @Test func originalPixabayPageImportsTheExactVideoAndRetainsProvenance() async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let editor = document.editorViewModel
            let video = try await StoryboardTimingFixtures.video(in: fixture.root)
            let data = try await fixture.contents(of: video.url)
            editor.timeline.tracks = [Fixtures.videoTrack(id: "office-track")]
            let undo = UndoManager()
            undo.groupsByEvent = false
            editor.undo.attach(undo)
            let page = "https://pixabay.com/videos/business-office-contemporary-136268/"
            let provider = PixabayProvider(apiKey: "", requestPage: { _ in
                Data(#"<video src="https://cdn.pixabay.com/video/office.mp4"></video>"#.utf8)
            })
            let download: ImportMediaDownload = { request, _ in
                #expect(request.url?.absoluteString == "https://cdn.pixabay.com/video/office.mp4")
                return (try await fixture.stage(data), URLResponse(url: try #require(request.url),
                    mimeType: "video/mp4", expectedContentLength: data.count, textEncodingName: nil))
            }
            try await withClient(editor: editor, download: download, pageResolver: { try await provider.resolveVideoPage($0) }) { client in
                let (tools, _) = try await client.listTools()
                #expect(tools.first { $0.name == "import_media" }?.description?.contains("Pixabay video page") == true)
                let result = try await client.callTool(name: "import_media", arguments: [
                    "source": .object(["url": .string(page)]), "name": .string("Office"),
                ])
                try #require(result.isError != true)
                let id = try #require(try json(result)["mediaRef"] as? String)
                await editor.projectPackageCoordinator.waitUntilIdle()
                let assets = try await inventory(client)
                #expect(assets.count == 1)
                #expect(assets.first?["id"] as? String == id)
                #expect(assets.first?["inputIdentityState"] as? String == "verified")
                let asset = try #require(editor.mediaAssets.first { $0.id.hasPrefix(id) })
                #expect(asset.generationStatus == .none)
                #expect(asset.importInput?.sourceURL == page)
                #expect(asset.importInput?.origin?.sourceId == "stock:pixabay:pixabay-video-136268")
                #expect(try await fixture.contents(of: asset.url) == data)
                let repeated = try await client.callTool(name: "import_media", arguments: [
                    "source": .object(["url": .string("https://www.pixabay.com/en/videos/office-136268/?ref=share")]),
                ])
                #expect(try json(repeated)["mediaRef"] as? String == id)
                #expect(try await inventory(client).count == 1)
                let beforePlacement = editor.timelines
                let placed = try await client.callTool(name: "add_clips", arguments: [
                    "entries": .array([.object([
                        "mediaRef": .string(id), "trackIndex": .int(0),
                        "startFrame": .int(0), "endFrame": .int(30),
                    ])]),
                ])
                try #require(placed.isError != true, "\(placed.content)")
                let timeline = try json(try await client.callTool(name: "get_timeline"))
                let tracks = try #require(timeline["tracks"] as? [[String: Any]])
                #expect(tracks.contains { ($0["clips"] as? [[String: Any]])?.isEmpty == false })
                #expect(try await client.callTool(name: "undo").isError != true)
                #expect(editor.timelines == beforePlacement)
                #expect(try await inventory(client).count == 1)
                #expect(try await fixture.contents(of: asset.url) == data)
                try await savePackageTestDocument(document)
                #expect(try await fixture.readPackage().manifest?.entries.first?.importInput?.sourceURL == page)
            }
        }
    }

    @Test(arguments: [false, true])
    func failedOrCancelledPageResolutionDoesNotCreateMediaOrUndo(cancelled: Bool) async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let editor = document.editorViewModel
            let undo = UndoManager()
            undo.groupsByEvent = false
            editor.undo.attach(undo)
            try await withClient(editor: editor, pageResolver: { _ in
                if cancelled { throw CancellationError() }
                throw ToolError("Pixabay page access blocked; configure an API key")
            }) { client in
                let result = try await client.callTool(name: "import_media", arguments: [
                    "source": .object(["url": .string("https://pixabay.com/videos/office-136268/")]),
                    "folder": .string("B-roll/Office"),
                ])
                #expect(result.isError == true)
                #expect(try await inventory(client).isEmpty)
                #expect(editor.folders.isEmpty)
                #expect(!undo.canUndo)
                try await savePackageTestDocument(document)
                #expect(try await fixture.readPackage().manifest?.entries.isEmpty == true)
            }
        }
    }

    @Test func closingDuringPageResolutionCannotPublishAnImport() async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let editor = document.editorViewModel
            let gate = PackageImportDownloadGate()
            defer { gate.complete(CancellationError()) }
            let provider = PixabayProvider(apiKey: "", requestPage: { _ in
                Data(#"<video src="https://cdn.pixabay.com/video/office.mp4"></video>"#.utf8)
            })
            try await withClient(editor: editor, pageResolver: { url in
                try await gate.wait()
                return try await provider.resolveVideoPage(url)
            }) { client in
                let importing = Task {
                    try await client.callTool(name: "import_media", arguments: [
                        "source": .object(["url": .string("https://pixabay.com/videos/office-136268/")]),
                    ])
                }
                await gate.entered.wait()
                let close = try #require(document.beginClosing())
                defer { editor.projectPackageCoordinator.cancelClosing(close) }
                gate.complete()
                #expect(try await importing.value.isError == true)
                editor.projectPackageCoordinator.cancelClosing(close)
                #expect(try await inventory(client).isEmpty)
                #expect(editor.mediaManifest.entries.isEmpty)
            }
        }
    }

    private func withClient(editor: EditorViewModel,
        download: @escaping ImportMediaDownload = ToolExecutor.downloadImportedMedia,
        pageResolver: @escaping @Sendable (URL) async throws -> StockMediaHit = { try await PixabayProvider().resolveVideoPage($0) },
        operation: @MainActor (Client) async throws -> Void) async throws {
        let executor = ToolExecutor(editor: editor, stockProviders: [], importDownloader: download, importPageResolver: pageResolver)
        let server = Server(name: "package-import-proof", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "package-import-proof", version: "1")
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

    private func inventory(_ client: Client) async throws -> [[String: Any]] {
        try #require(try json(try await client.callTool(name: "get_media"))["assets"] as? [[String: Any]])
    }

    private func json(_ result: (content: [Tool.Content], isError: Bool?)) throws -> [String: Any] {
        for content in result.content {
            if case .text(let text, _, _) = content {
                return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            }
        }
        throw CocoaError(.coderReadCorrupt)
    }
}
