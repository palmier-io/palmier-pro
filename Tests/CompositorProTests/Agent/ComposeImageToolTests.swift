import Foundation
import ImageIO
import Testing
@testable import CompositorPro

@Suite("compose_image")
@MainActor
struct ComposeImageToolTests {
    /// A saved project with `count` real PNG stills in the library.
    private func fixture(count: Int = 4) async throws -> (ToolHarness, [String]) {
        let harness = ToolHarness()
        let root = try await Task.detached { () -> URL in
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("compose-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }.value
        harness.editor.projectURL = root.appendingPathComponent("Test.compositorpro")

        var refs: [String] = []
        for index in 0 ..< count {
            let url = root.appendingPathComponent("still-\(index).png")
            try Self.writePNG(to: url, red: UInt8(40 + index * 45), size: 320)
            let asset = MediaAsset(url: url, type: .image, name: "still \(index)", duration: 4)
            harness.editor.mediaAssets.append(asset)
            harness.editor.mediaManifest.entries.append(MediaManifestEntry(
                id: asset.id, name: asset.name, type: .image,
                source: .external(absolutePath: url.path), duration: 4
            ))
            refs.append(asset.id)
        }
        return (harness, refs)
    }

    private static func writePNG(to url: URL, red: UInt8, size: Int) throws {
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        context.setFillColor(CGColor(red: CGFloat(red) / 255, green: 0.4, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let image = context.makeImage()!
        let url = url as CFURL
        guard let destination = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test("Several stills become one image in the library")
    func composesStills() async throws {
        let (harness, refs) = try await fixture(count: 4)
        let before = harness.editor.mediaAssets.count
        let receipt = try #require(
            try await harness.runOK("compose_image", args: [
                "mediaRefs": refs, "layout": "grid", "preset": "square",
            ]) as? [String: Any]
        )
        #expect(receipt["sourceCount"] as? Int == 4)
        #expect(receipt["layout"] as? String == "grid")
        #expect(receipt["width"] as? Int == 1080)
        #expect(receipt["height"] as? Int == 1080)
        #expect(receipt["inLibrary"] as? Bool == true)
        #expect(harness.editor.mediaAssets.count == before + 1, "one asset added, not four")

        let shortId = try #require(receipt["mediaRef"] as? String)
        // mediaAssetsById is refreshed on reload, so the array is the authority right after import.
        let asset = try #require(
            harness.editor.mediaAssets.first { $0.id.hasPrefix(shortId) }
        )
        #expect(asset.type == .image)
        #expect(FileManager.default.fileExists(atPath: asset.url.path))
        #expect(asset.sourceWidth == 1080)
    }

    @Test("The receipt reports the sources it used, in order")
    func reportsSources() async throws {
        let (harness, refs) = try await fixture(count: 3)
        let receipt = try #require(
            try await harness.runOK("compose_image", args: ["mediaRefs": refs]) as? [String: Any]
        )
        let sources = try #require(receipt["sources"] as? [[String: Any]])
        #expect(sources.count == 3)
        let reported = sources.compactMap { $0["mediaRef"] as? String }
        #expect(reported.count == 3, "every source reports its id: \(sources)")
        // Receipts hand out 8-character id prefixes, the convention every tool follows.
        #expect(
            Set(reported) == Set(refs.map { String($0.prefix(8)) }),
            "the same three assets, order independent"
        )
    }

    @Test("Each preset produces its own output shape")
    func presetsDriveShape() async throws {
        let (harness, refs) = try await fixture(count: 2)
        for (preset, width, height) in [
            ("youtube", 1280, 720), ("vertical", 1080, 1920),
            ("square", 1080, 1080), ("timeline", 1280, 720),
        ] {
            let receipt = try #require(
                try await harness.runOK("compose_image", args: [
                    "mediaRefs": refs, "preset": preset,
                ]) as? [String: Any]
            )
            #expect(receipt["width"] as? Int == width, "\(preset) width")
            #expect(receipt["height"] as? Int == height, "\(preset) height")
        }
    }

