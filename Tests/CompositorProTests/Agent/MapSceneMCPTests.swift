import AppKit
import AVFoundation
import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("Map scenes through MCP", .serialized)
@MainActor
struct MapSceneMCPTests {
    @Test func discoversBuildsReadsPersistsAndUndoesOneIntent() async throws {
        try await withSavedMediaPackageTestFixture { fixture, document in
            let editor = document.editorViewModel
            editor.timeline = Fixtures.timeline(fps: 30, tracks: [Fixtures.videoTrack(clips: [Fixtures.clip(id: "existing", start: 0, duration: 90)])])
            editor.selectedClipIds = ["existing"]
            let before = editor.timeline
            let undo = UndoManager()
            undo.groupsByEvent = false
            editor.undo.attach(undo)
            try await withClient(editor) { client in
                let (tools, _) = try await client.listTools()
                let build = try #require(tools.first { $0.name == "build_map_scene" })
                let properties = try #require(build.inputSchema.objectValue?["properties"]?.objectValue)
                #expect(properties["objects"]?.objectValue?["items"]?.objectValue?["properties"]?.objectValue?["kind"]?.objectValue?["enum"]?.arrayValue?.contains(.string("ship")) == true)
                #expect(properties["fps"]?.objectValue?["maximum"] == .int(120))
                #expect(tools.contains { $0.name == "list_map_regions" })
                #expect(tools.contains { $0.name == "read_map_scene" })
                let atlas = try json(try await client.callTool(name: "list_map_regions", arguments: ["query": .string("Georgia")]))
                let regions = try #require(atlas["regions"] as? [[String: Any]])
                #expect(Set(regions.compactMap { $0["id"] as? String }).isSuperset(of: ["country:GEO", "subdivision:US-GA"]))

                let request = buildRequest()
                let built = try await client.callTool(name: "build_map_scene", arguments: request)
                let builtText = try jsonText(built)
                try #require(built.isError != true, "\(builtText)")
                let receipt = try json(built)
                let mediaRef = try #require(receipt["mediaRef"] as? String)
                #expect(receipt["changed"] as? Bool == true)
                #expect(receipt["undoSteps"] as? Int == 1)
                #expect(receipt["fps"] as? Int == 24)
                #expect(receipt["placementFrames"] as? Int == 30)
                let asset = try #require(editor.mediaAssets.first { $0.id.hasPrefix(mediaRef) })
                let map = try #require(asset.mapScene)
                #expect(map.input.objects?.first?.kind == .ship)
                #expect(map.videoDigest.count == 64)
                let url = asset.url
                #expect(abs(try await AVURLAsset(url: url).load(.duration).seconds - 1) < 0.001)
                let inventory = try json(try await client.callTool(name: "get_media"))
                #expect((inventory["assets"] as? [[String: Any]])?.count == 1)
                let read = try json(try await client.callTool(name: "read_map_scene", arguments: ["mediaRef": .string(mediaRef)]))
                #expect((read["spec"] as? [String: Any])?["digest"] as? String == map.digest)
                let timeline = try json(try await client.callTool(name: "get_timeline"))
                let tracks = try #require(timeline["tracks"] as? [[String: Any]])
                #expect(tracks.count == before.tracks.count + 1)
                #expect(editor.timeline.tracks.flatMap(\.clips).filter { $0.mediaRef == asset.id }.count == 1)
                #expect(editor.timeline.tracks.last == before.tracks.last)

                let repeated = try json(try await client.callTool(name: "build_map_scene", arguments: request))
                #expect(repeated["changed"] as? Bool == false)
                #expect(repeated["reused"] as? Bool == true)
                #expect(repeated["undoSteps"] as? Int == 0)
                #expect(repeated["mediaRef"] as? String == mediaRef)
                #expect(editor.mediaAssets.count == 1)
                try await savePackageTestDocument(document)
                let persisted = try await fixture.readPackage()
                #expect(persisted.manifest?.entries.first?.mapScene == map)
                let bytes = try await fixture.contents(of: url)
                _ = try await client.callTool(name: "undo")
                #expect(editor.timeline == before)
                #expect(editor.selectedClipIds == ["existing"])
                #expect(editor.mediaAssets.isEmpty)
                #expect(!undo.canUndo)
                #expect(try await fixture.contents(of: url) == bytes)
                undo.redo()
                #expect(editor.mediaAssets.first?.mapScene == map)
                let copy = fixture.root.appendingPathComponent("Copy.compositorpro", isDirectory: true)
                try await savePackageTestDocument(document, to: copy, operation: .saveAsOperation)
                let copied = try await fixture.readPackage(at: copy)
                let entry = try #require(copied.manifest?.entries.first)
                #expect(entry.mapScene == map)
                #expect(asset.url.path.hasPrefix(copy.path + "/"))
                let restored = MediaAsset(entry: entry, resolvedURL: asset.url)
                #expect(restored.mapScene == map)
                let restoredEditor = EditorViewModel()
                restoredEditor.importMediaAsset(restored)
                try await withClient(restoredEditor) { restoredClient in
                    let read = try json(try await restoredClient.callTool(name: "read_map_scene", arguments: ["mediaRef": .string(entry.id)]))
                    #expect((read["spec"] as? [String: Any])?["videoDigest"] as? String == map.videoDigest)
                }
            }
        }
    }

