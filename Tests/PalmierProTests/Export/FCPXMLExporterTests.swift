import Foundation
import Testing
@testable import PalmierPro

@Suite("FCPXMLExporter")
struct FCPXMLExporterTests {

    // MARK: - Helpers

    private func makeResolver(entries: [MediaManifestEntry]) throws -> (MediaResolver, URL) {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FCPXMLExporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        for entry in entries {
            if case let .external(absolutePath) = entry.source {
                FileManager.default.createFile(atPath: absolutePath, contents: Data())
            }
        }
        var manifest = MediaManifest()
        manifest.entries = entries
        return (MediaResolver(manifest: { manifest }, projectURL: { nil }), tmpDir)
    }

    private func readXML(at url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    private func videoEntry(
        id: String,
        in dir: String,
        duration: Double = 5,
        sourceWidth: Int = 1920,
        sourceHeight: Int = 1080
    ) -> MediaManifestEntry {
        MediaManifestEntry(
            id: id, name: id, type: .video,
            source: .external(absolutePath: (dir as NSString).appendingPathComponent("\(id).mp4")),
            duration: duration,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        )
    }

    private func audioEntry(id: String, in dir: String, duration: Double = 5) -> MediaManifestEntry {
        MediaManifestEntry(
            id: id, name: id, type: .audio,
            source: .external(absolutePath: (dir as NSString).appendingPathComponent("\(id).m4a")),
            duration: duration
        )
    }

    private func export(_ timeline: Timeline, resolver: MediaResolver, tmpDir: URL) throws -> String {
        let outURL = tmpDir.appendingPathComponent("out.fcpxml")
        try FCPXMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)
        return try readXML(at: outURL)
    }

    // MARK: - Document structure

    @Test func headerHasFcpxmlProjectSequenceAndResources() throws {
        let timeline = Fixtures.timeline()
        let (resolver, tmpDir) = try makeResolver(entries: [])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        #expect(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        #expect(xml.contains("<!DOCTYPE fcpxml>"))
        #expect(xml.contains("<fcpxml version=\"1.14\">"))
        #expect(xml.contains("<resources>"))
        #expect(xml.contains("<format id=\"r1\""))
        #expect(xml.contains("<library>"))
        #expect(xml.contains("<event name=\"Palmier Export\">"))
        #expect(xml.contains("<project name=\"Timeline Export\">"))
        #expect(xml.contains("<sequence format=\"r1\" duration=\"0s\""))
        #expect(xml.contains("<spine/>"))
    }