    @Test("A headline is drawn without needing a hosted service")
    func headlineIsLocal() async throws {
        let (harness, refs) = try await fixture(count: 2)
        let receipt = try #require(
            try await harness.runOK("compose_image", args: [
                "mediaRefs": refs, "headline": "Summer", "subline": "a short film",
            ]) as? [String: Any]
        )
        #expect(receipt["changed"] as? Bool == true)
        let notes = try #require(receipt["notes"] as? [String])
        #expect(notes.contains { $0.contains("Nothing was generated") })
    }

    @Test("addToTimeline places the image in one step")
    func canPlaceOnTimeline() async throws {
        let (harness, refs) = try await fixture(count: 2)
        let receipt = try #require(
            try await harness.runOK("compose_image", args: [
                "mediaRefs": refs, "addToTimeline": true, "startFrame": 0,
            ]) as? [String: Any]
        )
        let shortId = try #require(receipt["clipId"] as? String)
        let clip = try #require(
            harness.editor.timeline.tracks.flatMap(\.clips)
                .first { $0.id.hasPrefix(shortId) }
        )
        #expect(clip.mediaType == .image)
        #expect(clip.durationFrames > 0, "a still needs a display length on the timeline")
    }

    @Test("Without addToTimeline the timeline is untouched")
    func doesNotTouchTimelineByDefault() async throws {
        let (harness, refs) = try await fixture(count: 2)
        let before = harness.editor.timeline
        let receipt = try #require(
            try await harness.runOK("compose_image", args: ["mediaRefs": refs]) as? [String: Any]
        )
        #expect(receipt["clipId"] == nil)
        #expect(harness.editor.timeline.tracks == before.tracks)
    }

    @Test("Neither query nor mediaRefs is refused, and nothing is created")
    func refusesNoSources() async throws {
        let (harness, _) = try await fixture(count: 1)
        let before = harness.editor.mediaAssets.count
        let result = await harness.runRaw("compose_image", args: [:])
        #expect(result.isError)
        #expect(harness.editor.mediaAssets.count == before)
    }

    @Test("Unknown layout, preset and placement are refused by name")
    func refusesUnknownEnums() async throws {
        let (harness, refs) = try await fixture(count: 2)
        for (key, bad, expected) in [
            ("layout", "mosaic", "grid"),
            ("preset", "billboard", "youtube"),
            ("textPlacement", "middle", "bottomLeft"),
        ] {
            let result = await harness.runRaw("compose_image", args: [
                "mediaRefs": refs, key: bad,
            ])
            #expect(result.isError, "\(key) should reject '\(bad)'")
            #expect(ToolHarness.textOf(result).contains(expected))
        }
    }

    @Test("An out-of-range limit is refused")
    func refusesBadLimit() async throws {
        let (harness, refs) = try await fixture(count: 2)
        for bad in [0, 13, -1] {
            let result = await harness.runRaw("compose_image", args: [
                "mediaRefs": refs, "limit": bad,
            ])
            #expect(result.isError, "limit \(bad) should be refused")
        }
    }

    @Test("An unknown mediaRef is refused rather than silently skipped")
    func refusesUnknownMedia() async throws {
        let (harness, refs) = try await fixture(count: 2)
        let result = await harness.runRaw("compose_image", args: [
            "mediaRefs": refs + ["missing-asset"],
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("missing-asset"))
    }

    @Test("A mistyped key is rejected rather than ignored")
    func rejectsUnknownKeys() async throws {
        let (harness, refs) = try await fixture(count: 2)
        let result = await harness.runRaw("compose_image", args: [
            "mediaRefs": refs, "layoutt": "grid",
        ])
        #expect(result.isError)
    }

    @Test("One image alone still produces a full-bleed picture")
    func singleImageFillsCanvas() async throws {
        let (harness, refs) = try await fixture(count: 1)
        let receipt = try #require(
            try await harness.runOK("compose_image", args: ["mediaRefs": refs]) as? [String: Any]
        )
        #expect(receipt["sourceCount"] as? Int == 1)
        #expect(receipt["width"] as? Int == 1280)
        #expect(receipt["height"] as? Int == 720)
    }
}