using System.Xml.Linq;
using PalmierPro.Core.Export;
using PalmierPro.Core.Models;
using PalmierPro.Services.Export;
using Shouldly;
using Xunit;

namespace PalmierPro.Services.Tests.Export;

/// Ported from Tests/PalmierProTests/Export/FCPXMLExporterTests.swift. Each test names its source
/// Swift test. Assertions use substring containment like the Swift `#expect(xml.contains(...))`
/// pattern; a few additionally parse the document with `XDocument` to confirm it's well-formed XML.
public class FcpxmlExporterTests
{
    private static readonly FakeFontTraitResolver FontResolver = new();

    private static string Render(Timeline timeline, MediaResolver resolver,
        FcpxmlVersion version = FcpxmlVersionExtensions.Default, FcpxmlTarget target = FcpxmlTargetExtensions.Default,
        Func<string, Timeline?>? resolveTimeline = null, IReadOnlyDictionary<string, SourceTimecode>? startTimecodes = null) =>
        FcpxmlExporter.Render(timeline, resolver, FontResolver, resolveTimeline, version, target, startTimecodes);

    // MARK: - Document structure

    /// Source: headerHasFcpxmlProjectSequenceAndResources
    [Fact]
    public void Header_HasFcpxmlProjectSequenceAndResources()
    {
        var timeline = ExportFixtures.Timeline();
        var resolver = ExportFixtures.ResolverFor();

        var xml = Render(timeline, resolver);

        xml.ShouldStartWith("<?xml version=\"1.0\" encoding=\"UTF-8\"?>");
        xml.ShouldContain("<!DOCTYPE fcpxml>");
        xml.ShouldContain("<fcpxml version=\"1.10\">");
        xml.ShouldContain("<resources>");
        xml.ShouldContain("<format id=\"r1\"");
        xml.ShouldContain("name=\"FFVideoFormat1080p30\"");
        xml.ShouldContain("colorSpace=\"1-1-1 (Rec. 709)\"");
        xml.ShouldContain("<library>");
        xml.ShouldContain("<event name=\"Palmier Export\">");
        xml.ShouldContain($"<project name=\"{timeline.Name}\">");
        xml.ShouldContain("<sequence format=\"r1\" duration=\"0s\"");
        xml.ShouldContain("<spine/>");

        // Parses as well-formed XML (part of the "output XML parses" requirement).
        Should.NotThrow(() => XDocument.Parse(xml));
    }

    /// Source: explicitVersionIsHonoredInHeader
    [Fact]
    public void ExplicitVersion_IsHonoredInHeader()
    {
        var timeline = ExportFixtures.Timeline();
        var resolver = ExportFixtures.ResolverFor();

        var xml = Render(timeline, resolver, version: FcpxmlVersion.V1_14);

        xml.ShouldContain("<fcpxml version=\"1.14\">");
    }

    /// Source: clipsReferencingUnresolvableMediaAreSkipped
    [Fact]
    public void Clips_ReferencingUnresolvableMedia_AreSkipped()
    {
        var resolver = ExportFixtures.ResolverFor();
        var clip = ExportFixtures.Clip(id: "ghost", mediaRef: "missing", start: 0, duration: 30);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);

        var xml = Render(timeline, resolver);