    @Test func clipsReferencingUnresolvableMediaAreSkipped() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [])
        let clip = Fixtures.clip(id: "ghost", mediaRef: "missing", start: 0, duration: 30)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        #expect(!xml.contains("<asset-clip"))
        #expect(!xml.contains("ghost"))
    }

    @Test func repeatedMediaRefEmitsOneAssetResource() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoEntry(id: "shared", in: NSTemporaryDirectory())])
        let clipA = Fixtures.clip(id: "a", mediaRef: "shared", start: 0, duration: 30)
        let clipB = Fixtures.clip(id: "b", mediaRef: "shared", start: 60, duration: 30)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clipA, clipB])])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        let assetCount = xml.components(separatedBy: "<asset id=\"asset").count - 1
        let clipCount = xml.components(separatedBy: "<asset-clip ref=\"asset1\"").count - 1
        #expect(assetCount == 1)
        #expect(clipCount == 2)
    }

    @Test func sameMediaRefVideoAndAudioUseSeparateAssets() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoEntry(id: "media-v", in: NSTemporaryDirectory())])
        let video = Fixtures.clip(id: "video", mediaRef: "media-v", mediaType: .video, start: 0, duration: 30)
        let audio = Fixtures.clip(id: "audio", mediaRef: "media-v", mediaType: .audio, start: 0, duration: 30)
        let timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [video]),
            Fixtures.audioTrack(clips: [audio]),
        ])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)
        let videoAsset = xml.components(separatedBy: "<asset id=\"asset1\"").dropFirst().first?.components(separatedBy: "</asset>").first ?? ""
        let audioAsset = xml.components(separatedBy: "<asset id=\"asset2\"").dropFirst().first?.components(separatedBy: "</asset>").first ?? ""

        #expect(videoAsset.contains("hasVideo=\"1\""))
        #expect(videoAsset.contains("format=\"format1\""))
        #expect(!videoAsset.contains("hasAudio"))
        #expect(audioAsset.contains("hasAudio=\"1\""))
        #expect(!audioAsset.contains("hasVideo"))
        #expect(xml.contains("<asset-clip ref=\"asset1\" name=\"media-v\" lane=\"1\""))
        #expect(xml.contains("<asset-clip ref=\"asset2\" name=\"media-v\" lane=\"-1\""))
        #expect(!xml.contains("srcEnable"))
    }

    @Test func visualTrackLanesPreserveTopOverBottom() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoEntry(id: "media-v", in: NSTemporaryDirectory())])
        let top = Fixtures.clip(id: "top", mediaRef: "media-v", start: 0, duration: 30)
        let bottom = Fixtures.clip(id: "bottom", mediaRef: "media-v", start: 0, duration: 30)
        let timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [top]),
            Fixtures.videoTrack(clips: [bottom]),
        ])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        #expect(xml.contains("name=\"media-v\" lane=\"2\" offset=\"0s\""))
        #expect(xml.contains("name=\"media-v\" lane=\"1\" offset=\"0s\""))
    }

    // MARK: - Timing & speed

    @Test func videoClipEmitsAssetClipWithOffsetStartAndDuration() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoEntry(id: "media-v", in: NSTemporaryDirectory())])
        let clip = Fixtures.clip(id: "clip-1", mediaRef: "media-v", start: 30, duration: 60, trimStart: 10)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        #expect(xml.contains("<asset-clip ref=\"asset1\" name=\"media-v\" lane=\"1\""))
        #expect(xml.contains("offset=\"1s\""))
        #expect(xml.contains("start=\"1/3s\""))
        #expect(xml.contains("duration=\"2s\""))
        #expect(!xml.contains("srcEnable"))
    }

    @Test func speedChangeEmitsRelativeTimeMap() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoEntry(id: "media-v", in: NSTemporaryDirectory())])
        let clip = Fixtures.clip(id: "fast", mediaRef: "media-v", start: 0, duration: 60, trimStart: 10, speed: 2.0)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        // start positions the in-point (trimStart 10 / 30fps); the timeMap is relative to it (0 → span).
        #expect(xml.contains("offset=\"0s\" start=\"1/3s\" duration=\"2s\""))
        #expect(xml.contains("<timeMap frameSampling=\"floor\">"))
        #expect(xml.contains("<timept time=\"0s\" value=\"0s\" interp=\"linear\"/>"))
        #expect(xml.contains("<timept time=\"2s\" value=\"4s\" interp=\"linear\"/>"))
    }

    // MARK: - Transform, scale, flip

    @Test func fittedVideoEmitsNoTransform() throws {
        // A fitted clip (width/height = its aspect-fit) divides out to scale 1×1 → nothing emitted.
        let entry = videoEntry(id: "media-v", in: NSTemporaryDirectory(), sourceWidth: 3413, sourceHeight: 607)
        let (resolver, tmpDir) = try makeResolver(entries: [entry])
        var clip = Fixtures.clip(id: "clip-1", mediaRef: "media-v", start: 0, duration: 60)
        clip.transform = Transform(width: 1, height: (1920.0 / 1080.0) / (3413.0 / 607.0))
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        #expect(xml.contains("<format id=\"format1\" name=\"media-v\" frameDuration=\"1/30s\" width=\"3413\" height=\"607\"/>"))
        #expect(!xml.contains("<adjust-transform"))
    }

    @Test func centeredUnrotatedVideoOmitsTransform() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoEntry(id: "media-v", in: NSTemporaryDirectory())])
        let clip = Fixtures.clip(id: "clip-1", mediaRef: "media-v", start: 0, duration: 60)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        #expect(!xml.contains("<adjust-transform"))
    }

    @Test func videoTransformExportsPositionAndRotation() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoEntry(id: "media-v", in: NSTemporaryDirectory())])
        var clip = Fixtures.clip(id: "clip-1", mediaRef: "media-v", start: 0, duration: 60)
        clip.transform = Transform(centerX: 0.25, centerY: 0.75, rotation: 30)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        // 1080p: x = (0.25-0.5)*1920/10.8 = -44.4444, y = (0.5-0.75)*100 = -25; rotation negated.
        #expect(xml.contains("<adjust-transform scale=\"1 1\" rotation=\"-30\" anchor=\"0 0\" position=\"-44.4444 -25\"/>"))
    }

    @Test func scaledVideoExportsScaleRelativeToFit() throws {
        // Mismatched source (ultra-wide) at half its fitted size: the aspect-fit divides out, leaving 0.5×0.5.
        let entry = videoEntry(id: "media-v", in: NSTemporaryDirectory(), sourceWidth: 3413, sourceHeight: 607)
        let (resolver, tmpDir) = try makeResolver(entries: [entry])
        var clip = Fixtures.clip(id: "clip-1", mediaRef: "media-v", start: 0, duration: 60)
        let fitHeight = (1920.0 / 1080.0) / (3413.0 / 607.0)
        clip.transform = Transform(width: 0.5, height: fitHeight * 0.5)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        #expect(xml.contains("<adjust-transform scale=\"0.5 0.5\" anchor=\"0 0\" position=\"0 0\"/>"))
    }

    @Test func matchedAspectScaleExportsFractionDirectly() throws {
        // Source aspect == frame aspect → no fit division, scale is the raw fraction.
        let (resolver, tmpDir) = try makeResolver(entries: [videoEntry(id: "media-v", in: NSTemporaryDirectory())])
        var clip = Fixtures.clip(id: "clip-1", mediaRef: "media-v", start: 0, duration: 60)
        clip.transform = Transform(width: 0.5, height: 0.5)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        #expect(xml.contains("<adjust-transform scale=\"0.5 0.5\" anchor=\"0 0\" position=\"0 0\"/>"))
    }

    @Test func horizontalFlipExportsNegativeScale() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoEntry(id: "media-v", in: NSTemporaryDirectory())])
        var clip = Fixtures.clip(id: "clip-1", mediaRef: "media-v", start: 0, duration: 60)
        clip.transform = Transform(flipHorizontal: true)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        #expect(xml.contains("<adjust-transform scale=\"-1 1\" anchor=\"0 0\" position=\"0 0\"/>"))
    }

    @Test func positionKeyframesExportAsParamAnimation() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoEntry(id: "media-v", in: NSTemporaryDirectory())])
        var clip = Fixtures.clip(id: "clip-1", mediaRef: "media-v", start: 0, duration: 60)
        // positionTrack stores topLeft; with default size 1×1, topLeft (0,b) → center (0.5, b+0.5).
        clip.positionTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: AnimPair(a: 0, b: 0), interpolationOut: .linear),
            Keyframe(frame: 30, value: AnimPair(a: 0, b: 0.25), interpolationOut: .linear),
        ])
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        #expect(xml.contains("<param name=\"position\" value=\"0 0\">"))
        #expect(xml.contains("<keyframeAnimation>"))
        #expect(xml.contains("<keyframe time=\"0s\" curve=\"linear\" value=\"0 0\"/>"))
        #expect(xml.contains("<keyframe time=\"1s\" curve=\"linear\" value=\"0 -25\"/>"))
    }

    // MARK: - Crop

    @Test func cropExportsTrimRectAsPercent() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoEntry(id: "media-v", in: NSTemporaryDirectory())])
        var clip = Fixtures.clip(id: "clip-1", mediaRef: "media-v", start: 0, duration: 60)
        clip.crop = Crop(left: 0.1, top: 0.2, right: 0.3, bottom: 0.4)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        #expect(xml.contains("<adjust-crop mode=\"trim\">"))
        #expect(xml.contains("<trim-rect top=\"20\" right=\"30\" bottom=\"40\" left=\"10\"/>"))
    }

    @Test func identityCropOmitsAdjustCrop() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoEntry(id: "media-v", in: NSTemporaryDirectory())])
        let clip = Fixtures.clip(id: "clip-1", mediaRef: "media-v", start: 0, duration: 60)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        #expect(!xml.contains("<adjust-crop"))
    }

    // MARK: - Opacity

    @Test func clipOpacityExportsAdjustBlend() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoEntry(id: "media-v", in: NSTemporaryDirectory())])
        var clip = Fixtures.clip(id: "clip-1", mediaRef: "media-v", start: 0, duration: 60)
        clip.opacity = 0.25
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        #expect(xml.contains("<adjust-blend amount=\"0.25\"/>"))
    }

    @Test func fullyOpaqueClipOmitsAdjustBlend() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoEntry(id: "media-v", in: NSTemporaryDirectory())])
        let clip = Fixtures.clip(id: "clip-1", mediaRef: "media-v", start: 0, duration: 60)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        #expect(!xml.contains("<adjust-blend"))
    }

    @Test func opacityKeyframesExportInsideAdjustBlend() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoEntry(id: "media-v", in: NSTemporaryDirectory())])
        var clip = Fixtures.clip(id: "clip-1", mediaRef: "media-v", start: 0, duration: 60)
        clip.opacityTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 0.0, interpolationOut: .linear),
            Keyframe(frame: 30, value: 1.0, interpolationOut: .linear),
        ])
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        #expect(xml.contains("<adjust-blend amount=\"1\">"))
        #expect(xml.contains("<param name=\"amount\" value=\"1\">"))
        #expect(xml.contains("<keyframe time=\"0s\" curve=\"linear\" value=\"0\"/>"))
        #expect(xml.contains("<keyframe time=\"1s\" curve=\"linear\" value=\"1\"/>"))
    }

    // MARK: - Volume

    @Test func reducedVolumeExportsAdjustVolumeInDecibels() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [audioEntry(id: "media-a", in: NSTemporaryDirectory())])
        var clip = Fixtures.clip(id: "clip-a", mediaRef: "media-a", mediaType: .audio, start: 0, duration: 60)
        clip.volume = 0.5
        let timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        #expect(xml.contains("<adjust-volume amount=\"-6.0206\"/>"))  // 20*log10(0.5)
    }

    @Test func unityVolumeOmitsAdjustVolume() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [audioEntry(id: "media-a", in: NSTemporaryDirectory())])
        let clip = Fixtures.clip(id: "clip-a", mediaRef: "media-a", mediaType: .audio, start: 0, duration: 60)
        let timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        #expect(!xml.contains("<adjust-volume"))
    }

    @Test func volumeKeyframesCollapseToStaticLevel() throws {
        // DaVinci itself drops keyframed audio volume on FCPXML export, so we emit just the static level.
        let (resolver, tmpDir) = try makeResolver(entries: [audioEntry(id: "media-a", in: NSTemporaryDirectory())])
        var clip = Fixtures.clip(id: "clip-a", mediaRef: "media-a", mediaType: .audio, start: 0, duration: 60)
        clip.volume = 0.5
        clip.volumeTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 0.0, interpolationOut: .linear),
            Keyframe(frame: 30, value: -6.0, interpolationOut: .linear),
        ])
        let timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        #expect(xml.contains("<adjust-volume amount=\"-6.0206\"/>"))  // self-closing → no keyframeAnimation
    }

    // MARK: - Deliberately not exported

    @Test func fadesAndChannelLayoutAreNotExported() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [audioEntry(id: "media-a", in: NSTemporaryDirectory())])
        var audio = Fixtures.clip(id: "audio", mediaRef: "media-a", mediaType: .audio, start: 0, duration: 60)
        audio.fadeInFrames = 15
        let timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [audio])])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        #expect(xml.contains("<asset-clip ref=\"asset1\""))
        #expect(!xml.contains("<fadeIn"))
        #expect(!xml.contains("audioSources="))
        #expect(!xml.contains("audioChannels="))
    }

    // MARK: - Titles

    @Test func textClipEmitsTitleAndEscapedText() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [])
        var text = Fixtures.clip(id: "title", mediaRef: "text", mediaType: .text, start: 30, duration: 60)
        text.textContent = "A & B"
        var style = TextStyle()
        style.fontName = "Helvetica"
        style.fontSize = 48
        style.alignment = .left
        text.textStyle = style
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [text])])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        #expect(xml.contains("<effect id=\"titleBasic\""))
        #expect(xml.contains("<title ref=\"titleBasic\" name=\"A &amp; B\""))
        #expect(xml.contains("<text-style ref=\"textStyle1\">A &amp; B</text-style>"))
        #expect(xml.contains("font=\"Helvetica\""))
        #expect(xml.contains("fontFace=\"Regular\""))
        #expect(xml.contains("fontSize=\"48\""))
        #expect(xml.contains("alignment=\"left\""))
    }

    @Test func postScriptFontNameExportsFamilyAndFaceForResolveTitles() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [])
        var text = Fixtures.clip(id: "title", mediaRef: "text", mediaType: .text, start: 0, duration: 60)
        text.textContent = "Caption"
        var style = TextStyle()
        style.fontName = "Helvetica-Bold"
        text.textStyle = style
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [text])])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        #expect(xml.contains("font=\"Helvetica\""))
        #expect(xml.contains("fontFace=\"Bold\""))
    }

    @Test func verticalTimelineScalesTitleFontSizeLikeRenderer() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [])
        var text = Fixtures.clip(id: "title", mediaRef: "text", mediaType: .text, start: 0, duration: 60)
        text.textContent = "Caption"
        text.textStyle = TextStyle(fontSize: 48)
        var timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [text])])
        timeline.width = 720
        timeline.height = 1280

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        #expect(xml.contains("fontSize=\"56.8889\""))
        #expect(xml.contains("<adjust-transform scale=\"1 1\" anchor=\"0 0\" position=\"0 0\"/>"))
    }

    @Test func textBoxTransformExportsTitlePositionAndOpacity() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [])
        var text = Fixtures.clip(id: "title", mediaRef: "text", mediaType: .text, start: 0, duration: 60)
        text.textContent = "Caption"
        text.opacity = 0.5
        text.transform = Transform(centerX: 0.25, centerY: 0.75, width: 0.2, height: 0.1, rotation: 15)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [text])])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        #expect(xml.contains("<title ref=\"titleBasic\" name=\"Caption\""))
        #expect(xml.contains("<text-style ref=\"textStyle1\">Caption</text-style>"))
        #expect(xml.contains("<adjust-conform type=\"fit\"/>"))
        #expect(xml.contains("<adjust-transform scale=\"1 1\" anchor=\"0 0\" position=\"-44.4444 -25\"/>"))
        #expect(!xml.contains("<param name=\"Position\""))
        #expect(xml.contains("<adjust-blend amount=\"0.5\"/>"))
    }

    // MARK: - Export service

    @Test func fcpxmlExportThroughExportServiceWritesFileWithoutError() async throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoEntry(id: "media-v", in: NSTemporaryDirectory())])
        let clip = Fixtures.clip(id: "clip", mediaRef: "media-v", start: 0, duration: 30)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        let outURL = tmpDir.appendingPathComponent("service.fcpxml")

        let svc = await ExportService()
        await svc.export(
            timeline: timeline,
            resolver: resolver,
            format: .fcpxml,
            resolution: .r1080p,
            outputURL: outURL
        )

        await #expect(svc.error == nil)
        await #expect(svc.progress == 1.0)
        #expect(FileManager.default.fileExists(atPath: outURL.path))
    }
}
