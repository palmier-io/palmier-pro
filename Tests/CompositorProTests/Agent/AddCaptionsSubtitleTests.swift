import Foundation
import Testing
@testable import CompositorPro

@Suite("add_captions subtitleMediaRef")
@MainActor
struct AddCaptionsSubtitleTests {
    private func registerSubtitleAsset(
        _ editor: EditorViewModel, fixture: PackageTestFixture, id: String, contents: String
    ) async throws {
        let url = fixture.root.appendingPathComponent("captions.srt")
        try await fixture.io.perform { try contents.write(to: url, atomically: true, encoding: .utf8) }
        let asset = MediaAsset(id: id, url: url, type: .subtitle, name: "captions", duration: 4)
        editor.importMediaAsset(asset)
    }

    @Test func placesSubtitleCuesAsCaptionsAtTheirTimecodesResolvingShortIds() async throws {
        try await withSavedMediaPackageTestFixture { fixture, document in
            let editor = document.editorViewModel
            editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack()])
            try await registerSubtitleAsset(
                editor, fixture: fixture, id: "AB107A6F-155C-417C-8776-41BFA1C3DF07",
                contents: "1\n00:00:01,000 --> 00:00:02,000\nHello.\n\n2\n00:00:03,000 --> 00:00:04,000\nWorld.\n"
            )

            let result = await ToolExecutor(editor: editor).execute(name: "add_captions", args: ["subtitleMediaRef": "AB107A6F"])
            #expect(!result.isError, "\(ToolHarness.textOf(result))")

            let captions = editor.timeline.tracks[0].clips
            #expect(captions.map(\.textContent) == ["Hello.", "World."])
            #expect(captions.map(\.startFrame) == [30, 90])
            #expect(captions.allSatisfy { $0.captionGroupId != nil })
        }
    }

    @Test func rejectsCombinedOptionsWrongTypesAndMalformedFiles() async throws {
        try await withSavedMediaPackageTestFixture { fixture, document in
            let editor = document.editorViewModel
            editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack()])
            editor.importMediaAsset(MediaAsset(id: "vid", url: fixture.root.appendingPathComponent("video.mov"), type: .video, name: "Video"))
            try await registerSubtitleAsset(editor, fixture: fixture, id: "bad", contents: "garbage --> nonsense\nBroken.\n")
            let executor = ToolExecutor(editor: editor)

            let combined = await executor.execute(name: "add_captions", args: ["subtitleMediaRef": "bad", "maxWords": 3])
            #expect(ToolHarness.textOf(combined).contains("maxWords"))

            let nonString = await executor.execute(name: "add_captions", args: ["subtitleMediaRef": 123])
            #expect(ToolHarness.textOf(nonString).contains("subtitleMediaRef"))

            let wrongType = await executor.execute(name: "add_captions", args: ["subtitleMediaRef": "vid"])
            #expect(ToolHarness.textOf(wrongType).contains("not a subtitle file"))

            let malformed = await executor.execute(name: "add_captions", args: ["subtitleMediaRef": "bad"])
            #expect(ToolHarness.textOf(malformed).contains("Malformed cue timing at line 1"))

            #expect(editor.timeline.tracks.flatMap(\.clips).allSatisfy { $0.mediaType != .text })
        }
    }

    @Test func importsSubtitleBytesViaMimeType() async throws {
        try await withSavedMediaPackageTestFixture { fixture, document in
            let editor = document.editorViewModel
            let srt = "1\n00:00:01,000 --> 00:00:02,000\nFrom bytes.\n"
            let result = await ToolExecutor(editor: editor).execute(name: "import_media", args: [
                "source": ["bytes": Data(srt.utf8).base64EncodedString(), "mimeType": "application/x-subrip"],
            ])
            try #require(!result.isError, "\(ToolHarness.textOf(result))")
            let receipt = try #require(JSONSerialization.jsonObject(with: Data(ToolHarness.textOf(result).utf8)) as? [String: Any])
            #expect(receipt["type"] as? String == "subtitle")
            let mediaRef = try #require(receipt["mediaRef"] as? String)
            let asset = try #require(editor.mediaAssets.first { $0.id.hasPrefix(mediaRef) })
            #expect(asset.type == .subtitle)
            #expect(try await fixture.contents(of: asset.url) == Data(srt.utf8))
            try await savePackageTestDocument(document)
            #expect(try await fixture.readPackage().manifest?.entries.first?.id == asset.id)
        }
    }
}
