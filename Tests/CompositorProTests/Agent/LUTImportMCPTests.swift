import CoreImage
import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("Immutable LUT imports through MCP", .serialized)
@MainActor
struct LUTImportMCPTests {
    private func withClient(_ executor: ToolExecutor, body: (Client) async throws -> Void) async throws {
        let server = Server(name: "lut-import", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: executor)
        let pair = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "lut-import-tests", version: "1")
        try await server.start(transport: pair.server)
        do {
            _ = try await client.connect(transport: pair.client)
            try await body(client)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    private func arguments(_ path: String) -> [String: Value] {
        ["clipIds": .array([.string("graded")]), "lut": .object(["path": .string(path)])]
    }

    private func path(in editor: EditorViewModel) throws -> String {
        try #require(editor.clipFor(id: "graded")?.effects?.first(where: { $0.type == "color.lut" })?.params["path"]?.string)
    }

    @Test func sameNamesPreserveIndependentGradesPersistedPathsAndUndoBytes() async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let editor = document.editorViewModel
            editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [Fixtures.clip(id: "graded", start: 0, duration: 90)])])
            try await savePackageTestDocument(document)
            let executor = ToolExecutor(editor: editor)
            let storage = fixture.root.appendingPathComponent("luts")
            executor.lutStoring = { try await LUTLoader.store(path: $0, projectId: $1, storageDirectory: storage) }
            let red = Data(("LUT_3D_SIZE 2\n" + String(repeating: "1 0 0\n", count: 8)).utf8)
            let green = Data(("LUT_3D_SIZE 2\n" + String(repeating: "0 1 0\n", count: 8)).utf8)
            let sources = try await fixture.io.perform {
                let first = fixture.root.appendingPathComponent("first/look.cube")
                let second = fixture.root.appendingPathComponent("second/look.cube")
                for url in [first, second] { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
                try red.write(to: first)
                try green.write(to: second)
                return (first, second)
            }
            let undo = UndoManager()
            editor.undo.attach(undo)
            let before = editor.timeline
            try await withClient(executor) { (client: Client) async throws in
                #expect(try await client.callTool(name: "apply_color", arguments: arguments(sources.0.path)).isError != true)
                let redPath = try path(in: editor)
                let redGrade = editor.timeline
                #expect(try await client.callTool(name: "apply_color", arguments: arguments(sources.0.path)).isError != true)
                #expect(editor.timeline == redGrade)
                #expect(try await client.callTool(name: "apply_color", arguments: arguments(sources.1.path)).isError != true)
                let greenPath = try path(in: editor)
                #expect(redPath != greenPath)
                #expect(URL(fileURLWithPath: redPath).lastPathComponent == "look.cube")
                #expect(try await fixture.contents(of: URL(fileURLWithPath: redPath)) == red)
                #expect(try await fixture.contents(of: URL(fileURLWithPath: greenPath)) == green)
                let readback = try await client.callTool(name: "get_timeline")
                let text = try #require(readback.content.first)
                guard case .text(let json, _, _) = text else { throw CocoaError(.coderReadCorrupt) }
                let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
                let tracks = try #require(object["tracks"] as? [[String: Any]])
                let clips = try #require(tracks.first?["clips"] as? [[String: Any]])
                let color = try #require(clips.first?["color"] as? [String: Any])
                let lut = try #require(color["lut"] as? [String: Any])
                #expect(lut["path"] as? String == greenPath)
                try await savePackageTestDocument(document)
                let saved = try await fixture.readPackage()
                let effect = saved.projectFile.timelines.first?.tracks.first?.clips.first?.effects?.first { $0.type == "color.lut" }
                #expect(effect?.params["path"]?.string == greenPath)
                try await fixture.io.remove([sources.0, sources.1])
                let pixels = try await fixture.io.perform {
                    let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
                    let image = CIImage(color: .init(red: 0.2, green: 0.3, blue: 0.4)).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
                    func sample(_ path: String) throws -> [Float] {
                        let cube = try #require(LUTLoader.load(path: path))
                        let output = LUTTetraKernel.apply(image, cube: cube, key: path, intensity: 1)
                        var pixel = [Float](repeating: 0, count: 4)
                        context.render(output, toBitmap: &pixel, rowBytes: 16, bounds: image.extent, format: .RGBAf, colorSpace: nil)
                        return pixel
                    }
                    return (try sample(redPath), try sample(greenPath), try sample(redPath))
                }
                #expect(abs(pixels.0[0] - 1) < 0.001 && pixels.0[1] < 0.001)
                #expect(abs(pixels.1[1] - 1) < 0.001 && pixels.1[0] < 0.001)
                #expect(pixels.0 == pixels.2)
                #expect(try await client.callTool(name: "undo").isError != true)
                #expect(editor.timeline == redGrade)
                #expect(try await client.callTool(name: "undo").isError != true)
                #expect(editor.timeline == before && !undo.canUndo)
                undo.redo()
                #expect(editor.timeline == redGrade)
                #expect(try await fixture.contents(of: URL(fileURLWithPath: redPath)) == red)
            }
        }
    }

    @Test func staleAndFailedPreparationLeaveStateAndUndoUnchanged() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [Fixtures.clip(id: "graded", start: 0, duration: 90)])]))
        let undo = UndoManager()
        h.editor.undo.attach(undo)
        let entered = PackageTestSignal(), release = PackageTestSignal()
        h.executor.lutStoring = { _, _ in
            await entered.signal()
            await release.wait()
            return "/tmp/prepared-lut.cube"
        }
        try await withClient(h.executor) { (client: Client) async throws in
            let pending = Task { try await client.callTool(name: "apply_color", arguments: arguments("/tmp/input.cube")) }
            await entered.wait()
            h.editor.timeline.tracks[0].clips[0].durationFrames = 60
            let current = h.editor.timeline
            release.signal()
            #expect(try await pending.value.isError == true)
            #expect(h.editor.timeline == current && !undo.canUndo)
            h.executor.lutStoring = { _, _ in throw CocoaError(.fileReadNoSuchFile) }
            #expect(try await client.callTool(name: "apply_color", arguments: arguments("/tmp/missing.cube")).isError == true)
            #expect(h.editor.timeline == current && !undo.canUndo)
        }
    }

    @Test func cancelledLUTPreparationCannotPublish() async {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [Fixtures.clip(id: "graded", start: 0, duration: 90)])]))
        let undo = UndoManager()
        h.editor.undo.attach(undo)
        let entered = PackageTestSignal(), release = PackageTestSignal()
        h.executor.lutStoring = { _, _ in
            await entered.signal()
            await release.wait()
            return "/tmp/prepared-lut.cube"
        }
        let before = h.editor.timeline
        let pending = Task { await h.runRaw("apply_color", args: ["clipIds": ["graded"], "lut": ["path": "/tmp/input.cube"]]) }
        await entered.wait()
        pending.cancel()
        release.signal()
        #expect(await pending.value.isError)
        #expect(h.editor.timeline == before && !undo.canUndo)
    }
}