    @Test func invalidRequestsNeverMutateLibraryTimelineOrHistory() async throws {
        try await withSavedMediaPackageTestFixture { _, document in
            let editor = document.editorViewModel
            let before = editor.timeline
            let undo = UndoManager()
            undo.groupsByEvent = false
            editor.undo.attach(undo)
            try await withClient(editor) { client in
                let requests: [[String: Value]] = [
                    ["places": .array([.object(["name": .string("Atlantis")])])],
                    ["places": .array([.object(["name": .string("Georgia")])])],
                    ["places": .array([.object(["name": .string("Penang")])]), "fps": .int(121)],
                    ["places": .array([.object(["name": .string("Penang")])]), "objects": .array([.object(["id": .string("ship"), "kind": .string("ship"), "routeId": .string("unknown")])])],
                    ["places": .array([.object(["name": .string("Penang")])]), "objects": .array([.object(["id": .string("ship"), "kind": .string("ship"), "place": .string("Penang"), "speed": .int(2)])])],
                    ["places": .array([.object(["name": .string("Malaysia")])]), "regions": .array([.object(["name": .string("Malaysia"), "componentIndices": .array([.int(999)])])])],
                    ["places": .array([.object(["name": .string("Penang")])]), "durationFrames": .int(1), "fps": .int(120), "addToTimeline": .bool(true)],
                ]
                for request in requests {
                    let refused = try await client.callTool(name: "build_map_scene", arguments: request)
                    #expect(refused.isError == true)
                    #expect(editor.timeline == before)
                    #expect(editor.mediaAssets.isEmpty)
                    #expect(!undo.canUndo)
                }
                #expect((try await client.callTool(name: "read_map_scene", arguments: ["mediaRef": .string("missing")])).isError == true)
                #expect((try await client.callTool(name: "list_map_regions", arguments: ["limit": .int(0)])).isError == true)
            }
        }
    }

    @Test func importedCustomObjectAcceptsShortMediaReferenceAndPersistsItsFingerprint() async throws {
        try await withSavedMediaPackageTestFixture { fixture, document in
            let editor = document.editorViewModel
            let undo = UndoManager()
            undo.groupsByEvent = false
            editor.undo.attach(undo)
            try await withClient(editor) { client in
                let image = try await MediaInputIdentityFixtures.imageData(width: 64, height: 64)
                let imported = try json(try await client.callTool(name: "import_media", arguments: [
                    "source": .object(["bytes": .string(image.base64EncodedString()), "mimeType": .string("image/png")]),
                    "name": .string("Custom ship"),
                ]))
                let reference = try #require(imported["mediaRef"] as? String)
                let made = try await client.callTool(name: "build_map_scene", arguments: [
                    "places": .array([.object(["name": .string("Penang")])]),
                    "objects": .array([.object(["id": .string("custom"), "kind": .string("image"), "place": .string("Penang"), "imageMediaRef": .string(reference)])]),
                    "width": .int(480), "height": .int(270), "durationFrames": .int(6), "palette": .object(["relief": .bool(false)]),
                ])
                let madeText = try jsonText(made)
                try #require(made.isError != true, "\(madeText)")
                let map = try #require(editor.mediaAssets.last?.mapScene)
                let source = try #require(editor.mediaAssets.first)
                #expect(map.imageDigests[source.id]?.count == 64)
                #expect(map.input.objects?.first?.imageMediaRef == source.id)
                try await savePackageTestDocument(document)
                #expect(try await fixture.readPackage().manifest?.entries.last?.mapScene == map)
                _ = try await client.callTool(name: "undo")
                #expect(editor.mediaAssets.map(\.id) == [source.id])
                #expect(try await fixture.exists(source.url))
            }
        }
    }

