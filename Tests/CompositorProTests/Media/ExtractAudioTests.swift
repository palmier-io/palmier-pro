import AVFoundation
import Foundation
import Testing
@testable import CompositorPro

@Suite("Extract Audio")
@MainActor
struct ExtractAudioTests {
    @Test func skipsAssetsWithoutExtractableAudio() async {
        let e = EditorViewModel()
        let silentVideo = MediaAsset(url: URL(fileURLWithPath: "/tmp/silent.mp4"), type: .video, name: "Silent")
        silentVideo.hasAudio = false
        let audio = MediaAsset(url: URL(fileURLWithPath: "/tmp/take.m4a"), type: .audio, name: "Take")
        audio.hasAudio = true
        let image = MediaAsset(url: URL(fileURLWithPath: "/tmp/still.png"), type: .image, name: "Still")
        let generating = MediaAsset(url: URL(fileURLWithPath: "/tmp/gen.mp4"), type: .video, name: "Gen")
        generating.hasAudio = true
        generating.generationStatus = .generating
        for asset in [silentVideo, audio, image, generating] {
            e.importMediaAsset(asset)
        }

        await e.extractAudio(from: [silentVideo.id, audio.id, image.id, generating.id])

        #expect(e.mediaAssets.count == 4)
        #expect(e.mediaAssets.allSatisfy { $0.type != .audio || $0.id == audio.id })
    }

    @Test func extractsStandaloneAudioAssetIntoSameFolder() async throws {
        try await withSavedMediaPackageTestFixture { fixture, document in
            let sourceURL = try await Self.writeSilentAudio(in: fixture.root)
            let e = document.editorViewModel
            let folderId = e.createFolder(name: "B-roll")
            let source = MediaAsset(url: sourceURL, type: .video, name: "Interview")
            source.hasAudio = true
            source.folderId = folderId
            e.importMediaAsset(source)

            await e.extractAudio(from: [source.id])

            let extracted = try #require(e.mediaAssets.first { $0.id != source.id })
            #expect(extracted.type == .audio)
            #expect(extracted.name == "Interview (audio)")
            #expect(extracted.folderId == folderId)
            #expect(extracted.generationStatus == .none)
            #expect(extracted.duration > 0)
            #expect(try await fixture.exists(extracted.url))
            #expect(extracted.url.pathExtension == "m4a")
            #expect(extracted.url.deletingLastPathComponent().path == fixture.package.appendingPathComponent("media").path)
        }
    }

    @Test func extractsTrimmedAudioFromLinkedClipWithoutUnlinking() async throws {
        try await withSavedMediaPackageTestFixture { fixture, document in
            let sourceURL = try await Self.writeSilentAudio(in: fixture.root)
            let e = document.editorViewModel
            e.timeline.fps = 30
            _ = e.insertTrack(at: 0, type: .video)
            let source = MediaAsset(url: sourceURL, type: .video, name: "Interview", duration: 0.1)
            source.hasAudio = true
            e.importMediaAsset(source)
            let ids = e.placeClip(asset: source, trackIndex: 0, startFrame: 0, durationFrames: 2)
            let videoId = try #require(ids.first)
            let audioId = try #require(ids.dropFirst().first)

            #expect(e.canExtractAudio(fromClipId: videoId))
            #expect(e.canExtractAudio(fromClipId: audioId))
            await e.extractAudio(fromClipId: videoId)

            let extracted = try #require(e.mediaAssets.first { $0.type == .audio })
            #expect(extracted.name == "Interview (audio)")
            #expect(extracted.generationStatus == .none)
            #expect(try await fixture.exists(extracted.url))
            #expect(extracted.url.deletingLastPathComponent().path == fixture.package.appendingPathComponent("media").path)
            let video = try #require(e.clipFor(id: videoId))
            let audio = try #require(e.clipFor(id: audioId))
            #expect(video.linkGroupId != nil)
            #expect(video.linkGroupId == audio.linkGroupId)
        }
    }

    @Test func skipsLinkedClipWhileSourceIsGenerating() async throws {
        let e = EditorViewModel()
        _ = e.insertTrack(at: 0, type: .video)
        let source = MediaAsset(
            url: URL(fileURLWithPath: "/tmp/extract-audio-generating.mp4"),
            type: .video,
            name: "Gen",
            duration: 1
        )
        source.hasAudio = true
        source.generationStatus = .generating
        e.importMediaAsset(source)
        let ids = e.placeClip(asset: source, trackIndex: 0, startFrame: 0, durationFrames: 10)
        let videoId = try #require(ids.first)

        #expect(!e.canExtractAudio(fromClipId: videoId))
        await e.extractAudio(fromClipId: videoId)
        #expect(e.mediaAssets.allSatisfy { $0.id == source.id })
    }

    @concurrent private static func writeSilentAudio(in root: URL) async throws -> URL {
        let url = root.appendingPathComponent("extract-audio-\(UUID().uuidString).caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
        buffer.frameLength = 4_410
        try file.write(from: buffer)
        return url
    }
}

@MainActor
func withSavedMediaPackageTestFixture(
    _ operation: @MainActor (PackageTestFixture, VideoProject) async throws -> Void
) async throws {
    try await withPackageTestFixture { fixture in
        let document = fixture.document()
        do {
            try await savePackageTestDocument(document)
            try await operation(fixture, document)
        } catch {
            await document.abortOpening()
            await document.editorViewModel.missingMediaRefreshTask?.value
            throw error
        }
        await document.abortOpening()
        await document.editorViewModel.missingMediaRefreshTask?.value
    }
}