        xml.ShouldNotContain("<asset-clip");
        xml.ShouldNotContain("<ref-clip");
        xml.ShouldNotContain("<media id=");
        xml.ShouldNotContain("ghost");
    }

    /// Source: repeatedMediaRefEmitsOneAssetResource
    [Fact]
    public void RepeatedMediaRef_EmitsOneAssetResource()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("shared", dir));
        var clipA = ExportFixtures.Clip(id: "a", mediaRef: "shared", start: 0, duration: 30);
        var clipB = ExportFixtures.Clip(id: "b", mediaRef: "shared", start: 60, duration: 30);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clipA, clipB)]);

        var xml = Render(timeline, resolver);

        Count(xml, "<asset id=\"asset").ShouldBe(1);          // one shared asset
        Count(xml, "<media id=\"media").ShouldBe(0);           // audio-less source needs no compound
        Count(xml, "<asset-clip ref=\"asset1\"").ShouldBe(2);  // two flat asset-clips reference it
    }

    /// Source: distinctMediaRefsWithSameSourceFileEmitOneAssetResource
    [Fact]
    public void DistinctMediaRefs_WithSameSourceFile_EmitOneAssetResource()
    {
        var dir = ExportFixtures.NewTempDir();
        var sourcePath = Path.Combine(dir, $"shared-source-{Guid.NewGuid():N}.mp4");
        var entryA = new MediaManifestEntry("shared-a", "A", ClipType.Video, MediaSource.External(sourcePath), 5, sourceWidth: 1920, sourceHeight: 1080, hasAudio: true);
        var entryB = new MediaManifestEntry("shared-b", "B", ClipType.Video, MediaSource.External(sourcePath), 5, sourceWidth: 1920, sourceHeight: 1080, hasAudio: true);
        var resolver = ExportFixtures.ResolverFor(entryA, entryB);
        var clipA = ExportFixtures.Clip(id: "a", mediaRef: "shared-a", start: 0, duration: 30);
        var clipB = ExportFixtures.Clip(id: "b", mediaRef: "shared-b", start: 60, duration: 30);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clipA, clipB)]);

        var xml = Render(timeline, resolver);

        Count(xml, "<asset id=\"asset").ShouldBe(1);
        Count(xml, "<media id=\"media").ShouldBe(1);
        // Both refs collapse onto the one asset; each ref-clip is named for the shared file (with
        // extension) so Resolve relinks them.
        Count(xml, $"<ref-clip ref=\"media1\" name=\"{Path.GetFileName(sourcePath)}\"").ShouldBe(2);
        xml.ShouldNotContain("<asset id=\"asset2\"");
    }

    /// Source: apostropheInSourcePathPercentEncodesInMediaRep
    [Fact]
    public void ApostropheInSourcePath_PercentEncodesInMediaRep()
    {
        // Resolve's relinker fails on &apos; — the apostrophe must land as %27.
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("sam's clip", dir));
        var clip = ExportFixtures.Clip(id: "c", mediaRef: "sam's clip", start: 0, duration: 30);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);

        var xml = Render(timeline, resolver);
        var mediaRepStart = xml.IndexOf("<media-rep", StringComparison.Ordinal);
        var rep = mediaRepStart >= 0 ? xml[mediaRepStart..xml.IndexOf("/>", mediaRepStart, StringComparison.Ordinal)] : "";

        rep.ShouldContain("%27");
        rep.ShouldNotContain("&apos;");
    }

    /// Source: stillImageEmitsVideoElementWithTransform
    [Fact]
    public void StillImage_EmitsVideoElementWithTransform()
    {
        var dir = ExportFixtures.NewTempDir();
        var entry = ExportFixtures.ImageEntry("broll", dir);
        var resolver = ExportFixtures.ResolverFor(entry);
        var clip = ExportFixtures.Clip(id: "c", mediaRef: "broll", mediaType: ClipType.Image, start: 0, duration: 30);
        clip.Transform = new Transform { CenterX = 0.25, CenterY = 0.75 };
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);

        var xml = Render(timeline, resolver);

        xml.ShouldContain("<video ref=\"asset1\" name=\"broll.png\" lane=\"1\"");
        xml.ShouldNotContain("<ref-clip");
        xml.ShouldNotContain("<media id=");
        xml.ShouldContain("<adjust-transform scale=\"1 1\" anchor=\"0 0\" position=\"-44.4444 -25\"/>");
    }

    /// Source: assetResourcesOmitSyntheticUID
    [Fact]
    public void AssetResources_OmitSyntheticUid()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir));
        var clip = ExportFixtures.Clip(id: "clip", mediaRef: "media-v", start: 0, duration: 30);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);

        var xml = Render(timeline, resolver);
        var asset = Between(xml, "<asset id=\"asset1\"", "</asset>");

        asset.ShouldNotContain("uid=");
        xml.ShouldNotContain("io.palmier.media.asset");
    }

    /// Source: oneSidedAvClipWrapsAssetInFullMediaCompoundClip
    [Fact]
    public void OneSidedAvClip_WrapsAssetInFullMediaCompoundClip()
    {
        // The compound must hold the FULL media (5s), independent of the clip's trim/duration —
        // that runway is what stops Resolve blacking a retimed tail.
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir, hasAudio: true));
        var clip = ExportFixtures.Clip(id: "c", mediaRef: "media-v", start: 0, duration: 30, trimStart: 20);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);

        var xml = Render(timeline, resolver);
        var compound = Between(xml, "<media id=\"media1\"", "</media>");

        compound.ShouldContain("<sequence format=\"r2\" duration=\"5s\"");
        compound.ShouldContain("<asset-clip ref=\"asset1\" name=\"media-v.mp4\" duration=\"5s\" start=\"0s\" offset=\"0s\" format=\"r2\"/>");
        xml.ShouldContain("<ref-clip ref=\"media1\"");
        xml.ShouldContain("srcEnable=\"video\"");
        xml.ShouldContain("<adjust-conform type=\"fit\"/>");
    }

    /// Source: audiolessVideoEmitsFlatAssetClipWithoutCompound
    [Fact]
    public void AudiolessVideo_EmitsFlatAssetClipWithoutCompound()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir));
        var clip = ExportFixtures.Clip(id: "c", mediaRef: "media-v", start: 0, duration: 30, trimStart: 20);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);

        var xml = Render(timeline, resolver);

        xml.ShouldNotContain("<media id=");
        xml.ShouldNotContain("<ref-clip");
        xml.ShouldContain("<asset-clip ref=\"asset1\" name=\"media-v.mp4\" lane=\"1\"");
        xml.ShouldContain("<adjust-conform type=\"fit\"/>");
    }

    /// Source: sameMediaRefVideoAndAudioShareOneAsset
    [Fact]
    public void SameMediaRef_VideoAndAudio_ShareOneAsset()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir, hasAudio: true));
        var video = ExportFixtures.Clip(id: "video", mediaRef: "media-v", mediaType: ClipType.Video, start: 0, duration: 30);
        var audio = ExportFixtures.Clip(id: "audio", mediaRef: "media-v", mediaType: ClipType.Audio, start: 0, duration: 30);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(video), ExportFixtures.AudioTrack(audio)]);

        var xml = Render(timeline, resolver);

        xml.ShouldNotContain("<asset id=\"asset2\"");
        var asset = Between(xml, "<asset id=\"asset1\"", "</asset>");
        asset.ShouldContain("hasVideo=\"1\"");
        asset.ShouldContain("format=\"r2\"");
        asset.ShouldContain("videoSources=\"1\"");
        asset.ShouldContain("hasAudio=\"1\"");
        asset.ShouldContain("audioSources=\"1\"");
        asset.ShouldContain("audioChannels=\"2\"");
        asset.ShouldContain("audioRate=\"48000\"");
        xml.ShouldContain("<ref-clip ref=\"media1\" name=\"media-v.mp4\" lane=\"1\"");
        xml.ShouldContain("srcEnable=\"video\"");
        xml.ShouldContain("<ref-clip ref=\"media1\" name=\"media-v.mp4\" lane=\"-1\"");
        xml.ShouldContain("srcEnable=\"audio\"");
    }

    /// Source: linkedAvPairCollapsesToOneFlatAssetClip
    [Fact]
    public void LinkedAvPair_CollapsesToOneFlatAssetClip()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir, hasAudio: true));
        var video = ExportFixtures.Clip(id: "video", mediaRef: "media-v", mediaType: ClipType.Video, start: 0, duration: 30);
        var audio = ExportFixtures.Clip(id: "audio", mediaRef: "media-v", mediaType: ClipType.Audio, start: 0, duration: 30, volume: 0.5);
        video.LinkGroupId = "pair";
        audio.LinkGroupId = "pair";
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(video), ExportFixtures.AudioTrack(audio)]);

        var xml = Render(timeline, resolver);

        xml.ShouldContain("<asset-clip ref=\"asset1\" name=\"media-v.mp4\" lane=\"1\"");
        xml.ShouldNotContain("<ref-clip");
        xml.ShouldNotContain("<media id=");
        xml.ShouldNotContain("lane=\"-1\"");
        xml.ShouldNotContain("srcEnable=");
        xml.ShouldContain("<adjust-volume amount=\"-6.0206\"/>");
    }

    /// Source: mutedAudioTrackKeepsLinkedPairSeparate
    [Fact]
    public void MutedAudioTrack_KeepsLinkedPairSeparate()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir, hasAudio: true));
        var video = ExportFixtures.Clip(id: "video", mediaRef: "media-v", mediaType: ClipType.Video, start: 0, duration: 30);
        var audio = ExportFixtures.Clip(id: "audio", mediaRef: "media-v", mediaType: ClipType.Audio, start: 0, duration: 30);
        video.LinkGroupId = "pair";
        audio.LinkGroupId = "pair";
        var audioTrack = ExportFixtures.AudioTrack(audio);
        audioTrack.Muted = true;
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(video), audioTrack]);

        var xml = Render(timeline, resolver);

        xml.ShouldContain("<ref-clip ref=\"media1\" name=\"media-v.mp4\" lane=\"1\"");
        xml.ShouldContain("srcEnable=\"video\"");
        xml.ShouldContain("<ref-clip ref=\"media1\" name=\"media-v.mp4\" lane=\"-1\"");
        xml.ShouldContain("srcEnable=\"audio\"");
        xml.ShouldContain("enabled=\"0\"");
    }

    /// Source: visualTrackLanesPreserveTopOverBottom
    [Fact]
    public void VisualTrackLanes_PreserveTopOverBottom()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir));
        var top = ExportFixtures.Clip(id: "top", mediaRef: "media-v", start: 0, duration: 30);
        var bottom = ExportFixtures.Clip(id: "bottom", mediaRef: "media-v", start: 0, duration: 30);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(top), ExportFixtures.VideoTrack(bottom)]);

        var xml = Render(timeline, resolver);

        xml.ShouldContain("name=\"media-v.mp4\" lane=\"2\" offset=\"0s\"");
        xml.ShouldContain("name=\"media-v.mp4\" lane=\"1\" offset=\"0s\"");
    }

    // MARK: - Timing & speed

    /// Source: videoClipEmitsFlatAssetClipWithOffsetStartAndDuration
    [Fact]
    public void VideoClip_EmitsFlatAssetClipWithOffsetStartAndDuration()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir));
        var clip = ExportFixtures.Clip(id: "clip-1", mediaRef: "media-v", start: 30, duration: 60, trimStart: 10);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);

        var xml = Render(timeline, resolver);

        // Unspeeded: start is the raw source in-point (trimStart 10 / 30fps = 1/3s), no timeMap.
        xml.ShouldContain("<asset-clip ref=\"asset1\" name=\"media-v.mp4\" lane=\"1\"");
        xml.ShouldContain("offset=\"1s\"");
        xml.ShouldContain("start=\"1/3s\"");
        xml.ShouldContain("duration=\"2s\"");
        xml.ShouldNotContain("<timeMap");
    }

    /// Source: speedChangeEmitsWholeMediaTimeMap
    [Fact]
    public void SpeedChange_EmitsWholeMediaTimeMap()
    {
        // 5s media @ 30fps = 150 source frames; 2× speed-up, trimStart 10, 60-frame output.
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir));
        var clip = ExportFixtures.Clip(id: "fast", mediaRef: "media-v", start: 0, duration: 60, trimStart: 10, speed: 2.0);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);

        var xml = Render(timeline, resolver);

        // start is in the OUTPUT axis (source-in 10 ÷ speed 2 = 5 frames = 1/6s); the timeMap
        // describes the WHOLE media retimed (output 150/2=75f=5/2s → source 150f=5s), windowed by
        // start/duration.
        xml.ShouldContain("offset=\"0s\" start=\"1/6s\" duration=\"2s\"");
        xml.ShouldContain("<timeMap frameSampling=\"floor\">");
        xml.ShouldContain("<timept time=\"0s\" value=\"0s\" interp=\"linear\"/>");
        xml.ShouldContain("<timept time=\"5/2s\" value=\"5s\" interp=\"linear\"/>");
    }

    /// Source: slowMotionEmitsWholeMediaTimeMap
    [Fact]
    public void SlowMotion_EmitsWholeMediaTimeMap()
    {
        // 0.5× slow-mo: the whole-media ramp's output axis is LONGER than the source. Exercises
        // the speed < 1 (p<q) path.
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir));
        var clip = ExportFixtures.Clip(id: "slow", mediaRef: "media-v", start: 0, duration: 60, trimStart: 30, speed: 0.5);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);

        var xml = Render(timeline, resolver);

        // start = 30 ÷ 0.5 = 60 output frames = 2s; ramp output 150/0.5=300f=10s → source 150f=5s.
        xml.ShouldContain("start=\"2s\"");
        xml.ShouldContain("<timept time=\"10s\" value=\"5s\" interp=\"linear\"/>");
    }

    /// Source: retimedKeyframeTimeIsOffsetByStart
    [Fact]
    public void RetimedKeyframeTime_IsOffsetByStart()
    {
        // Resolve measures param keyframe time from the timeMap origin, so it's offset by the
        // clip's output-axis start (trimStart ÷ speed), not zero-based. 5s media @30fps, 2× speed.
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir));
        var clip = ExportFixtures.Clip(id: "z", mediaRef: "media-v", start: 0, duration: 60, trimStart: 10, speed: 2.0);
        clip.ScaleTrack = new KeyframeTrack<AnimPair>([
            new Keyframe<AnimPair>(0, new AnimPair(0.5, 0.5), Interpolation.Linear),
            new Keyframe<AnimPair>(15, new AnimPair(1, 1), Interpolation.Linear),
        ]);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);

        var xml = Render(timeline, resolver);

        // start = 10/(2×30) = 1/6s; first keyframe sits AT start, second 15 output frames later
        // (1/6+1/2=2/3s).
        xml.ShouldContain("start=\"1/6s\"");
        xml.ShouldContain("<keyframe time=\"1/6s\"");
        xml.ShouldContain("<keyframe time=\"2/3s\"");
    }

    // MARK: - Source timecode

    /// Source: embeddedTimecodeConvertsToTimelineFrames
    [Fact]
    public void EmbeddedTimecode_ConvertsToTimelineFrames()
    {
        // 00:00:14:44 @ 50fps → 744 quanta-frames; at a 50fps timeline that's 744/50 = 372/25s.
        var tc = new SourceTimecode(744, 50, false);
        tc.FramesAtFps(50).ShouldBe(744);
        // A 25fps timeline halves it (14.88s → 372 frames).
        tc.FramesAtFps(25).ShouldBe(372);
    }

    /// Source: assetAndCompoundStartCarryEmbeddedTimecode
    [Fact]
    public void AssetAndCompoundStart_CarryEmbeddedTimecode()
    {
        // Regression: for footage with an embedded running timecode, the asset (and the compound's
        // inner clip) must declare it so Resolve doesn't flag a mismatch and offset every trim.
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir, hasAudio: true));
        var clip = ExportFixtures.Clip(id: "c", mediaRef: "media-v", start: 0, duration: 30, trimStart: 10);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);

        // 00:00:14:44 @ 50 quanta = 744; the timeline runs 30fps → 744/50×30 = 446 frames = 223/15s.
        var tc = new SourceTimecode(744, 50, false);
        var xml = Render(timeline, resolver, startTimecodes: new Dictionary<string, SourceTimecode> { ["media-v"] = tc });

        xml.ShouldContain("<asset id=\"asset1\" name=\"media-v.mp4\" start=\"223/15s\"");
        // The compound reads the asset from its timecode origin (offset stays 0 — 0-based spine).
        xml.ShouldContain("start=\"223/15s\" offset=\"0s\"");
        // The outer ref-clip stays 0-based against the compound: trimStart 10 / 30fps = 1/3s.
        xml.ShouldContain("<ref-clip ref=\"media1\" name=\"media-v.mp4\" lane=\"1\" offset=\"0s\" start=\"1/3s\"");
    }

    /// Source: absentTimecodeKeepsZeroBasedStarts
    [Fact]
    public void AbsentTimecode_KeepsZeroBasedStarts()
    {
        // No tmcd track → starts stay 0s, byte-identical to the pre-timecode behavior.
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir, hasAudio: true));
        var clip = ExportFixtures.Clip(id: "c", mediaRef: "media-v", start: 0, duration: 30);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);

        var xml = Render(timeline, resolver);

        xml.ShouldContain("<asset id=\"asset1\" name=\"media-v.mp4\" start=\"0s\"");
    }

    /// New (not a direct Swift port): exercises the `ISourceTimingReader` injection seam end to end
    /// through `FcpxmlExporter.ExportAsync` — the Windows-specific shim `FCPXMLExporter.export`
    /// wires to `SourceTimingReader.timecodes` on the Mac; here a fake stands in so the test never
    /// launches ffprobe.exe.
    [Fact]
    public async Task ExportAsync_ReadsEmbeddedTimecodeThroughInjectedTimingReader()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir, hasAudio: true));
        var clip = ExportFixtures.Clip(id: "c", mediaRef: "media-v", start: 0, duration: 30, trimStart: 10);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);
        var timingReader = new FakeSourceTimingReader(new Dictionary<string, SourceTimecode>
        {
            ["media-v"] = new SourceTimecode(744, 50, false),
        });
        var outPath = Path.Combine(dir, "out.fcpxml");

        await FcpxmlExporter.ExportAsync(timeline, resolver, timingReader, FontResolver, outPath);

        File.Exists(outPath).ShouldBeTrue();
        var xml = File.ReadAllText(outPath);
        xml.ShouldContain("<asset id=\"asset1\" name=\"media-v.mp4\" start=\"223/15s\"");
        Should.NotThrow(() => XDocument.Parse(xml));
    }

    /// Source: unspeededTrimmedKeyframeStaysClipRelative
    [Fact]
    public void UnspeededTrimmedKeyframe_StaysClipRelative()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir));
        var clip = ExportFixtures.Clip(id: "t", mediaRef: "media-v", start: 0, duration: 60, trimStart: 10);
        clip.OpacityTrack = new KeyframeTrack<double>([
            new Keyframe<double>(0, 0.0, Interpolation.Linear),
            new Keyframe<double>(30, 1.0, Interpolation.Linear),
        ]);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);

        var xml = Render(timeline, resolver);

        xml.ShouldNotContain("<timeMap");
        xml.ShouldContain("<keyframe time=\"0s\" curve=\"linear\" value=\"0\"/>");   // not 1/3s
        xml.ShouldContain("<keyframe time=\"1s\" curve=\"linear\" value=\"1\"/>");
    }

    // MARK: - Transform, scale, flip

    /// Source: fittedVideoEmitsNoTransform
    [Fact]
    public void FittedVideo_EmitsNoTransform()
    {
        var dir = ExportFixtures.NewTempDir();
        var entry = ExportFixtures.VideoEntry("media-v", dir, sourceWidth: 3413, sourceHeight: 607);
        var resolver = ExportFixtures.ResolverFor(entry);
        var clip = ExportFixtures.Clip(id: "clip-1", mediaRef: "media-v", start: 0, duration: 60);
        clip.Transform = new Transform { Width = 1, Height = 1920.0 / 1080.0 / (3413.0 / 607.0) };
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);

        var xml = Render(timeline, resolver);

        xml.ShouldContain("<format id=\"r2\" name=\"FFVideoFormat3413x607p30\" frameDuration=\"1/30s\" width=\"3413\" height=\"607\" colorSpace=\"1-1-1 (Rec. 709)\"/>");
        xml.ShouldNotContain("<adjust-transform");
    }

    /// Source: ntscSourceFormatUsesFinalCutRateSuffix
    [Fact]
    public void NtscSourceFormat_UsesFinalCutRateSuffix()
    {
        var dir = ExportFixtures.NewTempDir();
        var entry = ExportFixtures.VideoEntry("media-v", dir);
        entry.SourceFPS = 29.97;
        var resolver = ExportFixtures.ResolverFor(entry);
        var clip = ExportFixtures.Clip(id: "clip-1", mediaRef: "media-v", start: 0, duration: 60);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);

        var xml = Render(timeline, resolver);

        xml.ShouldContain("<format id=\"r2\" name=\"FFVideoFormat1080p2997\" frameDuration=\"1001/30000s\" width=\"1920\" height=\"1080\" colorSpace=\"1-1-1 (Rec. 709)\"/>");
    }

    /// Source: customTimelineFormatUsesFinalCutGenericPresetName
    [Fact]
    public void CustomTimelineFormat_UsesFinalCutGenericPresetName()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir));
        var clip = ExportFixtures.Clip(id: "clip-1", mediaRef: "media-v", start: 0, duration: 60);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);
        timeline.Width = 1080;
        timeline.Height = 1920;

        var xml = Render(timeline, resolver);

        xml.ShouldContain("<format id=\"r1\" name=\"FFVideoFormatRateUndefined\" frameDuration=\"1/30s\" width=\"1080\" height=\"1920\" colorSpace=\"1-1-1 (Rec. 709)\"/>");
        xml.ShouldContain("<sequence format=\"r1\"");
    }

    /// Source: centeredUnrotatedVideoOmitsTransform
    [Fact]
    public void CenteredUnrotatedVideo_OmitsTransform()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir));
        var clip = ExportFixtures.Clip(id: "clip-1", mediaRef: "media-v", start: 0, duration: 60);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);

        var xml = Render(timeline, resolver);

        xml.ShouldNotContain("<adjust-transform");
    }

    /// Source: videoTransformExportsPositionAndRotation
    [Fact]
    public void VideoTransform_ExportsPositionAndRotation()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir));
        var clip = ExportFixtures.Clip(id: "clip-1", mediaRef: "media-v", start: 0, duration: 60);
        clip.Transform = new Transform { CenterX = 0.25, CenterY = 0.75, Rotation = 30 };
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);

        var xml = Render(timeline, resolver);

        // 1080p: x = (0.25-0.5)*1920/10.8 = -44.4444, y = (0.5-0.75)*100 = -25; rotation negated.
        xml.ShouldContain("<adjust-transform scale=\"1 1\" rotation=\"-30\" anchor=\"0 0\" position=\"-44.4444 -25\"/>");
    }

    /// Source: horizontalFlipExportsNegativeScale
    [Fact]
    public void HorizontalFlip_ExportsNegativeScale()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir));
        var clip = ExportFixtures.Clip(id: "clip-1", mediaRef: "media-v", start: 0, duration: 60);
        clip.Transform = new Transform { FlipHorizontal = true };
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);

        var xml = Render(timeline, resolver);

        xml.ShouldContain("<adjust-transform scale=\"-1 1\" anchor=\"0 0\" position=\"0 0\"/>");
    }

    /// Source: scaledVideoExportsScaleRelativeToFit
    [Fact]
    public void ScaledVideo_ExportsScaleRelativeToFit()
    {
        // Mismatched source (ultra-wide) at half its fitted size: the aspect-fit divides out, leaving 0.5×0.5.
        var dir = ExportFixtures.NewTempDir();
        var entry = ExportFixtures.VideoEntry("media-v", dir, sourceWidth: 3413, sourceHeight: 607);
        var resolver = ExportFixtures.ResolverFor(entry);
        var clip = ExportFixtures.Clip(id: "clip-1", mediaRef: "media-v", start: 0, duration: 60);
        var fitHeight = 1920.0 / 1080.0 / (3413.0 / 607.0);
        clip.Transform = new Transform { Width = 0.5, Height = fitHeight * 0.5 };
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);

        var xml = Render(timeline, resolver);

        xml.ShouldContain("<adjust-transform scale=\"0.5 0.5\" anchor=\"0 0\" position=\"0 0\"/>");
    }

    /// Source: matchedAspectScaleExportsFractionDirectly
    [Fact]
    public void MatchedAspectScale_ExportsFractionDirectly()
    {
        // Source aspect == frame aspect → no fit division, scale is the raw fraction.
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir));
        var clip = ExportFixtures.Clip(id: "clip-1", mediaRef: "media-v", start: 0, duration: 60);
        clip.Transform = new Transform { Width = 0.5, Height = 0.5 };
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);

        var xml = Render(timeline, resolver);

        xml.ShouldContain("<adjust-transform scale=\"0.5 0.5\" anchor=\"0 0\" position=\"0 0\"/>");
    }

    /// Source: fittedClipPositionDividesOutConformFit
    [Fact]
    public void FittedClipPosition_DividesOutConformFit()
    {
        // 16:9 in 9:16: fitH = 81/256, so centerY 0.75 → −25×256/81 = −79.0123; x unaffected (fitW 1).
        var dir = ExportFixtures.NewTempDir();
        var entry = ExportFixtures.VideoEntry("media-v", dir, sourceWidth: 1280, sourceHeight: 720);
        var resolver = ExportFixtures.ResolverFor(entry);
        var clip = ExportFixtures.Clip(id: "clip-1", mediaRef: "media-v", start: 0, duration: 60);
        clip.Transform = new Transform { CenterX = 0.75, CenterY = 0.75, Width = 1, Height = 81.0 / 256.0 };
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);
        timeline.Width = 1080;
        timeline.Height = 1920;

        var xml = Render(timeline, resolver);

        xml.ShouldContain("<adjust-transform scale=\"1 1\" anchor=\"0 0\" position=\"14.0625 -79.0123\"/>");
    }

    /// Source: fcpTargetWritesSpecLiteralPositionAndCrop
    [Fact]
    public void FcpTarget_WritesSpecLiteralPositionAndCrop()
    {
        // Final Cut takes the spec at face value: raw percent crop, no conform-fit division.
        var dir = ExportFixtures.NewTempDir();
        var entry = ExportFixtures.VideoEntry("media-v", dir, sourceWidth: 1280, sourceHeight: 720);
        var resolver = ExportFixtures.ResolverFor(entry);
        var clip = ExportFixtures.Clip(id: "clip-1", mediaRef: "media-v", start: 0, duration: 60);
        clip.Transform = new Transform { CenterX = 0.75, CenterY = 0.75, Width = 1, Height = 81.0 / 256.0 };
        clip.Crop = new Crop { Left = 0.2, Top = 0.05, Right = 0.1, Bottom = 0.05 };
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);
        timeline.Width = 1080;
        timeline.Height = 1920;

        var xml = Render(timeline, resolver, target: FcpxmlTarget.Fcp);

        xml.ShouldContain("position=\"14.0625 -25\"");
        xml.ShouldContain("<trim-rect top=\"5\" right=\"10\" bottom=\"5\" left=\"20\"/>");
    }

    /// Source: positionKeyframesExportAsParamAnimation
    [Fact]
    public void PositionKeyframes_ExportAsParamAnimation()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir));
        var clip = ExportFixtures.Clip(id: "clip-1", mediaRef: "media-v", start: 0, duration: 60);
        // positionTrack stores topLeft; with default size 1×1, topLeft (0,b) → center (0.5, b+0.5).
        clip.PositionTrack = new KeyframeTrack<AnimPair>([
            new Keyframe<AnimPair>(0, new AnimPair(0, 0), Interpolation.Linear),
            new Keyframe<AnimPair>(30, new AnimPair(0, 0.25), Interpolation.Linear),
        ]);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);

        var xml = Render(timeline, resolver);

        xml.ShouldContain("<param name=\"position\" value=\"0 0\">");
        xml.ShouldContain("<keyframeAnimation>");
        xml.ShouldContain("<keyframe time=\"0s\" curve=\"linear\" value=\"0 0\"/>");
        xml.ShouldContain("<keyframe time=\"1s\" curve=\"linear\" value=\"0 -25\"/>");
    }

    // MARK: - Crop

    /// Source: cropExportsTrimRectInResolveUnits
    [Fact]
    public void Crop_ExportsTrimRectInResolveUnits()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir));
        var clip = ExportFixtures.Clip(id: "clip-1", mediaRef: "media-v", start: 0, duration: 60);
        clip.Crop = new Crop { Left = 0.1, Top = 0.2, Right = 0.3, Bottom = 0.4 };
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);

        var xml = Render(timeline, resolver);

        xml.ShouldContain("<adjust-crop mode=\"trim\">");
        xml.ShouldContain("<trim-rect top=\"20\" right=\"53.3333\" bottom=\"40\" left=\"17.7778\"/>");
    }

    /// Source: cropOfWideSourceInPortraitSequenceMatchesResolveEncoding
    [Fact]
    public void CropOfWideSourceInPortraitSequence_MatchesResolveEncoding()
    {
        // Byte-matches DaVinci's own export of the identical crop (256/128/36/36 source px).
        var dir = ExportFixtures.NewTempDir();
        var entry = ExportFixtures.VideoEntry("media-v", dir, sourceWidth: 1280, sourceHeight: 720);
        var resolver = ExportFixtures.ResolverFor(entry);
        var clip = ExportFixtures.Clip(id: "clip-1", mediaRef: "media-v", start: 0, duration: 60);
        clip.Crop = new Crop { Left = 0.2, Top = 0.05, Right = 0.1, Bottom = 0.05 };
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);
        timeline.Width = 1080;
        timeline.Height = 1920;

        var xml = Render(timeline, resolver);

        xml.ShouldContain("<trim-rect top=\"5.9259\" right=\"6.6667\" bottom=\"5.9259\" left=\"13.3333\"/>");
    }

    /// Source: identityCropOmitsAdjustCrop
    [Fact]
    public void IdentityCrop_OmitsAdjustCrop()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir));
        var clip = ExportFixtures.Clip(id: "clip-1", mediaRef: "media-v", start: 0, duration: 60);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);

        var xml = Render(timeline, resolver);

        xml.ShouldNotContain("<adjust-crop");
    }

    // MARK: - Opacity

    /// Source: clipOpacityExportsAdjustBlend
    [Fact]
    public void ClipOpacity_ExportsAdjustBlend()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir));
        var clip = ExportFixtures.Clip(id: "clip-1", mediaRef: "media-v", start: 0, duration: 60);
        clip.Opacity = 0.25;
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);

        var xml = Render(timeline, resolver);

        xml.ShouldContain("<adjust-blend amount=\"0.25\"/>");
    }

    /// Source: fullyOpaqueClipOmitsAdjustBlend
    [Fact]
    public void FullyOpaqueClip_OmitsAdjustBlend()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir));
        var clip = ExportFixtures.Clip(id: "clip-1", mediaRef: "media-v", start: 0, duration: 60);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);

        var xml = Render(timeline, resolver);

        xml.ShouldNotContain("<adjust-blend");
    }

    /// Source: opacityKeyframesExportInsideAdjustBlend
    [Fact]
    public void OpacityKeyframes_ExportInsideAdjustBlend()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir));
        var clip = ExportFixtures.Clip(id: "clip-1", mediaRef: "media-v", start: 0, duration: 60);
        clip.OpacityTrack = new KeyframeTrack<double>([
            new Keyframe<double>(0, 0.0, Interpolation.Linear),
            new Keyframe<double>(30, 1.0, Interpolation.Linear),
        ]);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);

        var xml = Render(timeline, resolver);

        xml.ShouldContain("<adjust-blend amount=\"1\">");
        xml.ShouldContain("<param name=\"amount\" value=\"1\">");
        xml.ShouldContain("<keyframe time=\"0s\" curve=\"linear\" value=\"0\"/>");
        xml.ShouldContain("<keyframe time=\"1s\" curve=\"linear\" value=\"1\"/>");
    }

    // MARK: - Volume

    /// Source: reducedVolumeExportsAdjustVolumeInDecibels
    [Fact]
    public void ReducedVolume_ExportsAdjustVolumeInDecibels()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.AudioEntry("media-a", dir));
        var clip = ExportFixtures.Clip(id: "clip-a", mediaRef: "media-a", mediaType: ClipType.Audio, start: 0, duration: 60);
        clip.Volume = 0.5;
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.AudioTrack(clip)]);

        var xml = Render(timeline, resolver);

        xml.ShouldContain("<adjust-volume amount=\"-6.0206\"/>");  // 20*log10(0.5)
    }

    /// Source: unityVolumeOmitsAdjustVolume
    [Fact]
    public void UnityVolume_OmitsAdjustVolume()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.AudioEntry("media-a", dir));
        var clip = ExportFixtures.Clip(id: "clip-a", mediaRef: "media-a", mediaType: ClipType.Audio, start: 0, duration: 60);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.AudioTrack(clip)]);

        var xml = Render(timeline, resolver);

        xml.ShouldNotContain("<adjust-volume");
    }

    /// Source: volumeKeyframesCollapseToStaticLevel
    [Fact]
    public void VolumeKeyframes_CollapseToStaticLevel()
    {
        // DaVinci itself drops keyframed audio volume on FCPXML export, so we emit just the static level.
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.AudioEntry("media-a", dir));
        var clip = ExportFixtures.Clip(id: "clip-a", mediaRef: "media-a", mediaType: ClipType.Audio, start: 0, duration: 60);
        clip.Volume = 0.5;
        clip.VolumeTrack = new KeyframeTrack<double>([
            new Keyframe<double>(0, 0.0, Interpolation.Linear),
            new Keyframe<double>(30, -6.0, Interpolation.Linear),
        ]);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.AudioTrack(clip)]);

        var xml = Render(timeline, resolver);

        xml.ShouldContain("<adjust-volume amount=\"-6.0206\"/>");  // self-closing → no keyframeAnimation
    }

    // MARK: - Deliberately not exported

    /// Source: fadesAndChannelLayoutAreNotExported
    [Fact]
    public void FadesAndChannelLayout_AreNotExported()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.AudioEntry("media-a", dir));
        var audio = ExportFixtures.Clip(id: "audio", mediaRef: "media-a", mediaType: ClipType.Audio, start: 0, duration: 60);
        audio.FadeInFrames = 15;
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.AudioTrack(audio)]);

        var xml = Render(timeline, resolver);

        // Pure audio source → no srcEnable (it has no video stream to disambiguate).
        xml.ShouldContain("<asset-clip ref=\"asset1\"");
        xml.ShouldNotContain("srcEnable=");
        xml.ShouldNotContain("<fadeIn");
        xml.ShouldNotContain("<audio-channel-source");
    }

    // MARK: - Titles

    /// Source: textClipEmitsTitleAndEscapedText
    [Fact]
    public void TextClip_EmitsTitleAndEscapedText()
    {
        var resolver = ExportFixtures.ResolverFor();
        var text = ExportFixtures.Clip(id: "title", mediaRef: "text", mediaType: ClipType.Text, start: 30, duration: 60);
        text.TextContent = "A & B";
        var style = new TextStyle { FontName = "Helvetica", FontSize = 48, IsBold = false, Alignment = TextStyleAlignment.Left };
        text.TextStyle = System.Text.Json.JsonSerializer.SerializeToElement(style);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(text)]);

        var xml = Render(timeline, resolver);

        xml.ShouldContain("<effect id=\"titleBasic\"");
        xml.ShouldContain("<title ref=\"titleBasic\" name=\"A &amp; B\"");
        xml.ShouldContain("<text-style ref=\"textStyle1\">A &amp; B</text-style>");
        xml.ShouldContain("font=\"Helvetica\"");
        xml.ShouldContain("fontFace=\"Regular\"");
        xml.ShouldContain("fontSize=\"48\"");
        xml.ShouldContain("alignment=\"left\"");
    }

    /// Source: postScriptFontNameExportsFamilyAndFaceForResolveTitles
    [Fact]
    public void PostScriptFontName_ExportsFamilyAndFaceForResolveTitles()
    {
        var resolver = ExportFixtures.ResolverFor();
        var text = ExportFixtures.Clip(id: "title", mediaRef: "text", mediaType: ClipType.Text, start: 0, duration: 60);
        text.TextContent = "Caption";
        var style = new TextStyle { FontName = "Helvetica-Bold" };
        text.TextStyle = System.Text.Json.JsonSerializer.SerializeToElement(style);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(text)]);

        var xml = Render(timeline, resolver);

        xml.ShouldContain("font=\"Helvetica\"");
        xml.ShouldContain("fontFace=\"Bold\"");
    }

    /// Source: explicitFontTraitsOverridePostScriptFontFaceForResolveTitles
    [Fact]
    public void ExplicitFontTraits_OverridePostScriptFontFaceForResolveTitles()
    {
        var resolver = ExportFixtures.ResolverFor();
        var text = ExportFixtures.Clip(id: "title", mediaRef: "text", mediaType: ClipType.Text, start: 0, duration: 60);
        text.TextContent = "Caption";
        var style = new TextStyle { FontName = "Helvetica-Bold", IsBold = false, IsItalic = false };
        text.TextStyle = System.Text.Json.JsonSerializer.SerializeToElement(style);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(text)]);

        var xml = Render(timeline, resolver);

        xml.ShouldContain("font=\"Helvetica\"");
        xml.ShouldContain("fontFace=\"Regular\"");
    }

    /// Source: textBorderExportsStrokeColorAndWidth
    [Fact]
    public void TextBorder_ExportsStrokeColorAndWidth()
    {
        var resolver = ExportFixtures.ResolverFor();
        var text = ExportFixtures.Clip(id: "title", mediaRef: "text", mediaType: ClipType.Text, start: 0, duration: 60);
        text.TextContent = "HOOK";
        var style = new TextStyle
        {
            FontSize = 96,
            Border = new TextStyleFill(true, new TextStyleRgba(0, 0, 0, 1)),
        };
        text.TextStyle = System.Text.Json.JsonSerializer.SerializeToElement(style);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(text)]);

        var xml = Render(timeline, resolver);

        // 4% of the 96pt font (NSAttributedString's stroke convention) = 3.84pt.
        xml.ShouldContain("strokeColor=\"0 0 0 1\"");
        xml.ShouldContain("strokeWidth=\"3.84\"");
    }

    /// Source: disabledBorderOmitsStroke
    [Fact]
    public void DisabledBorder_OmitsStroke()
    {
        var resolver = ExportFixtures.ResolverFor();
        var text = ExportFixtures.Clip(id: "title", mediaRef: "text", mediaType: ClipType.Text, start: 0, duration: 60);
        text.TextContent = "HOOK";
        text.TextStyle = System.Text.Json.JsonSerializer.SerializeToElement(new TextStyle());
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(text)]);

        var xml = Render(timeline, resolver);

        xml.ShouldNotContain("strokeColor=");
        xml.ShouldNotContain("strokeWidth=");
    }

    /// Source: titleFontSizeDoesNotScaleWithSequenceHeight
    [Fact]
    public void TitleFontSize_DoesNotScaleWithSequenceHeight()
    {
        var resolver = ExportFixtures.ResolverFor();
        var text = ExportFixtures.Clip(id: "title", mediaRef: "text", mediaType: ClipType.Text, start: 0, duration: 60);
        text.TextContent = "Caption";
        text.TextStyle = System.Text.Json.JsonSerializer.SerializeToElement(new TextStyle { FontSize = 48 });
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(text)]);
        timeline.Width = 720;
        timeline.Height = 1280;

        var xml = Render(timeline, resolver);

        xml.ShouldContain("fontSize=\"48\"");
        xml.ShouldContain("<adjust-transform scale=\"1 1\" anchor=\"0 0\" position=\"0 0\"/>");
    }

    /// Source: textBoxTransformExportsTitlePositionAndOpacity
    [Fact]
    public void TextBoxTransform_ExportsTitlePositionAndOpacity()
    {
        var resolver = ExportFixtures.ResolverFor();
        var text = ExportFixtures.Clip(id: "title", mediaRef: "text", mediaType: ClipType.Text, start: 0, duration: 60);
        text.TextContent = "Caption";
        text.Opacity = 0.5;
        text.Transform = new Transform { CenterX = 0.25, CenterY = 0.75, Width = 0.2, Height = 0.1, Rotation = 15 };
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(text)]);

        var xml = Render(timeline, resolver);

        xml.ShouldContain("<title ref=\"titleBasic\" name=\"Caption\"");
        xml.ShouldContain("<text-style ref=\"textStyle1\">Caption</text-style>");
        xml.ShouldContain("<adjust-conform type=\"fit\"/>");
        xml.ShouldContain("<adjust-transform scale=\"1 1\" anchor=\"0 0\" position=\"-44.4444 -25\"/>");
        xml.ShouldNotContain("<param name=\"Position\"");
        xml.ShouldContain("<adjust-blend amount=\"0.5\"/>");
    }

    // MARK: - Nested timelines

    /// Source: nestEmitsCompoundResourceAndRefClip (FCPXMLNestExportTests)
    [Fact]
    public void Nest_EmitsCompoundResourceAndRefClip()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("v1", dir));
        var child = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(ExportFixtures.Clip(mediaRef: "v1", start: 0, duration: 60))]);
        child.Name = "Intro";
        var parent = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(ExportFixtures.NestCarrier(child, 30))]);
        var byId = new Dictionary<string, Timeline> { [child.Id] = child, [parent.Id] = parent };

        var xml = Render(parent, resolver, resolveTimeline: id => byId.GetValueOrDefault(id));

        xml.ShouldContain("<media id=\"nest1\" name=\"Intro\">");
        xml.ShouldContain("<ref-clip ref=\"nest1\"");
        var refClipLine = xml.Split('\n').FirstOrDefault(l => l.Contains("<ref-clip ref=\"nest1\"")) ?? "";
        refClipLine.ShouldContain("srcEnable=\"video\"");
        refClipLine.ShouldContain("offset=\"1s\"");
        refClipLine.ShouldContain("duration=\"2s\"");
        xml.ShouldContain("<asset-clip ref=\"asset1\"");
    }

    /// Source: linkedCarrierPairCollapsesIntoOneRefClip (FCPXMLNestExportTests)
    [Fact]
    public void LinkedCarrierPair_CollapsesIntoOneRefClip()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("v1", dir, hasAudio: true));
        var child = ExportFixtures.Timeline(tracks:
        [
            ExportFixtures.VideoTrack(ExportFixtures.Clip(mediaRef: "v1", start: 0, duration: 60)),
            ExportFixtures.AudioTrack(ExportFixtures.Clip(mediaRef: "v1", mediaType: ClipType.Audio, start: 0, duration: 60)),
        ]);
        var video = ExportFixtures.NestCarrier(child, 0);
        var audio = ExportFixtures.Clip(mediaRef: child.Id, mediaType: ClipType.Audio, start: 0, duration: 60);
        audio.SourceClipType = ClipType.Sequence;
        video.LinkGroupId = "g1";
        audio.LinkGroupId = "g1";
        var parent = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(video), ExportFixtures.AudioTrack(audio)]);
        var byId = new Dictionary<string, Timeline> { [child.Id] = child, [parent.Id] = parent };

        var xml = Render(parent, resolver, resolveTimeline: id => byId.GetValueOrDefault(id));

        Count(xml, "<ref-clip ref=\"nest1\"").ShouldBe(1);
        var refClipLine = xml.Split('\n').FirstOrDefault(l => l.Contains("<ref-clip ref=\"nest1\"")) ?? "";
        refClipLine.ShouldNotContain("srcEnable");
    }

    /// Source: twoLevelNestingEmitsBothCompounds (FCPXMLNestExportTests)
    [Fact]
    public void TwoLevelNesting_EmitsBothCompounds()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("v1", dir));
        var grandchild = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(ExportFixtures.Clip(mediaRef: "v1", start: 0, duration: 30))]);
        grandchild.Name = "Deep";
        var child = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(ExportFixtures.NestCarrier(grandchild, 0))]);
        var parent = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(ExportFixtures.NestCarrier(child, 0))]);
        var byId = new Dictionary<string, Timeline> { [grandchild.Id] = grandchild, [child.Id] = child, [parent.Id] = parent };

        var xml = Render(parent, resolver, resolveTimeline: id => byId.GetValueOrDefault(id));

        xml.ShouldContain("<media id=\"nest1\"");
        xml.ShouldContain("<media id=\"nest2\" name=\"Deep\">");
        xml.ShouldContain("<ref-clip ref=\"nest2\"");
    }

    /// Source: frozenCarrierClampsToChildContent (FCPXMLNestExportTests)
    [Fact]
    public void FrozenCarrier_ClampsToChildContent()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("v1", dir));
        var child = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(ExportFixtures.Clip(mediaRef: "v1", start: 0, duration: 60))]);
        var parent = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(ExportFixtures.NestCarrier(child, 0, duration: 100, trimStart: 10))]);
        var byId = new Dictionary<string, Timeline> { [child.Id] = child, [parent.Id] = parent };

        var xml = Render(parent, resolver, resolveTimeline: id => byId.GetValueOrDefault(id));

        var refClipLine = xml.Split('\n').FirstOrDefault(l => l.Contains("<ref-clip ref=\"nest1\"")) ?? "";
        refClipLine.ShouldContain("start=\"1/3s\"");
        refClipLine.ShouldContain("duration=\"5/3s\"");
    }

    /// Source: emptyOrMissingChildDropsCarrier (FCPXMLNestExportTests)
    [Fact]
    public void EmptyOrMissingChild_DropsCarrier()
    {
        var resolver = ExportFixtures.ResolverFor();
        var empty = ExportFixtures.Timeline();
        var missingCarrier = ExportFixtures.Clip(mediaRef: "no-such-timeline", start: 60, duration: 30);
        missingCarrier.MediaType = ClipType.Sequence;
        missingCarrier.SourceClipType = ClipType.Sequence;
        var parent = ExportFixtures.Timeline(tracks:
        [
            ExportFixtures.VideoTrack(ExportFixtures.NestCarrier(empty, 0, duration: 30), missingCarrier),
        ]);
        var byId = new Dictionary<string, Timeline> { [empty.Id] = empty, [parent.Id] = parent };

        var xml = Render(parent, resolver, resolveTimeline: id => byId.GetValueOrDefault(id));

        xml.ShouldNotContain("<media id=\"nest");
        xml.ShouldNotContain("<ref-clip");
    }

    private static int Count(string haystack, string needle)
    {
        var count = 0;
        var index = 0;
        while ((index = haystack.IndexOf(needle, index, StringComparison.Ordinal)) >= 0)
        {
            count += 1;
            index += needle.Length;
        }
        return count;
    }

    private static string Between(string haystack, string startMarker, string endMarker)
    {
        var start = haystack.IndexOf(startMarker, StringComparison.Ordinal);
        if (start < 0)
        {
            return "";
        }
        var end = haystack.IndexOf(endMarker, start, StringComparison.Ordinal);
        return end < 0 ? "" : haystack[start..end];
    }
}