    @Test func portraitMapProofRendersReliefRegionsCameraAndTradeObjects() async throws {
        try await withSavedMediaPackageTestFixture { fixture, document in
            try await withClient(document.editorViewModel) { client in
                let request: [String: Value] = [
                    "places": .array([
                        .object(["name": .string("Port Klang"), "latitude": .double(3.0), "longitude": .double(101.35), "showPin": .bool(true), "showLabel": .bool(false)]),
                        .object(["name": .string("Tanjung Pelepas"), "showLabel": .bool(false)]),
                    ]),
                    "regions": .array([.object(["name": .string("country:MYS"), "showLabel": .bool(false), "color": .string("#FECC52"), "opacity": .double(0.5), "pulse": .bool(true)])]),
                    "connections": .array([.object(["id": .string("sea"), "from": .string("Port Klang"), "to": .string("Tanjung Pelepas"), "revealFrames": .int(12), "via": .array([
                        .object(["latitude": .double(2.5), "longitude": .double(100.5)]), .object(["latitude": .double(1.0), "longitude": .double(102.5)]),
                    ]), "color": .string("#FFAF59"), "width": .int(5)])]),
                    "objects": .array([
                        .object(["id": .string("ship"), "kind": .string("ship"), "routeId": .string("sea"), "startFrame": .int(14), "endFrame": .int(66), "size": .int(52)]),
                        .object(["id": .string("cargo"), "kind": .string("package"), "routeId": .string("sea"), "startFrame": .int(24), "endFrame": .int(68), "size": .int(30), "color": .string("#FFCB52")]),
                    ]),
                    "camera": .array([
                        .object(["frame": .int(0), "latitude": .double(3.6), "longitude": .double(108.5), "zoom": .double(0.8)]),
                        .object(["frame": .int(35), "latitude": .double(2.7), "longitude": .double(102), "zoom": .double(2.3), "rotation": .int(-5), "tilt": .int(12)]),
                        .object(["frame": .int(71), "latitude": .double(1.6), "longitude": .double(102.8), "zoom": .double(2.8)]),
                    ]),
                    "texts": .array([
                        .object(["id": .string("title"), "text": .string("TRADE IN MOTION"), "fontSize": .int(52), "x": .double(0.5), "y": .double(0.13), "entrance": .string("pop")]),
                        .object(["id": .string("caption"), "text": .string("PORTS  •  SHIPS  •  CARGO"), "fontSize": .int(26), "x": .double(0.5), "y": .double(0.78), "startFrame": .int(24), "entrance": .string("slide")]),
                    ]),
                    "durationFrames": .int(72), "fps": .int(24), "width": .int(540), "height": .int(960), "name": .string("Map motion proof"),
                ]
                let result = try await client.callTool(name: "build_map_scene", arguments: request)
                let resultText = try jsonText(result)
                try #require(result.isError != true, "\(resultText)")
                let asset = try #require(document.editorViewModel.mediaAssets.last)
                let url = asset.url
                let metadata = try await MediaAssetMetadata.load(.init(url: url, type: .video, thumbnailMaxPixelSize: nil))
                #expect(metadata.width == 540)
                #expect(metadata.height == 960)
                #expect(abs((metadata.duration ?? 0) - 3) < 0.001)
                #expect(asset.mapScene?.imageDigests[MapSceneRenderResources.reliefKey] != nil)
                if let destination = ProcessInfo.processInfo.environment["COMPOSITOR_MAP_PROOF_DIRECTORY"] {
                    let target = URL(fileURLWithPath: destination, isDirectory: true)
                    try await fixture.io.perform {
                        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                        let output = target.appendingPathComponent("map-motion-proof.mov")
                        try FileManager.default.copyItem(at: url, to: output)
                    }
                }
            }
        }
    }

