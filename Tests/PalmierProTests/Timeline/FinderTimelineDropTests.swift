import Foundation
import Testing
@testable import PalmierPro

@MainActor
private func editor(_ tracks: [Track] = [Fixtures.videoTrack()]) -> EditorViewModel {
    let e = EditorViewModel()
    e.timeline = Fixtures.timeline(tracks: tracks)
    return e
}

@MainActor
private func tempMediaURLs(count: Int, ext: String = "mp4") throws -> [URL] {
    try (0..<count).map { index in
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("finder-timeline-\(UUID().uuidString)-\(index).\(ext)")
        try Data().write(to: url)
        return url
    }
}

@Suite("EditorViewModel — Finder → timeline drop")
@MainActor
struct FinderTimelineDropTests {

    @Test func commitExternalMediaDropPlacesClipsEndToEnd() {
        let e = editor()
        let first = MediaAsset(
            url: URL(fileURLWithPath: "/tmp/a.mp4"),
            type: .video,
            name: "a",
            duration: 2
        )
        first.hasAudio = false
        let second = MediaAsset(
            url: URL(fileURLWithPath: "/tmp/b.mp4"),
            type: .video,
            name: "b",
            duration: 3
        )
        second.hasAudio = false
        e.mediaAssets = [first, second]

        e.commitExternalMediaDrop(
            assets: [first, second],
            cursor: .existingTrack(0),
            atFrame: 10,
            ripple: false
        )

        let clips = e.timeline.tracks[0].clips.sorted { $0.startFrame < $1.startFrame }
        #expect(clips.map(\.mediaRef) == [first.id, second.id])
        #expect(clips.map(\.startFrame) == [10, 70])
        #expect(clips.map(\.durationFrames) == [60, 90])
    }

    @Test func importAndPlaceFinderItemsImportsAndPlacesSequentially() async throws {
        let e = editor()
        let urls = try tempMediaURLs(count: 3)
        defer { for url in urls { try? FileManager.default.removeItem(at: url) } }

        await e.importAndPlaceFinderItems(
            urls,
            into: nil,
            cursor: .existingTrack(0),
            atFrame: 10,
            ripple: false
        )

        #expect(e.mediaAssets.count == 3)
        let clips = e.timeline.tracks[0].clips.sorted { $0.startFrame < $1.startFrame }
        #expect(clips.count == 3)
        #expect(clips.map(\.startFrame) == [10, 11, 12])
        #expect(Set(clips.map(\.mediaRef)) == Set(e.mediaAssets.map(\.id)))
    }

    @Test func importAndPlaceFinderItemsUsesKnownDurationsWhenFinalized() async throws {
        let e = editor()
        let urls = try tempMediaURLs(count: 2)
        defer { for url in urls { try? FileManager.default.removeItem(at: url) } }

        let summary = try await e.importFinderItems(urls, into: nil, finalizeImmediately: false)
        #expect(summary.assetIds.count == 2)
        for (index, id) in summary.assetIds.enumerated() {
            let asset = try #require(e.mediaAssets.first { $0.id == id })
            asset.duration = Double(index + 1)
            asset.hasAudio = false
        }

        e.commitExternalMediaDrop(
            assets: summary.assetIds.compactMap { id in e.mediaAssets.first { $0.id == id } },
            cursor: .existingTrack(0),
            atFrame: 0,
            ripple: false
        )

        let clips = e.timeline.tracks[0].clips.sorted { $0.startFrame < $1.startFrame }
        #expect(clips.map(\.startFrame) == [0, 30])
        #expect(clips.map(\.durationFrames) == [30, 60])
    }

    @Test func importAndPlaceFinderItemsSkipsUnsupportedFiles() async {
        let e = editor()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("finder-timeline-\(UUID().uuidString).txt")
        try? Data("nope".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        await e.importAndPlaceFinderItems(
            [url],
            into: nil,
            cursor: .existingTrack(0),
            atFrame: 0,
            ripple: false
        )

        #expect(e.mediaAssets.isEmpty)
        #expect(e.timeline.tracks[0].clips.isEmpty)
    }

    @Test func importFinderItemsExposesAssetIdsInDropOrder() async throws {
        let e = editor()
        let urls = try tempMediaURLs(count: 2)
        defer { for url in urls { try? FileManager.default.removeItem(at: url) } }

        let summary = try await e.importFinderItems(urls, into: nil, finalizeImmediately: false)
        #expect(summary.assetCount == 2)
        #expect(summary.assetIds.count == 2)
        #expect(summary.assetIds == e.mediaAssets.map(\.id))
    }
}
