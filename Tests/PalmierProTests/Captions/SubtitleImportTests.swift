import Foundation
import Testing
@testable import PalmierPro

@MainActor
@Suite struct SubtitleImportTests {
    private let e = EditorViewModel()
    private let undoManager = UndoManager()

    init() {
        e.undo.attach(undoManager)
        e.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 300)]),
        ])
    }

    private static let srt = "1\n00:00:01,000 --> 00:00:02,000\nHello.\n\n2\n00:00:03,000 --> 00:00:04,000\nWorld.\n"

    private func withSubtitleFile<T>(
        _ contents: String, _ body: (URL) async throws -> T
    ) async throws -> T {
        let dir = try await Task.detached {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("SubtitleImportTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try contents.write(to: dir.appendingPathComponent("captions.srt"), atomically: true, encoding: .utf8)
            return dir
        }.value
        defer { Task.detached { try? FileManager.default.removeItem(at: dir) } }
        return try await body(dir.appendingPathComponent("captions.srt"))
    }

    @Test func importCreatesSubtitleAssetWithDurationFromLastCue() async throws {
        try await withSubtitleFile(Self.srt) { url in
            let summary = try await e.importFinderItems([url], into: nil, finalize: false)
            let asset = try #require(summary.assets.first)
            #expect(asset.type == .subtitle)
            #expect(await e.finalizeImportedAsset(asset))
            #expect(asset.duration == 4.0)
        }
    }

    @Test func malformedSubtitleAssetFailsFinalizeAndPlacesNoCaptions() async throws {
        try await withSubtitleFile("garbage --> nonsense\nBroken.\n") { url in
            await e.importFinderItemsToTimeline([url], cursor: .existingTrack(0), atFrame: 0, ripple: false)
        }
        #expect(e.mediaAssets.count == 1)
        #expect(e.timeline.tracks.flatMap(\.clips).allSatisfy { $0.mediaType != .text })
    }

    @Test func timelineDropSyncsCaptionsToFileTimecodesAsOneUndoStep() async throws {
        try await withSubtitleFile(Self.srt) { url in
            await e.importFinderItemsToTimeline([url], cursor: .existingTrack(0), atFrame: 42, ripple: false)
        }
        let asset = try #require(e.mediaAssets.first)
        #expect(asset.type == .subtitle)

        let captions = e.timeline.tracks[0].clips
        #expect(captions.map(\.textContent) == ["Hello.", "World."])
        #expect(captions.map(\.startFrame) == [30, 90])
        #expect(captions.allSatisfy { $0.mediaType == .text && $0.captionGroupId != nil })

        // One drop is one undo step: captions and the imported asset revert together.
        #expect(e.undo.undoLatest() == "Add Media")
        #expect(e.timeline.tracks.flatMap(\.clips).allSatisfy { $0.mediaType != .text })
        #expect(e.mediaAssets.isEmpty)
        #expect(!undoManager.canUndo)
    }

    @Test func placeCaptionsReportsOfflineAssetWithoutMutating() async throws {
        let asset = MediaAsset(
            id: "missing", url: URL(fileURLWithPath: "/nonexistent/captions.srt"),
            type: .subtitle, name: "captions", duration: 4
        )
        let before = e.timeline
        await e.placeCaptions(fromSubtitleAssets: [asset])
        #expect(e.mediaPanelToast?.kind == .warning)
        #expect(e.timeline == before)
        #expect(!undoManager.canUndo)
    }

    @Test func subtitleAssetsNeverEnterTheClipDropPlan() {
        let asset = MediaAsset(
            id: "subs", url: URL(fileURLWithPath: "/tmp/captions.srt"),
            type: .subtitle, name: "captions", duration: 4
        )
        let plan = e.resolveDropPlan(cursor: .existingTrack(0), assets: [asset], atFrame: 0)
        #expect(plan.placements.isEmpty)
    }
}