    @Test func narratedMapAndCargoExportWithMeasuredSentenceTiming() async throws {
        try await withSavedMediaPackageTestFixture { fixture, document in
            let editor = document.editorViewModel
            editor.timeline = Fixtures.timeline(fps: 24)
            editor.timeline.width = 1080
            editor.timeline.height = 1920
            let undo = UndoManager()
            undo.groupsByEvent = false
            editor.undo.attach(undo)
            let suite = "MapNarratedProof-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let queue = ExportQueue(historyStore: defaults)
            editor.exportQueue = queue
            do {
                try await withClient(editor) { client in
                    let voices = SpeechSynthesizer.voices(matchingLanguage: "en-US")
                    let voice = try #require(voices.first(where: \.isEnhanced) ?? voices.first)
                    var secondStart = 0
                    for sentence in ["Follow the cargo ship. It carries packages across the sea.",
                                     "At the next port, those packages continue their journey by truck."] {
                        let speech = try await client.callTool(name: "generate_speech", arguments: [
                            "engine": .string("system"), "voice": .string(voice.identifier), "rate": .double(1.08),
                            "text": .string(sentence), "placeAtFrame": .int(secondStart), "trackName": .string("Narration"),
                        ])
                        let speechText = try jsonText(speech)
                        try #require(speech.isError != true, "\(speechText)")
                        if secondStart == 0 {
                            secondStart = Int(ceil(try #require(editor.mediaAssets.last).duration * 24))
                        }
                    }
                    let duration = editor.timeline.totalFrames + 12
                    let built = try await client.callTool(name: "build_map_scene", arguments: [
                        "places": .array([
                            .object(["name": .string("Port Klang"), "latitude": .double(3.0), "longitude": .double(101.35)]),
                            .object(["name": .string("Tanjung Pelepas")]), .object(["name": .string("Johor Bahru")]),
                        ]),
                        "regions": .array([.object(["name": .string("country:MYS"), "showLabel": .bool(false), "opacity": .double(0.35)])]),
                        "connections": .array([
                            .object(["id": .string("sea"), "from": .string("Port Klang"), "to": .string("Tanjung Pelepas"), "revealFrames": .int(12),
                                "via": .array([.object(["latitude": .double(2.5), "longitude": .double(100.5)]),
                                               .object(["latitude": .double(1.0), "longitude": .double(102.5)])])]),
                            .object(["id": .string("road"), "from": .string("Tanjung Pelepas"), "to": .string("Johor Bahru"),
                                "revealFrame": .int(secondStart), "revealFrames": .int(12), "color": .string("#FF725B")]),
                        ]),
                        "objects": .array([
                            .object(["id": .string("ship"), "kind": .string("ship"), "routeId": .string("sea"), "startFrame": .int(12), "endFrame": .int(secondStart), "size": .int(104)]),
                            .object(["id": .string("cargo"), "kind": .string("package"), "routeId": .string("sea"), "startFrame": .int(24), "endFrame": .int(secondStart), "size": .int(60), "color": .string("#FFCB52")]),
                            .object(["id": .string("truck"), "kind": .string("truck"), "routeId": .string("road"), "startFrame": .int(secondStart + 12),
                                "endFrame": .int(duration), "size": .int(96), "rotateToPath": .bool(true)]),
                        ]),
                        "camera": .array([
                            .object(["frame": .int(0), "latitude": .double(3.6), "longitude": .double(106), "zoom": .double(1.2)]),
                            .object(["frame": .int(secondStart - 1), "latitude": .double(1.6), "longitude": .double(103.4), "zoom": .double(7)]),
                        ]),
                        "texts": .array([
                            .object(["id": .string("hook"), "text": .string("FOLLOW THE CARGO"), "fontSize": .int(96), "y": .double(0.15), "endFrame": .int(secondStart)]),
                            .object(["id": .string("transfer"), "text": .string("THE JOURNEY CONTINUES"), "fontSize": .int(80), "y": .double(0.15), "startFrame": .int(secondStart)]),
                        ]),
                        "palette": .object(["labelSize": .int(42)]), "durationFrames": .int(duration), "addToTimeline": .bool(true),
                    ])
                    let builtText = try jsonText(built)
                    try #require(built.isError != true, "\(builtText)")
                    let clips = editor.timeline.tracks.filter { $0.type == .audio }.flatMap(\.clips)
                    #expect(clips.map(\.startFrame).sorted() == [0, secondStart])
                    let mixed = try await client.callTool(name: "mix_audio", arguments: [
                        "roles": .array(clips.map { .object(["clipId": .string($0.id), "role": .string("voice")]) }),
                        "targetLUFS": .int(-18), "truePeakDBTP": .int(-1),
                    ])
                    let mixedText = try jsonText(mixed)
                    if RuntimeCapabilities.bundledSpeech && MLXRuntime.isAvailable {
                        try #require(mixed.isError != true, "\(mixedText)")
                        #expect(editor.timeline.audioMix?.speechDetection.values.allSatisfy { $0 == "voiceActivity" } == true)
                    } else {
                        #expect(mixed.isError == true)
                        #expect(mixedText.contains("Speech timing is unavailable"))
                    }
                    let output = fixture.root.appendingPathComponent("narrated-map-proof.mp4")
                    let submitted = try json(try await client.callTool(name: "export_project", arguments: [
                        "codec": .string("H.264"), "outputPath": .string(output.path),
                    ]))
                    let job = try #require(submitted["jobId"] as? String)
                    let completed = try json(try await client.callTool(name: "manage_exports", arguments: ["action": .string("wait"), "jobId": .string(job)]))
                    #expect(completed["status"] as? String == "completed", "\(completed)")
                    let metadata = try await MediaAssetMetadata.load(.init(url: output, type: .video, thumbnailMaxPixelSize: nil))
                    #expect(metadata.width == 1080 && metadata.height == 1920 && metadata.hasAudio == true)
                    #expect(abs((metadata.duration ?? 0) - Double(duration) / 24) < 0.1)
                    #expect(try await AudioFinishingFixtures.rms(output) > 0.001)
                    try await savePackageTestDocument(document)
                    if let destination = ProcessInfo.processInfo.environment["COMPOSITOR_MAP_PROOF_DIRECTORY"] {
                        let target = URL(fileURLWithPath: destination, isDirectory: true)
                        try await fixture.io.perform {
                            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                            try FileManager.default.copyItem(at: output, to: target.appendingPathComponent("narrated-map-proof.mp4"))
                            try FileManager.default.copyItem(at: fixture.package, to: target.appendingPathComponent("MapExplainer.compositorpro"))
                        }
                    }
                }
            } catch {
                for job in queue.jobs where job.status.isPending { queue.cancel(job.id) }
                do { try await Task { @MainActor in try await queue.waitWhileExportActive() }.value }
                catch let cleanup { throw ProjectPackageCleanupError(operationError: error, cleanupError: cleanup) }
                throw error
            }
        }
    }

    private func buildRequest() -> [String: Value] {
        ["places": .array([.object(["name": .string("Penang")]), .object(["name": .string("Kulim")])]),
         "connections": .array([.object(["from": .string("Penang"), "to": .string("Kulim"), "id": .string("route"), "revealFrames": .int(6)])]),
         "objects": .array([.object(["id": .string("ship"), "kind": .string("ship"), "routeId": .string("route"), "entrance": .string("none")])]),
         "durationFrames": .int(24), "fps": .int(24), "width": .int(480), "height": .int(270),
         "palette": .object(["relief": .bool(false)]), "addToTimeline": .bool(true), "startFrame": .int(60)]
    }

    private func withClient(_ editor: EditorViewModel, operation: @MainActor (Client) async throws -> Void) async throws {
        let server = Server(name: "map-proof", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: ToolExecutor(editor: editor))
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "map-proof-tests", version: "1")
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

    private func jsonText(_ result: (content: [Tool.Content], isError: Bool?)) throws -> String {
        for content in result.content { if case .text(let text, _, _) = content { return text } }
        throw CocoaError(.coderReadCorrupt)
    }

    private func json(_ result: (content: [Tool.Content], isError: Bool?)) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(jsonText(result).utf8)) as? [String: Any])
    }
}
