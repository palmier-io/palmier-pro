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
        sourceHeight: Int = 1080,
        hasAudio: Bool? = nil
    ) -> MediaManifestEntry {
        MediaManifestEntry(
            id: id, name: id, type: .video,
            source: .external(absolutePath: (dir as NSString).appendingPathComponent("\(id).mp4")),
            duration: duration,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            hasAudio: hasAudio
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
        #expect(xml.contains("<fcpxml version=\"1.10\">"))
        #expect(xml.contains("<resources>"))
        #expect(xml.contains("<format id=\"r1\""))
        #expect(xml.contains("name=\"FFVideoFormat1080p30\""))
        #expect(xml.contains("colorSpace=\"1-1-1 (Rec. 709)\""))
        #expect(xml.contains("<library>"))
        #expect(xml.contains("<event name=\"Palmier Export\">"))
        #expect(xml.contains("<project name=\"Timeline Export\">"))
        #expect(xml.contains("<sequence format=\"r1\" duration=\"0s\""))
        #expect(xml.contains("<spine/>"))
    }

    @Test func explicitVersionIsHonoredInHeader() throws {
        let timeline = Fixtures.timeline()
        let (resolver, tmpDir) = try makeResolver(entries: [])
        let outURL = tmpDir.appendingPathComponent("v14.fcpxml")

        try FCPXMLExporter.export(timeline: timeline, resolver: resolver, version: .v1_14, outputURL: outURL)

        #expect(try readXML(at: outURL).contains("<fcpxml version=\"1.14\">"))
    }

    @Test func clipsReferencingUnresolvableMediaAreSkipped() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [])
        let clip = Fixtures.clip(id: "ghost", mediaRef: "missing", start: 0, duration: 30)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        #expect(!xml.contains("<ref-clip"))     // visual clips emit ref-clips now
        #expect(!xml.contains("<media id="))    // and their compound clip
        #expect(!xml.contains("ghost"))
    }

    @Test func repeatedMediaRefEmitsOneAssetResource() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoEntry(id: "shared", in: NSTemporaryDirectory())])
        let clipA = Fixtures.clip(id: "a", mediaRef: "shared", start: 0, duration: 30)
        let clipB = Fixtures.clip(id: "b", mediaRef: "shared", start: 60, duration: 30)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clipA, clipB])])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        let assetCount = xml.components(separatedBy: "<asset id=\"asset").count - 1
        let compoundCount = xml.components(separatedBy: "<media id=\"media").count - 1
        let clipCount = xml.components(separatedBy: "<ref-clip ref=\"media1\"").count - 1
        #expect(assetCount == 1)       // one shared asset
        #expect(compoundCount == 1)    // one shared compound clip
        #expect(clipCount == 2)        // two ref-clips reference it
    }

    @Test func distinctMediaRefsWithSameSourceFileEmitOneAssetResource() throws {
        let source = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shared-source-\(UUID().uuidString).mp4")
        let entryA = MediaManifestEntry(
            id: "shared-a", name: "A", type: .video,
            source: .external(absolutePath: source.path),
            duration: 5,
            sourceWidth: 1920,
            sourceHeight: 1080,
            hasAudio: true
        )
        let entryB = MediaManifestEntry(
            id: "shared-b", name: "B", type: .video,
            source: .external(absolutePath: source.path),
            duration: 5,
            sourceWidth: 1920,
            sourceHeight: 1080,
            hasAudio: true
        )
        let (resolver, tmpDir) = try makeResolver(entries: [entryA, entryB])
        let clipA = Fixtures.clip(id: "a", mediaRef: "shared-a", start: 0, duration: 30)
        let clipB = Fixtures.clip(id: "b", mediaRef: "shared-b", start: 60, duration: 30)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clipA, clipB])])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        let assetCount = xml.components(separatedBy: "<asset id=\"asset").count - 1
        let compoundCount = xml.components(separatedBy: "<media id=\"media").count - 1
        #expect(assetCount == 1)
        #expect(compoundCount == 1)
        #expect(xml.contains("<ref-clip ref=\"media1\" name=\"A\""))
        #expect(xml.contains("<ref-clip ref=\"media1\" name=\"B\""))
        #expect(!xml.contains("<asset id=\"asset2\""))
    }

    @Test func assetResourcesOmitSyntheticUID() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoEntry(id: "media-v", in: NSTemporaryDirectory())])
        let clip = Fixtures.clip(id: "clip", mediaRef: "media-v", start: 0, duration: 30)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)
        let asset = xml.components(separatedBy: "<asset id=\"asset1\"").dropFirst().first?
            .components(separatedBy: "</asset>").first ?? ""

        #expect(!asset.contains("uid="))
        #expect(!xml.contains("io.palmier.media.asset"))
    }

    @Test func visualClipWrapsAssetInFullMediaCompoundClip() throws {
        // The compound clip must hold the FULL media (here 5s @30fps = 150 frames), independent of the
        // clip's trim/duration — that runway is what stops Resolve blacking a retimed tail. The ref-clip
        // also carries adjust-conform=fit to match Resolve.
        let (resolver, tmpDir) = try makeResolver(entries: [videoEntry(id: "media-v", in: NSTemporaryDirectory())])
        let clip = Fixtures.clip(id: "c", mediaRef: "media-v", start: 0, duration: 30, trimStart: 20)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)
        let compound = xml.components(separatedBy: "<media id=\"media1\"").dropFirst().first?
            .components(separatedBy: "</media>").first ?? ""

        #expect(compound.contains("<sequence format=\"r2\" duration=\"5s\""))
        #expect(compound.contains("<clip name=\"media-v\" duration=\"5s\" start=\"0s\" offset=\"0s\" format=\"r2\">"))
        #expect(compound.contains("<video ref=\"asset1\" duration=\"5s\" start=\"0s\" offset=\"0s\"/>"))
        #expect(xml.contains("<adjust-conform type=\"fit\"/>"))
    }

    @Test func sameMediaRefVideoAndAudioShareOneAsset() throws {
        // Unlinked video + audio on the same A/V source (no linkGroup): each stays on its own lane but
        // both route through the compound so srcEnable is honored (Resolve ignores it on bare asset-clips).
        let (resolver, tmpDir) = try makeResolver(entries: [videoEntry(id: "media-v", in: NSTemporaryDirectory(), hasAudio: true)])
        let video = Fixtures.clip(id: "video", mediaRef: "media-v", mediaType: .video, start: 0, duration: 30)
        let audio = Fixtures.clip(id: "audio", mediaRef: "media-v", mediaType: .audio, start: 0, duration: 30)
        let timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [video]),
            Fixtures.audioTrack(clips: [audio]),
        ])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        // One asset per source file, carrying both streams — Resolve's relinker fails on two assets
        // sharing a media-rep src.
        #expect(!xml.contains("<asset id=\"asset2\""))
        let asset = xml.components(separatedBy: "<asset id=\"asset1\"").dropFirst().first?.components(separatedBy: "</asset>").first ?? ""
        #expect(asset.contains("hasVideo=\"1\""))
        #expect(asset.contains("format=\"r2\""))
        #expect(asset.contains("videoSources=\"1\""))
        #expect(asset.contains("hasAudio=\"1\""))
        #expect(asset.contains("audioSources=\"1\""))
        #expect(asset.contains("audioChannels=\"2\""))
        #expect(asset.contains("audioRate=\"48000\""))
        // Both clips are <ref-clip>s over the compound, gated by srcEnable so neither pulls the other's
        // stream. The compound itself wraps the asset as an <asset-clip> to carry audio.
        #expect(xml.contains("<ref-clip ref=\"media1\" name=\"media-v\" lane=\"1\""))
        #expect(xml.contains("srcEnable=\"video\""))
        #expect(xml.contains("<ref-clip ref=\"media1\" name=\"media-v\" lane=\"-1\""))
        #expect(xml.contains("srcEnable=\"audio\""))
    }

    @Test func linkedAvPairCollapsesToOneRefClip() throws {
        // A synced A/V pair (shared linkGroup, aligned) becomes a single <ref-clip> carrying both streams.
        // The separate audio clip is dropped so Resolve doesn't import a phantom second video track.
        let (resolver, tmpDir) = try makeResolver(entries: [videoEntry(id: "media-v", in: NSTemporaryDirectory(), hasAudio: true)])
        var video = Fixtures.clip(id: "video", mediaRef: "media-v", mediaType: .video, start: 0, duration: 30)
        var audio = Fixtures.clip(id: "audio", mediaRef: "media-v", mediaType: .audio, start: 0, duration: 30, volume: 0.5)
        video.linkGroupId = "pair"
        audio.linkGroupId = "pair"
        let timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [video]),
            Fixtures.audioTrack(clips: [audio]),
        ])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        // One timeline element: the video ref-clip, no srcEnable (both streams play). No audio lane.
        #expect(xml.contains("<ref-clip ref=\"media1\" name=\"media-v\" lane=\"1\""))
        #expect(!xml.contains("lane=\"-1\""))
        #expect(!xml.contains("srcEnable="))
        // The dropped audio clip's volume rides on the surviving ref-clip.
        #expect(xml.contains("<adjust-volume amount=\"-6.0206\"/>"))
    }

    @Test func mutedAudioTrackKeepsLinkedPairSeparate() throws {
        // A muted audio track under a shown video has divergent enabled state, so the pair must NOT
        // collapse — else the audio would ride the (enabled) video clip and lose its mute.
        let (resolver, tmpDir) = try makeResolver(entries: [videoEntry(id: "media-v", in: NSTemporaryDirectory(), hasAudio: true)])
        var video = Fixtures.clip(id: "video", mediaRef: "media-v", mediaType: .video, start: 0, duration: 30)
        var audio = Fixtures.clip(id: "audio", mediaRef: "media-v", mediaType: .audio, start: 0, duration: 30)
        video.linkGroupId = "pair"
        audio.linkGroupId = "pair"
        var audioTrack = Fixtures.audioTrack(clips: [audio])
        audioTrack.muted = true
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [video]), audioTrack])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        // Both survive on their own lanes; the audio is a disabled ref-clip, video stays enabled video-only.
        #expect(xml.contains("<ref-clip ref=\"media1\" name=\"media-v\" lane=\"1\""))
        #expect(xml.contains("srcEnable=\"video\""))
        #expect(xml.contains("<ref-clip ref=\"media1\" name=\"media-v\" lane=\"-1\""))
        #expect(xml.contains("srcEnable=\"audio\""))
        #expect(xml.contains("enabled=\"0\""))
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

    @Test func videoClipEmitsRefClipWithOffsetStartAndDuration() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoEntry(id: "media-v", in: NSTemporaryDirectory())])
        let clip = Fixtures.clip(id: "clip-1", mediaRef: "media-v", start: 30, duration: 60, trimStart: 10)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        // Unspeeded: start is the raw source in-point (trimStart 10 / 30fps = 1/3s), no timeMap.
        #expect(xml.contains("<ref-clip ref=\"media1\" name=\"media-v\" lane=\"1\""))
        #expect(xml.contains("offset=\"1s\""))
        #expect(xml.contains("start=\"1/3s\""))
        #expect(xml.contains("duration=\"2s\""))
        #expect(!xml.contains("<timeMap"))
    }

    @Test func speedChangeEmitsWholeMediaTimeMap() throws {
        // 5s media @ 30fps = 150 source frames; 2× speed-up, trimStart 10, 60-frame output.
        let (resolver, tmpDir) = try makeResolver(entries: [videoEntry(id: "media-v", in: NSTemporaryDirectory())])
        let clip = Fixtures.clip(id: "fast", mediaRef: "media-v", start: 0, duration: 60, trimStart: 10, speed: 2.0)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        // start is in the OUTPUT axis (source-in 10 ÷ speed 2 = 5 frames = 1/6s); the timeMap describes
        // the WHOLE media retimed (output 150/2=75f=5/2s → source 150f=5s), windowed by start/duration.
        #expect(xml.contains("offset=\"0s\" start=\"1/6s\" duration=\"2s\""))
        #expect(xml.contains("<timeMap frameSampling=\"floor\">"))
        #expect(xml.contains("<timept time=\"0s\" value=\"0s\" interp=\"linear\"/>"))
        #expect(xml.contains("<timept time=\"5/2s\" value=\"5s\" interp=\"linear\"/>"))
    }

    @Test func slowMotionEmitsWholeMediaTimeMap() throws {
        // 0.5× slow-mo: source plays at half rate, so the whole-media ramp's output axis is LONGER than
        // the source (150 source frames = 5s → output 10s). Exercises the speed < 1 (p<q) path.
        let (resolver, tmpDir) = try makeResolver(entries: [videoEntry(id: "media-v", in: NSTemporaryDirectory())])
        let clip = Fixtures.clip(id: "slow", mediaRef: "media-v", start: 0, duration: 60, trimStart: 30, speed: 0.5)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        // start = 30 ÷ 0.5 = 60 output frames = 2s; ramp output 150/0.5=300f=10s → source 150f=5s.
        #expect(xml.contains("start=\"2s\""))
        #expect(xml.contains("<timept time=\"10s\" value=\"5s\" interp=\"linear\"/>"))
    }

    @Test func retimedKeyframeTimeIsOffsetByStart() throws {
        // Resolve measures param keyframe time from the timeMap origin, so it's offset by the clip's
        // output-axis start (trimStart ÷ speed), not zero-based. 5s media @30fps, 2× speed, trimStart 10.
        let (resolver, tmpDir) = try makeResolver(entries: [videoEntry(id: "media-v", in: NSTemporaryDirectory())])
        var clip = Fixtures.clip(id: "z", mediaRef: "media-v", start: 0, duration: 60, trimStart: 10, speed: 2.0)
        clip.scaleTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: AnimPair(a: 0.5, b: 0.5), interpolationOut: .linear),
            Keyframe(frame: 15, value: AnimPair(a: 1, b: 1), interpolationOut: .linear),
        ])
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        // start = 10/(2×30) = 1/6s; first keyframe sits AT start, second 15 output frames later (1/6+1/2=2/3s).
        #expect(xml.contains("start=\"1/6s\""))
        #expect(xml.contains("<keyframe time=\"1/6s\""))
        #expect(xml.contains("<keyframe time=\"2/3s\""))
    }

    @Test func unspeededTrimmedKeyframeStaysClipRelative() throws {
        // With no timeMap there's no output-axis origin, so keyframe time is plain clip-relative — NOT
        // offset by trimStart. (Guards against over-applying the retimed-clip offset.)
        let (resolver, tmpDir) = try makeResolver(entries: [videoEntry(id: "media-v", in: NSTemporaryDirectory())])
        var clip = Fixtures.clip(id: "t", mediaRef: "media-v", start: 0, duration: 60, trimStart: 10)
        clip.opacityTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 0.0, interpolationOut: .linear),
            Keyframe(frame: 30, value: 1.0, interpolationOut: .linear),
        ])
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        #expect(!xml.contains("<timeMap"))
        #expect(xml.contains("<keyframe time=\"0s\" curve=\"linear\" value=\"0\"/>"))   // not 1/3s
        #expect(xml.contains("<keyframe time=\"1s\" curve=\"linear\" value=\"1\"/>"))
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

        #expect(xml.contains("<format id=\"r2\" name=\"FFVideoFormat3413x607p30\" frameDuration=\"1/30s\" width=\"3413\" height=\"607\" colorSpace=\"1-1-1 (Rec. 709)\"/>"))
        #expect(!xml.contains("<adjust-transform"))
    }

    @Test func ntscSourceFormatUsesFinalCutRateSuffix() throws {
        var entry = videoEntry(id: "media-v", in: NSTemporaryDirectory())
        entry.sourceFPS = 29.97
        let (resolver, tmpDir) = try makeResolver(entries: [entry])
        let clip = Fixtures.clip(id: "clip-1", mediaRef: "media-v", start: 0, duration: 60)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        #expect(xml.contains("<format id=\"r2\" name=\"FFVideoFormat1080p2997\" frameDuration=\"1001/30000s\" width=\"1920\" height=\"1080\" colorSpace=\"1-1-1 (Rec. 709)\"/>"))
    }

    @Test func customTimelineFormatUsesFinalCutGenericPresetName() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoEntry(id: "media-v", in: NSTemporaryDirectory())])
        let clip = Fixtures.clip(id: "clip-1", mediaRef: "media-v", start: 0, duration: 60)
        var timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        timeline.width = 1080
        timeline.height = 1920

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        #expect(xml.contains("<format id=\"r1\" name=\"FFVideoFormatRateUndefined\" frameDuration=\"1/30s\" width=\"1080\" height=\"1920\" colorSpace=\"1-1-1 (Rec. 709)\"/>"))
        #expect(xml.contains("<sequence format=\"r1\""))
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

        // Pure audio source → no srcEnable (it has no video stream to disambiguate).
        #expect(xml.contains("<asset-clip ref=\"asset1\""))
        #expect(!xml.contains("srcEnable="))
        #expect(!xml.contains("<fadeIn"))
        #expect(!xml.contains("<audio-channel-source"))
    }

    // MARK: - Titles

    @Test func textClipEmitsTitleAndEscapedText() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [])
        var text = Fixtures.clip(id: "title", mediaRef: "text", mediaType: .text, start: 30, duration: 60)
        text.textContent = "A & B"
        var style = TextStyle()
        style.fontName = "Helvetica"
        style.fontSize = 48
        style.isBold = false
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

    @Test func explicitFontTraitsOverridePostScriptFontFaceForResolveTitles() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [])
        var text = Fixtures.clip(id: "title", mediaRef: "text", mediaType: .text, start: 0, duration: 60)
        text.textContent = "Caption"
        var style = TextStyle()
        style.fontName = "Helvetica-Bold"
        style.isBold = false
        style.isItalic = false
        text.textStyle = style
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [text])])

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        #expect(xml.contains("font=\"Helvetica\""))
        #expect(xml.contains("fontFace=\"Regular\""))
    }

    @Test func titleFontSizeDoesNotScaleWithSequenceHeight() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [])
        var text = Fixtures.clip(id: "title", mediaRef: "text", mediaType: .text, start: 0, duration: 60)
        text.textContent = "Caption"
        text.textStyle = TextStyle(fontSize: 48)
        var timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [text])])
        timeline.width = 720
        timeline.height = 1280

        let xml = try export(timeline, resolver: resolver, tmpDir: tmpDir)

        #expect(xml.contains("fontSize=\"48\""))
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
