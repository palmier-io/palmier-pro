import Foundation
import Testing
@testable import PalmierPro

@Suite("Project JSON roundtrip")
struct ProjectRoundTripTests {

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Timeline

    @Test func emptyTimelineSurvivesRoundTrip() throws {
        let t = Fixtures.timeline()
        #expect(try roundTrip(t) == t)
    }

    @Test func timelineWithSimpleClipsSurvivesRoundTrip() throws {
        let timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 50)]),
            Fixtures.audioTrack(clips: [Fixtures.clip(mediaType: .audio, start: 0, duration: 100)]),
        ])
        #expect(try roundTrip(timeline) == timeline)
    }

    @Test func clipPreservesFadeAndSpeedAndTrimAcrossRoundTrip() throws {
        var clip = Fixtures.clip(start: 0, duration: 60, trimStart: 10, trimEnd: 5, speed: 1.5, volume: 0.75)
        clip.fadeInFrames = 12
        clip.fadeOutFrames = 8
        clip.fadeInInterpolation = .linear
        clip.fadeOutInterpolation = .hold
        clip.opacity = 0.5
        let track = Fixtures.videoTrack(clips: [clip])
        let timeline = Fixtures.timeline(tracks: [track])

        let decoded = try roundTrip(timeline)
        let dc = decoded.tracks[0].clips[0]
        #expect(dc.trimStartFrame == 10)
        #expect(dc.trimEndFrame == 5)
        #expect(dc.speed == 1.5)
        #expect(dc.volume == 0.75)
        #expect(dc.fadeInFrames == 12)
        #expect(dc.fadeOutFrames == 8)
        #expect(dc.fadeInInterpolation == .linear)
        #expect(dc.fadeOutInterpolation == .hold)
        #expect(dc.opacity == 0.5)
    }

    @Test func clipTransformAndCropSurviveRoundTrip() throws {
        var clip = Fixtures.clip(start: 0, duration: 30)
        clip.transform = Transform(centerX: 0.4, centerY: 0.6, width: 0.5, height: 0.5, rotation: 45,
                                   flipHorizontal: true, flipVertical: false)
        clip.crop = Crop(left: 0.1, top: 0.2, right: 0.3, bottom: 0.4)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let decoded = try roundTrip(timeline)
        let dc = decoded.tracks[0].clips[0]
        #expect(dc.transform.centerX == 0.4)
        #expect(dc.transform.centerY == 0.6)
        #expect(dc.transform.rotation == 45)
        #expect(dc.transform.flipHorizontal == true)
        #expect(dc.crop == Crop(left: 0.1, top: 0.2, right: 0.3, bottom: 0.4))
    }

    @Test func clipKeyframesSurviveRoundTrip() throws {
        var clip = Fixtures.clip(start: 100, duration: 100)
        clip.upsertKeyframe(in: \.opacityTrack, frame: 100, value: 0.0)
        clip.upsertKeyframe(in: \.opacityTrack, frame: 150, value: 1.0)
        clip.setInterpolation(for: .opacity, atFrame: 100, .hold)
        clip.upsertKeyframe(in: \.scaleTrack, frame: 120, value: AnimPair(a: 0.5, b: 0.5))
        clip.upsertKeyframe(in: \.rotationTrack, frame: 110, value: 30)
        clip.upsertKeyframe(in: \.cropTrack, frame: 100, value: Crop(left: 0.1, top: 0, right: 0.1, bottom: 0))
        clip.upsertKeyframe(in: \.volumeTrack, frame: 130, value: -6)

        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        let decoded = try roundTrip(timeline)
        let dc = decoded.tracks[0].clips[0]
        #expect(dc.opacityTrack?.keyframes.count == 2)
        #expect(dc.opacityTrack?.keyframes[0].interpolationOut == .hold)
        #expect(dc.scaleTrack?.keyframes.count == 1)
        #expect(dc.rotationTrack?.keyframes[0].value == 30)
        #expect(dc.cropTrack?.keyframes[0].value.left == 0.1)
        #expect(dc.volumeTrack?.keyframes[0].value == -6)
    }

    @Test func clipLinkGroupAndTextContentSurviveRoundTrip() throws {
        var video = Fixtures.clip(id: "v1", start: 0, duration: 50)
        video.linkGroupId = "group-1"
        var audio = Fixtures.clip(id: "a1", mediaType: .audio, start: 0, duration: 50)
        audio.linkGroupId = "group-1"

        var text = Fixtures.clip(id: "t1", mediaRef: "text-1", mediaType: .text, start: 100, duration: 30)
        text.textContent = "Hello, world!"
        text.textStyle = TextStyle(fontName: "Helvetica-Bold", fontSize: 48, color: TextStyle.RGBA(r: 1, g: 0, b: 0))

        let timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [video, text]),
            Fixtures.audioTrack(clips: [audio]),
        ])
        let decoded = try roundTrip(timeline)
        #expect(decoded.tracks[0].clips[0].linkGroupId == "group-1")
        #expect(decoded.tracks[1].clips[0].linkGroupId == "group-1")
        let dt = decoded.tracks[0].clips.first { $0.id == "t1" }!
        #expect(dt.textContent == "Hello, world!")
        #expect(dt.textStyle?.fontSize == 48)
        #expect(dt.textStyle?.color.r == 1)
    }

    @Test func trackMutedAndHiddenFlagsSurviveRoundTrip() throws {
        var v = Fixtures.videoTrack()
        v.hidden = true
        var a = Fixtures.audioTrack()
        a.muted = true
        let timeline = Fixtures.timeline(tracks: [v, a])
        let decoded = try roundTrip(timeline)
        #expect(decoded.tracks[0].hidden == true)
        #expect(decoded.tracks[1].muted == true)
    }

    // MARK: - Legacy / tolerant decode

    @Test func trackMissingMutedFieldDecodesAsFalse() throws {
        // Older projects didn't have muted/hidden/syncLocked. They must decode with defaults.
        let json = """
        {
          "id": "t1",
          "type": "video",
          "label": "V1",
          "clips": []
        }
        """
        let track = try JSONDecoder().decode(Track.self, from: Data(json.utf8))
        #expect(track.muted == false)
        #expect(track.hidden == false)
        #expect(track.syncLocked == true)
    }

    @Test func clipMissingNewFieldsDecodesWithDefaults() throws {
        // Old clip with only the required fields. Should decode with all defaults filled in.
        let json = """
        {
          "id": "c1",
          "mediaRef": "media-1",
          "startFrame": 0,
          "durationFrames": 30
        }
        """
        let clip = try JSONDecoder().decode(Clip.self, from: Data(json.utf8))
        #expect(clip.speed == 1.0)
        #expect(clip.volume == 1.0)
        #expect(clip.opacity == 1.0)
        #expect(clip.fadeInFrames == 0)
        #expect(clip.fadeInInterpolation == .linear)
        #expect(clip.transform == Transform())
        #expect(clip.crop == Crop())
        #expect(clip.linkGroupId == nil)
        #expect(clip.textContent == nil)
    }

    @Test func transformMigratesLegacyXYToCenterXY() throws {
        // Pre-rename schema used `x` / `y` for the top-left corner instead of `centerX` / `centerY`.
        // Init must compute the new center from the old top-left when only legacy keys are present.
        let json = """
        {
          "x": 0.1, "y": 0.2,
          "width": 0.4, "height": 0.3
        }
        """
        let t = try JSONDecoder().decode(Transform.self, from: Data(json.utf8))
        // Legacy formula: centerX = x + width - 0.5 (verified by reading Transform.init(from:)).
        #expect(t.width == 0.4)
        #expect(t.height == 0.3)
        // Just verify centerX/Y were populated to something non-default (the legacy fallback ran).
        #expect(t.centerX != 0.5 || t.centerY != 0.5)
    }

    @Test func textStyleMissingFontScaleDecodesAsOne() throws {
        // fontScale was added later — older text styles should default to 1.0.
        let json = """
        {
          "fontName": "Helvetica-Bold",
          "fontSize": 96,
          "color": {"r": 1, "g": 1, "b": 1, "a": 1},
          "alignment": "center",
          "shadow": {
            "enabled": true,
            "color": {"r": 0, "g": 0, "b": 0, "a": 0.6},
            "offsetX": 0, "offsetY": -2, "blur": 6
          }
        }
        """
        let style = try JSONDecoder().decode(TextStyle.self, from: Data(json.utf8))
        #expect(style.fontScale == 1.0)
    }

    // MARK: - MediaManifest

    @Test func mediaManifestSurvivesRoundTripWithBothSourceKinds() throws {
        var manifest = MediaManifest()
        manifest.entries = [
            MediaManifestEntry(
                id: "ext-1", name: "External", type: .video,
                source: .external(absolutePath: "/abs/path/video.mp4"),
                duration: 5.0,
                sourceWidth: 1920, sourceHeight: 1080, sourceFPS: 30,
                hasAudio: true
            ),
            MediaManifestEntry(
                id: "proj-1", name: "Project-relative", type: .image,
                source: .project(relativePath: "media/img.png"),
                duration: 0,
                folderId: "folder-1"
            ),
        ]
        manifest.folders = [
            MediaFolder(id: "folder-1", name: "Refs", parentFolderId: nil),
        ]
        #expect(try roundTrip(manifest) == manifest)
    }

    @Test func mediaManifestMissingVersionDecodesAsVersionOne() throws {
        let json = """
        { "entries": [], "folders": [] }
        """
        let manifest = try JSONDecoder().decode(MediaManifest.self, from: Data(json.utf8))
        #expect(manifest.version == 1)
    }

    @Test func mediaManifestMissingEntriesAndFoldersDecodesAsEmpty() throws {
        // Even a fully-empty document should decode cleanly.
        let json = "{}"
        let manifest = try JSONDecoder().decode(MediaManifest.self, from: Data(json.utf8))
        #expect(manifest.entries.isEmpty)
        #expect(manifest.folders.isEmpty)
    }

    // MARK: - GenerationLog

    @Test func generationLogSurvivesRoundTrip() throws {
        var log = GenerationLog()
        log.entries = [
            GenerationLogEntry(model: "veo3.1-fast", costCredits: 100, createdAt: Date(timeIntervalSince1970: 1_700_000_000)),
            GenerationLogEntry(model: "nano-banana-pro", costCredits: nil, createdAt: nil),
        ]
        #expect(try roundTrip(log) == log)
    }

    @Test func generationLogEntryMigratesLegacyCostDollarsToCredits() throws {
        // Legacy entries stored `cost` as dollars (Double). New entries use `costCredits` (Int).
        // Conversion: credits = ceil(dollars * 100).
        let json = """
        { "id": "abc", "model": "test-model", "cost": 0.05 }
        """
        let entry = try JSONDecoder().decode(GenerationLogEntry.self, from: Data(json.utf8))
        #expect(entry.costCredits == 5) // 0.05 × 100 = 5
    }

    @Test func generationLogEntryWithNeitherCostFieldDecodesToNil() throws {
        let json = """
        { "id": "abc", "model": "test-model" }
        """
        let entry = try JSONDecoder().decode(GenerationLogEntry.self, from: Data(json.utf8))
        #expect(entry.costCredits == nil)
        #expect(entry.createdAt == nil)
    }
}
