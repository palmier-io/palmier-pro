import AVFoundation
import Foundation
import ImageIO
import MCP
import Testing
@testable import CompositorPro

@Suite("generate_thumbnail")
@MainActor
struct GenerateThumbnailToolTests {
    private struct Fixture {
        let harness: ToolHarness
        let dir: URL
        let clip: Clip
    }

    private func fixture(seconds: Double = 4) async throws -> Fixture {
        let harness = ToolHarness()
        let url = try await FixtureVideo.write(
            scenes: (0 ..< Int(seconds * 2)).map { index in
                let value = UInt8((index * 37) % 256)
                return FixtureVideo.Scene(
                    rgb: (value, UInt8((255 - Int(value)) % 256), 120),
                    seconds: 0.5
                )
            },
            fps: 30, size: 320, fileType: .mov
        )
        let asset = harness.addAsset(type: .video, duration: seconds, hasAudio: true)
        harness.editor.mediaManifest.entries = [MediaManifestEntry(
            id: asset.id, name: asset.name, type: .video,
            source: .external(absolutePath: url.path), duration: seconds
        )]
        _ = try await harness.runOK("add_clips", args: ["entries": [
            ["mediaRef": asset.id, "startFrame": 0, "source": [0.0, seconds]],
        ]])
        let clip = try #require(harness.editor.timeline.tracks.flatMap(\.clips)
            .first { $0.mediaType == .video })
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumb-\(UUID().uuidString)", isDirectory: true)
        return Fixture(harness: harness, dir: dir, clip: clip)
    }

    private func imageSize(of url: URL) throws -> (width: Int, height: Int, type: String) {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let type = try #require(CGImageSourceGetType(source) as String?)
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)
        return (width, height, type)
    }

    @Test func writesAJpegAtTheYouTubeSizeAndLeavesTheTimelineAlone() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let before = fixture.harness.editor.timeline

        let receipt = try await fixture.harness.runOK("generate_thumbnail", args: [
            "path": fixture.dir.path, "fileName": "poster",
        ]) as? [String: Any]
        #expect(receipt?["preset"] as? String == "youtube")
        #expect(receipt?["width"] as? Int == 1280)
        #expect(receipt?["height"] as? Int == 720)

        let url = try #require((receipt?["path"] as? String).map { URL(fileURLWithPath: $0) })
        #expect(FileManager.default.fileExists(atPath: url.path))
        let info = try imageSize(of: url)
        #expect(info.width == 1280 && info.height == 720)
        #expect(info.type == "public.jpeg")

        // The point of the tool: the edit is not touched.
        #expect(fixture.harness.editor.timeline == before)
        #expect(fixture.harness.editor.mediaAssets.count == 1)
    }

    @Test(arguments: [
        ("youtube", 1280, 720),
        ("vertical", 1080, 1920),
        ("square", 1080, 1080),
    ])
    func everyPresetRendersItsExactShape(
        preset: String, width: Int, height: Int
    ) async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        _ = try await fixture.harness.runOK("generate_thumbnail", args: [
            "preset": preset, "path": fixture.dir.path,
        ])
        let url = fixture.dir.appendingPathComponent("thumbnail.jpg")
        let info = try imageSize(of: url)
        #expect(info.width == width && info.height == height)
    }

    @Test func aChosenFrameIsUsedAndReported() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let receipt = try await fixture.harness.runOK("generate_thumbnail", args: [
            "frame": 45, "path": fixture.dir.path,
        ]) as? [String: Any]
        #expect(receipt?["frame"] as? Int == 45)
        #expect(receipt?["frameWasChosen"] as? Bool == false)
        #expect(receipt?["framesConsidered"] as? Int == 1)
    }

    @Test func anAutomaticFrameIsChosenAndReportedHonestly() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let receipt = try await fixture.harness.runOK("generate_thumbnail", args: [
            "path": fixture.dir.path,
        ]) as? [String: Any]
        #expect(receipt?["frameWasChosen"] as? Bool == true)
        let considered = try #require(receipt?["framesConsidered"] as? Int)
        #expect(considered > 1)
        let frame = try #require(receipt?["frame"] as? Int)
        #expect(frame >= 0 && frame < fixture.harness.editor.timeline.totalFrames)
        // The receipt must not claim it knows the best shot.
        let notes = try #require(receipt?["notes"] as? [String])
        #expect(notes.contains { $0.contains("not a judgement") })
    }

    @Test func aHeadlineIsDrawnOntoTheImageNotTheVideo() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let before = fixture.harness.editor.timeline
        let receipt = try await fixture.harness.runOK("generate_thumbnail", args: [
            "title": "THREE DAYS IN LISBON", "subtitle": "a food trip",
            "path": fixture.dir.path,
        ]) as? [String: Any]
        #expect(receipt?["hasTitle"] as? Bool == true)
        #expect(fixture.harness.editor.timeline == before)
        // No text clip was created for the thumbnail.
        #expect(!fixture.harness.editor.timeline.tracks.flatMap(\.clips).contains { $0.mediaType == .text })
    }

    @Test func aFrameOutsideTheTimelineIsRefused() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let result = await fixture.harness.runRaw("generate_thumbnail", args: [
            "frame": 99_999, "path": fixture.dir.path,
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("outside the timeline"))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.dir.appendingPathComponent("thumbnail.jpg").path
        ))
    }

    @Test func validationRefusesBadRequests() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let cases: [([String: Any], String, Comment)] = [
            (["preset": "billboard"], "Unknown thumbnail preset", "unknown preset"),
            (["placement": "topRight"], "placement must be", "bad placement"),
            (["titleScale": 5.0], "titleScale must be", "titleScale out of band"),
            (["path": "relative/dir"], "path must be absolute", "relative path"),
        ]
        for (args, expected, comment) in cases {
            let result = await fixture.harness.runRaw("generate_thumbnail", args: args)
            let message = ToolHarness.textOf(result)
            #expect(result.isError, comment)
            #expect(message.contains(expected), comment)
        }
    }

    @Test func endToEndOverMCP() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let server = Server(name: "thumb-test", version: "1.0.0", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: fixture.harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "thumb-test", version: "1.0.0")
        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            #expect(tools.contains { $0.name == "generate_thumbnail" })
            let result = try await client.callTool(name: "generate_thumbnail", arguments: [
                "preset": .string("vertical"),
                "title": .string("NINE DAYS OFF"),
                "path": .string(fixture.dir.path),
            ])
            #expect(result.isError != true)
            let url = fixture.dir.appendingPathComponent("thumbnail.jpg")
            #expect(FileManager.default.fileExists(atPath: url.path))
            let info = try imageSize(of: url)
            #expect(info.width == 1080 && info.height == 1920)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }
}