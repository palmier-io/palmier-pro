using System.Xml.Linq;
using PalmierPro.Core.Export;
using PalmierPro.Core.Models;
using PalmierPro.Services.Export;
using Shouldly;
using Xunit;

namespace PalmierPro.Services.Tests.Export;

/// Ported from Tests/PalmierProTests/Export/XMLExporterTests.swift and
/// XMLExporterTimecodeTests.swift. Each test names its source Swift test.
public class XmemlExporterTests
{
    // MARK: - Header / sequence shell

    /// Source: headerHasXmemlVersionAndSequenceShell
    [Fact]
    public void Header_HasXmemlVersionAndSequenceShell()
    {
        var timeline = ExportFixtures.Timeline();
        var resolver = ExportFixtures.ResolverFor();

        var xml = XmemlExporter.Render(timeline, resolver);

        xml.ShouldStartWith("<?xml version=\"1.0\" encoding=\"UTF-8\"?>");
        xml.ShouldContain("<xmeml version=\"4\">");
        xml.ShouldContain("<sequence id=\"sequence-1\">");
        xml.ShouldContain("<timebase>30</timebase>");
        xml.ShouldContain("<width>1920</width>");
        xml.ShouldContain("<height>1080</height>");
        xml.ShouldContain("</xmeml>");
        Should.NotThrow(() => XDocument.Parse(xml));
    }

    /// Source: exportThrowsWhenDestinationIsUnwritable
    [Fact]
    public async Task ExportAsync_ThrowsWhenDestinationIsUnwritable()
    {
        var timeline = ExportFixtures.Timeline();
        var resolver = ExportFixtures.ResolverFor();
        var dir = ExportFixtures.NewTempDir();
        var unwritable = Path.Combine(dir, "does-not-exist", "out.xml");
        var timingReader = new FakeSourceTimingReader(new Dictionary<string, SourceTimecode>());

        await Should.ThrowAsync<Exception>(() => XmemlExporter.ExportAsync(timeline, resolver, timingReader, unwritable));
        File.Exists(unwritable).ShouldBeFalse();
    }

    /// Source: headerReportsTimelineFpsAndCanvasDimensions
    [Fact]
    public void Header_ReportsTimelineFpsAndCanvasDimensions()
    {
        var timeline = ExportFixtures.Timeline(fps: 24);
        timeline.Width = 1280;
        timeline.Height = 720;
        var resolver = ExportFixtures.ResolverFor();

        var xml = XmemlExporter.Render(timeline, resolver);

        xml.ShouldContain("<timebase>24</timebase>");
        xml.ShouldContain("<width>1280</width>");
        xml.ShouldContain("<height>720</height>");
    }

    /// Source: emptyTimelineProducesZeroDuration
    [Fact]
    public void EmptyTimeline_ProducesZeroDuration()
    {
        var timeline = ExportFixtures.Timeline();
        var resolver = ExportFixtures.ResolverFor();

        var xml = XmemlExporter.Render(timeline, resolver);

        xml.ShouldContain("<duration>0</duration>");
    }

    // MARK: - Clip emission

    /// Source: videoClipEmitsClipitemWithStartAndEnd
    [Fact]
    public void VideoClip_EmitsClipitemWithStartAndEnd()
    {
        var dir = ExportFixtures.NewTempDir();
        var entry = new MediaManifestEntry("media-video", "MyVideo", ClipType.Video, MediaSource.External(Path.Combine(dir, "video.mp4")), 5.0);
        var resolver = ExportFixtures.ResolverFor(entry);
        var clip = ExportFixtures.Clip(id: "clip-1", mediaRef: "media-video", start: 30, duration: 60);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);

        var xml = XmemlExporter.Render(timeline, resolver);

        xml.ShouldContain("<clipitem id=\"clipitem-clip-1\">");
        xml.ShouldContain("<name>MyVideo</name>");
        xml.ShouldContain("<start>30</start>");
        xml.ShouldContain("<end>90</end>"); // 30 + 60
    }

    /// Source: clipsReferencingUnresolvableMediaAreSkipped
    [Fact]
    public void Clips_ReferencingUnresolvableMedia_AreSkipped()
    {
        var resolver = ExportFixtures.ResolverFor();
        var clip = ExportFixtures.Clip(id: "ghost-clip", mediaRef: "missing-media", start: 0, duration: 30);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);

        var xml = XmemlExporter.Render(timeline, resolver);

        xml.ShouldNotContain("ghost-clip");
        xml.ShouldNotContain("clipitem");
    }

    /// Source: repeatedMediaRefEmitsFileOnceThenReferences
    [Fact]
    public void RepeatedMediaRef_EmitsFileOnceThenReferences()
    {
        var dir = ExportFixtures.NewTempDir();
        var entry = new MediaManifestEntry("shared-media", "Shared", ClipType.Video, MediaSource.External(Path.Combine(dir, "video.mp4")), 10.0);
        var resolver = ExportFixtures.ResolverFor(entry);
        var clip1 = ExportFixtures.Clip(id: "c1", mediaRef: "shared-media", start: 0, duration: 30);
        var clip2 = ExportFixtures.Clip(id: "c2", mediaRef: "shared-media", start: 60, duration: 30);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip1, clip2)]);

        var xml = XmemlExporter.Render(timeline, resolver);

        var fileOpenCount = Count(xml, "<file id=\"file-shared-media-video\">");
        var fileSelfCloseCount = Count(xml, "<file id=\"file-shared-media-video\"/>");
        fileOpenCount.ShouldBe(1);
        fileSelfCloseCount.ShouldBe(1);
    }

    // MARK: - Audio clips

    /// Source: audioClipAppearsInAudioSectionOnly
    [Fact]
    public void AudioClip_AppearsInAudioSectionOnly()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.AudioEntry("media-a", dir));
        var clip = ExportFixtures.Clip(id: "audio-clip", mediaRef: "media-a", mediaType: ClipType.Audio, start: 0, duration: 30);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.AudioTrack(clip)]);

        var xml = XmemlExporter.Render(timeline, resolver);

        var audioSecStart = xml.IndexOf("<audio>", StringComparison.Ordinal);
        var videoSecUpperBound = xml.IndexOf("<video>", StringComparison.Ordinal) + "<video>".Length;
        audioSecStart.ShouldBeGreaterThanOrEqualTo(0);
        var clipIndex = xml.IndexOf("audio-clip", StringComparison.Ordinal);
        clipIndex.ShouldBeGreaterThan(audioSecStart);
        clipIndex.ShouldBeGreaterThan(videoSecUpperBound); // audio clipitem must not leak into the video section
    }

    // MARK: - Links

    /// Source: linkedClipsEmitCrossReferences
    [Fact]
    public void LinkedClips_EmitCrossReferences()
    {
        var dir = ExportFixtures.NewTempDir();
        var videoEntry = new MediaManifestEntry("media-v", "v", ClipType.Video, MediaSource.External(Path.Combine(dir, "v.mp4")), 1);
        var audioEntry = new MediaManifestEntry("media-a", "a", ClipType.Audio, MediaSource.External(Path.Combine(dir, "a.m4a")), 1);
        var resolver = ExportFixtures.ResolverFor(videoEntry, audioEntry);
        var videoClip = ExportFixtures.Clip(id: "vc", mediaRef: "media-v", mediaType: ClipType.Video, start: 0, duration: 30);
        var audioClip = ExportFixtures.Clip(id: "ac", mediaRef: "media-a", mediaType: ClipType.Audio, start: 0, duration: 30);
        videoClip.LinkGroupId = "group-1";
        audioClip.LinkGroupId = "group-1";
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(videoClip), ExportFixtures.AudioTrack(audioClip)]);

        var xml = XmemlExporter.Render(timeline, resolver);

        xml.ShouldContain("<linkclipref>clipitem-vc</linkclipref>");
        xml.ShouldContain("<linkclipref>clipitem-ac</linkclipref>");
        xml.ShouldContain("<mediatype>video</mediatype>");
        xml.ShouldContain("<mediatype>audio</mediatype>");
    }

    /// Source: unlinkedClipsEmitNoLinkBlocks
    [Fact]
    public void UnlinkedClips_EmitNoLinkBlocks()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir));
        var clip = ExportFixtures.Clip(id: "lone", mediaRef: "media-v", start: 0, duration: 30);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);

        var xml = XmemlExporter.Render(timeline, resolver);

        xml.ShouldNotContain("<link>");
        xml.ShouldNotContain("<linkclipref>");
    }

    // MARK: - Escaping

    /// Source: specialCharsInClipNameAreXMLEscaped
    [Fact]
    public void SpecialCharsInClipName_AreXmlEscaped()
    {
        var dir = ExportFixtures.NewTempDir();
        var entry = new MediaManifestEntry("media-v", "A & B < C > \"D\" 'E'", ClipType.Video, MediaSource.External(Path.Combine(dir, "v.mp4")), 1);
        var resolver = ExportFixtures.ResolverFor(entry);
        var clip = ExportFixtures.Clip(id: "c1", mediaRef: "media-v", start: 0, duration: 30);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);

        var xml = XmemlExporter.Render(timeline, resolver);

        xml.ShouldContain("A &amp; B &lt; C &gt; &quot;D&quot; &apos;E&apos;");
        xml.ShouldNotContain("A & B");
    }

    // MARK: - Filters

    /// Source: speedNotOneEmitsTimeRemapFilter
    [Fact]
    public void SpeedNotOne_EmitsTimeRemapFilter()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir));
        var clip = ExportFixtures.Clip(id: "c1", mediaRef: "media-v", start: 0, duration: 60, speed: 2.0);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);

        var xml = XmemlExporter.Render(timeline, resolver);

        xml.ShouldContain("<effectid>timeremap</effectid>");
        xml.ShouldContain("<value>200.0000</value>");
    }

    /// Source: speedOneEmitsNoTimeRemapFilter
    [Fact]
    public void SpeedOne_EmitsNoTimeRemapFilter()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir));
        var clip = ExportFixtures.Clip(id: "c1", mediaRef: "media-v", start: 0, duration: 60, speed: 1.0);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);

        var xml = XmemlExporter.Render(timeline, resolver);

        xml.ShouldNotContain("timeremap");
    }

    /// Source: volumeNotOneEmitsAudioLevelsFilter
    [Fact]
    public void VolumeNotOne_EmitsAudioLevelsFilter()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.AudioEntry("media-a", dir));
        var clip = ExportFixtures.Clip(id: "c1", mediaRef: "media-a", mediaType: ClipType.Audio, start: 0, duration: 60, volume: 0.5);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.AudioTrack(clip)]);

        var xml = XmemlExporter.Render(timeline, resolver);

        xml.ShouldContain("<effectid>audiolevels</effectid>");
        xml.ShouldContain("<value>0.5000</value>");
    }

    /// Source: volumeAtUnityEmitsNoAudioLevelsFilter
    [Fact]
    public void VolumeAtUnity_EmitsNoAudioLevelsFilter()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.AudioEntry("media-a", dir));
        var clip = ExportFixtures.Clip(id: "c1", mediaRef: "media-a", mediaType: ClipType.Audio, start: 0, duration: 60, volume: 1.0);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.AudioTrack(clip)]);

        var xml = XmemlExporter.Render(timeline, resolver);

        xml.ShouldNotContain("audiolevels");
    }

    /// Source: opacityNotOneEmitsDedicatedOpacityEffect
    [Fact]
    public void OpacityNotOne_EmitsDedicatedOpacityEffect()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir));
        var clip = ExportFixtures.Clip(id: "c1", mediaRef: "media-v", start: 0, duration: 30);
        clip.Opacity = 0.5;
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);

        var xml = XmemlExporter.Render(timeline, resolver);

        xml.ShouldContain("<effectid>opacity</effectid>");
        xml.ShouldContain("<parameterid>opacity</parameterid>");
        xml.ShouldContain("<value>50.0</value>");
    }

    /// Source: nonDefaultTransformEmitsMotionFilterWithMatchingParams
    [Fact]
    public void NonDefaultTransform_EmitsMotionFilterWithMatchingParams()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir));
        var clip = ExportFixtures.Clip(id: "c1", mediaRef: "media-v", start: 0, duration: 30);
        clip.Transform = new Transform { CenterX = 0.6, CenterY = 0.4, Width = 0.5, Height = 0.5, Rotation = 45 };
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);

        var xml = XmemlExporter.Render(timeline, resolver);

        xml.ShouldContain("<effectid>basic</effectid>");
        xml.ShouldContain("<parameterid>scale</parameterid>");
        xml.ShouldContain("<parameterid>rotation</parameterid>");
        xml.ShouldContain("<parameterid>center</parameterid>");
        xml.ShouldContain("<value>-45.00</value>");
        xml.ShouldContain("<value>50.00</value>");
    }

    /// Source: defaultClipEmitsNoMotionFilter
    [Fact]
    public void DefaultClip_EmitsNoMotionFilter()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir));
        var clip = ExportFixtures.Clip(id: "c1", mediaRef: "media-v", start: 0, duration: 30);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);

        var xml = XmemlExporter.Render(timeline, resolver);

        xml.ShouldNotContain("<effectid>basic</effectid>");
    }

    // MARK: - Text clips

    /// Source: textClipsAreNotEmitted
    [Fact]
    public void TextClips_AreNotEmitted()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir));
        var videoClip = ExportFixtures.Clip(id: "vc", mediaRef: "media-v", start: 0, duration: 30);
        var textClip = ExportFixtures.Clip(id: "tc", mediaRef: "text-no-manifest", mediaType: ClipType.Text, start: 0, duration: 30);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(videoClip, textClip)]);

        var xml = XmemlExporter.Render(timeline, resolver);

        xml.ShouldNotContain("clipitem-tc");
        xml.ShouldContain("clipitem-vc");
    }

    // MARK: - Track enabled state

    /// Source: mutedAudioTrackEmitsEnabledFalse
    [Fact]
    public void MutedAudioTrack_EmitsEnabledFalse()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.AudioEntry("media-a", dir));
        var track = ExportFixtures.AudioTrack(ExportFixtures.Clip(id: "ac", mediaRef: "media-a", mediaType: ClipType.Audio, start: 0, duration: 30));
        track.Muted = true;
        var timeline = ExportFixtures.Timeline(tracks: [track]);

        var xml = XmemlExporter.Render(timeline, resolver);

        var audioStart = xml.IndexOf("<audio>", StringComparison.Ordinal);
        audioStart.ShouldBeGreaterThanOrEqualTo(0);
        xml[audioStart..].ShouldContain("<enabled>FALSE</enabled>");
    }

    /// Source: hiddenVideoTrackEmitsEnabledFalse
    [Fact]
    public void HiddenVideoTrack_EmitsEnabledFalse()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir));
        var track = ExportFixtures.VideoTrack(ExportFixtures.Clip(id: "vc", mediaRef: "media-v", start: 0, duration: 30));
        track.Hidden = true;
        var timeline = ExportFixtures.Timeline(tracks: [track]);

        var xml = XmemlExporter.Render(timeline, resolver);

        var videoStart = xml.IndexOf("<video>", StringComparison.Ordinal);
        var videoEnd = xml.IndexOf("</video>", StringComparison.Ordinal) + "</video>".Length;
        videoStart.ShouldBeGreaterThanOrEqualTo(0);
        xml[videoStart..videoEnd].ShouldContain("<enabled>FALSE</enabled>");
    }

    // MARK: - Trim handling

    /// Source: trimStartIsReflectedInInOutPoints
    [Fact]
    public void TrimStart_IsReflectedInInOutPoints()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir));
        var clip = ExportFixtures.Clip(id: "c1", mediaRef: "media-v", start: 0, duration: 60, trimStart: 10);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);

        var xml = XmemlExporter.Render(timeline, resolver);

        xml.ShouldContain("<in>10</in>");
        xml.ShouldContain("<out>70</out>");
    }

    // MARK: - Timeline duration / ordering

    /// Source: sequenceDurationEqualsTimelineTotalFrames
    [Fact]
    public void SequenceDuration_EqualsTimelineTotalFrames()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir));
        var clipA = ExportFixtures.Clip(id: "a", mediaRef: "media-v", start: 0, duration: 50);
        var clipB = ExportFixtures.Clip(id: "b", mediaRef: "media-v", start: 100, duration: 80);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clipA, clipB)]);

        var xml = XmemlExporter.Render(timeline, resolver);

        xml.ShouldContain("<duration>180</duration>");
    }

    /// Source: multipleClipsOnSameTrackAreSortedByStartFrame
    [Fact]
    public void MultipleClips_OnSameTrack_AreSortedByStartFrame()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir));
        var later = ExportFixtures.Clip(id: "later", mediaRef: "media-v", start: 100, duration: 30);
        var earlier = ExportFixtures.Clip(id: "earlier", mediaRef: "media-v", start: 0, duration: 30);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(later, earlier)]);

        var xml = XmemlExporter.Render(timeline, resolver);

        xml.IndexOf("earlier", StringComparison.Ordinal).ShouldBeLessThan(xml.IndexOf("later", StringComparison.Ordinal));
    }

    /// Source: videoTracksAreReversedForFCPConvention
    [Fact]
    public void VideoTracks_AreReversedForFcpConvention()
    {
        var dir = ExportFixtures.NewTempDir();
        var entry = new MediaManifestEntry("media-v", "v", ClipType.Video, MediaSource.External(Path.Combine(dir, "v.mp4")), 5.0);
        var resolver = ExportFixtures.ResolverFor(entry);
        var topClip = ExportFixtures.Clip(id: "top-clip", mediaRef: "media-v", start: 0, duration: 30);
        var bottomClip = ExportFixtures.Clip(id: "bottom-clip", mediaRef: "media-v", start: 0, duration: 30);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(topClip), ExportFixtures.VideoTrack(bottomClip)]);

        var xml = XmemlExporter.Render(timeline, resolver);

        xml.IndexOf("bottom-clip", StringComparison.Ordinal).ShouldBeLessThan(xml.IndexOf("top-clip", StringComparison.Ordinal));
    }

    // MARK: - Keyframes, crop, transitions, NTSC

    private static (MediaResolver Resolver, string Dir) Fixture(int width = 3840, int height = 2160, double? sourceFPS = null)
    {
        var dir = ExportFixtures.NewTempDir();
        var entry = new MediaManifestEntry("media-1", "Clip", ClipType.Video, MediaSource.External(Path.Combine(dir, "kf.mov")), 5,
            sourceWidth: width, sourceHeight: height) { SourceFPS = sourceFPS };
        return (ExportFixtures.ResolverFor(entry), dir);
    }

    private static string ExportClip(Clip clip, MediaResolver resolver)
    {
        var track = clip.MediaType == ClipType.Audio ? ExportFixtures.AudioTrack(clip) : ExportFixtures.VideoTrack(clip);
        var timeline = ExportFixtures.Timeline(tracks: [track]);
        return XmemlExporter.Render(timeline, resolver);
    }

    /// Source: positionKeyframesEmitVaryingCenter
    [Fact]
    public void PositionKeyframes_EmitVaryingCenter()
    {
        var (resolver, _) = Fixture();
        var clip = ExportFixtures.Clip(mediaRef: "media-1", start: 0, duration: 200);
        clip.PositionTrack = new KeyframeTrack<AnimPair>([
            new Keyframe<AnimPair>(0, new AnimPair(0.0, 0.0)),
            new Keyframe<AnimPair>(100, new AnimPair(0.5, 0.5)),
        ]);

        var xml = ExportClip(clip, resolver);

        xml.ShouldContain("<parameterid>center</parameterid>");
        xml.ShouldContain("<horiz>0.50000</horiz>");
        xml.ShouldContain("<vert>0.50000</vert>");
    }

    /// Source: opacityKeyframesEmittedWithClipRelativeWhen
    [Fact]
    public void OpacityKeyframes_EmittedWithClipRelativeWhen()
    {
        var (resolver, _) = Fixture();
        var clip = ExportFixtures.Clip(mediaRef: "media-1", start: 100, duration: 200);
        clip.OpacityTrack = new KeyframeTrack<double>([
            new Keyframe<double>(30, 1.0),
            new Keyframe<double>(150, 0.5),
        ]);

        var xml = ExportClip(clip, resolver);

        xml.ShouldContain("<effectid>opacity</effectid>");
        xml.ShouldContain("<when>30</when>");
        xml.ShouldContain("<value>100.0</value>");
        xml.ShouldContain("<when>150</when>");
        xml.ShouldContain("<value>50.0</value>");
    }

    /// Source: volumeKeyframesEmittedOnAudioClip
    [Fact]
    public void VolumeKeyframes_EmittedOnAudioClip()
    {
        var (resolver, _) = Fixture();
        var clip = ExportFixtures.Clip(mediaRef: "media-1", mediaType: ClipType.Audio, start: 0, duration: 100);
        clip.VolumeTrack = new KeyframeTrack<double>([
            new Keyframe<double>(0, 0),
            new Keyframe<double>(50, -6),
        ]);

        var xml = ExportClip(clip, resolver);

        xml.ShouldContain("<effectid>audiolevels</effectid>");
        xml.ShouldContain("<when>0</when>");
        xml.ShouldContain("<when>50</when>");
        xml.ShouldContain("<keyframe>");
    }

    /// Source: fadesEmitSingleSidedCrossDissolveTransitions
    [Fact]
    public void Fades_EmitSingleSidedCrossDissolveTransitions()
    {
        var (resolver, _) = Fixture();
        var clip = ExportFixtures.Clip(mediaRef: "media-1", start: 100, duration: 200);
        clip.FadeInFrames = 30;
        clip.FadeOutFrames = 20;

        var xml = ExportClip(clip, resolver);

        xml.ShouldContain("<effectid>Cross Dissolve</effectid>");
        xml.ShouldContain("<alignment>start-black</alignment>");
        xml.ShouldContain("<start>100</start>");
        xml.ShouldContain("<end>130</end>");
        xml.ShouldContain("<alignment>end-black</alignment>");
        xml.ShouldContain("<start>280</start>");
        xml.ShouldContain("<end>300</end>");
        xml.IndexOf("start-black", StringComparison.Ordinal).ShouldBeLessThan(xml.IndexOf("<clipitem", StringComparison.Ordinal));
    }

    /// Source: audioClipFadesEmitCrossFadeTransitions
    [Fact]
    public void AudioClipFades_EmitCrossFadeTransitions()
    {
        var (resolver, _) = Fixture();
        var clip = ExportFixtures.Clip(mediaRef: "media-1", mediaType: ClipType.Audio, start: 0, duration: 100);
        clip.FadeInFrames = 10;
        clip.FadeOutFrames = 15;

        var xml = ExportClip(clip, resolver);

        xml.ShouldContain("<effectid>KGAudioTransCrossFade0dB</effectid>");
        xml.ShouldContain("<mediatype>audio</mediatype>");
        xml.ShouldNotContain("Cross Dissolve");
        xml.ShouldNotContain("<wipecode>");
        xml.ShouldContain("<start>0</start>");
        xml.ShouldContain("<end>10</end>");
        xml.ShouldContain("<start>85</start>");
        xml.ShouldContain("<end>100</end>");
    }

    /// Source: noFadeEmitsNoTransition
    [Fact]
    public void NoFade_EmitsNoTransition()
    {
        var (resolver, _) = Fixture();
        var clip = ExportFixtures.Clip(mediaRef: "media-1", start: 0, duration: 100);

        var xml = ExportClip(clip, resolver);

        xml.ShouldNotContain("<transitionitem>");
    }

    /// Source: staticCropEmitsCropFilterAsPercentages
    [Fact]
    public void StaticCrop_EmitsCropFilterAsPercentages()
    {
        var (resolver, _) = Fixture();
        var clip = ExportFixtures.Clip(mediaRef: "media-1", start: 0, duration: 100);
        clip.Crop = new Crop { Left = 0.1, Top = 0.25, Right = 0.2, Bottom = 0.05 };

        var xml = ExportClip(clip, resolver);

        xml.ShouldContain("<effectid>crop</effectid>");
        xml.ShouldContain("<parameterid>left</parameterid>");
        xml.ShouldContain("<value>10.00</value>");
        xml.ShouldContain("<value>25.00</value>");
        xml.ShouldNotContain("<keyframe>");
    }

    /// Source: cropKeyframesEmitClipRelativeWhen
    [Fact]
    public void CropKeyframes_EmitClipRelativeWhen()
    {
        var (resolver, _) = Fixture();
        var clip = ExportFixtures.Clip(mediaRef: "media-1", start: 40, duration: 200);
        clip.CropTrack = new KeyframeTrack<Crop>([
            new Keyframe<Crop>(0, new Crop()),
            new Keyframe<Crop>(60, new Crop { Left = 0.5 }),
        ]);

        var xml = ExportClip(clip, resolver);

        xml.ShouldContain("<effectid>crop</effectid>");
        xml.ShouldContain("<when>0</when>");
        xml.ShouldContain("<when>60</when>");
        xml.ShouldContain("<value>50.00</value>");
    }

    /// Source: identityCropEmitsNoFilter
    [Fact]
    public void IdentityCrop_EmitsNoFilter()
    {
        var (resolver, _) = Fixture();
        var clip = ExportFixtures.Clip(mediaRef: "media-1", start: 0, duration: 100);

        var xml = ExportClip(clip, resolver);

        xml.ShouldNotContain("<effectid>crop</effectid>");
    }

    /// Source: ntscSourceMarksFileRateTrue
    [Fact]
    public void NtscSource_MarksFileRateTrue()
    {
        var (resolver, _) = Fixture(sourceFPS: 30000.0 / 1001.0);
        var clip = ExportFixtures.Clip(mediaRef: "media-1", start: 0, duration: 100);

        var xml = ExportClip(clip, resolver);

        xml.ShouldContain("<ntsc>TRUE</ntsc>");
        xml.ShouldContain("<ntsc>FALSE</ntsc>");
    }

    /// Source: cleanFpsSourceStaysNtscFalse
    [Fact]
    public void CleanFpsSource_StaysNtscFalse()
    {
        var (resolver, _) = Fixture(sourceFPS: 30.0);
        var clip = ExportFixtures.Clip(mediaRef: "media-1", start: 0, duration: 100);

        var xml = ExportClip(clip, resolver);

        xml.ShouldNotContain("<ntsc>TRUE</ntsc>");
    }

    /// Source: noKeyframesStillEmitsStaticValueOnly
    [Fact]
    public void NoKeyframes_StillEmitsStaticValueOnly()
    {
        var (resolver, _) = Fixture();
        var clip = ExportFixtures.Clip(mediaRef: "media-1", start: 0, duration: 100);
        clip.Opacity = 0.5;

        var xml = ExportClip(clip, resolver);

        xml.ShouldContain("<effectid>opacity</effectid>");
        xml.ShouldNotContain("<keyframe>");
    }

    // MARK: - Nested timelines (XMEMLNestExportTests)

    private static Timeline VideoEntryTimeline(string mediaRef, string dir) =>
        ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(ExportFixtures.Clip(mediaRef: mediaRef, start: 0, duration: 60))]);

    /// Source: nestEmitsInlineSequenceInsideClipitem
    [Fact]
    public void Nest_EmitsInlineSequenceInsideClipitem()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("v1", dir));
        var child = VideoEntryTimeline("v1", dir);
        child.Name = "Intro";
        var parent = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(ExportFixtures.NestCarrier(child, 30))]);
        var byId = new Dictionary<string, Timeline> { [child.Id] = child, [parent.Id] = parent };

        var xml = XmemlExporter.Render(parent, resolver, id => byId.GetValueOrDefault(id));

        xml.ShouldContain("<sequence id=\"sequence-2\">");
        xml.ShouldContain("<name>Intro</name>");
        var clipitem = xml.Split(["<clipitem"], StringSplitOptions.None).FirstOrDefault(s => s.Contains("sequence-2")) ?? "";
        clipitem.ShouldContain("<start>30</start>");
        clipitem.ShouldContain("<end>90</end>");
        clipitem.ShouldContain("<in>0</in>");
        clipitem.ShouldContain("<out>60</out>");
        xml.ShouldContain("<pathurl>");
    }

    /// Source: secondCarrierReferencesTheSequenceById
    [Fact]
    public void SecondCarrier_ReferencesTheSequenceById()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("v1", dir));
        var child = VideoEntryTimeline("v1", dir);
        var parent = ExportFixtures.Timeline(tracks:
        [
            ExportFixtures.VideoTrack(ExportFixtures.NestCarrier(child, 0), ExportFixtures.NestCarrier(child, 60)),
        ]);
        var byId = new Dictionary<string, Timeline> { [child.Id] = child, [parent.Id] = parent };

        var xml = XmemlExporter.Render(parent, resolver, id => byId.GetValueOrDefault(id));

        Count(xml, "<sequence id=\"sequence-2\">").ShouldBe(1);
        Count(xml, "<sequence id=\"sequence-2\"/>").ShouldBe(1);
    }

    /// Source: twoLevelNestingEmitsBothSequences
    [Fact]
    public void TwoLevelNesting_EmitsBothSequences()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("v1", dir));
        var grandchild = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(ExportFixtures.Clip(mediaRef: "v1", start: 0, duration: 30))]);
        grandchild.Name = "Deep";
        var child = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(ExportFixtures.NestCarrier(grandchild, 0))]);
        var parent = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(ExportFixtures.NestCarrier(child, 0))]);
        var byId = new Dictionary<string, Timeline> { [grandchild.Id] = grandchild, [child.Id] = child, [parent.Id] = parent };

        var xml = XmemlExporter.Render(parent, resolver, id => byId.GetValueOrDefault(id));

        xml.ShouldContain("<sequence id=\"sequence-2\">");
        xml.ShouldContain("<sequence id=\"sequence-3\">");
        xml.ShouldContain("<name>Deep</name>");
    }

    /// Source: frozenCarrierClampsToChildContent (XMEMLNestExportTests)
    [Fact]
    public void FrozenCarrier_ClampsToChildContent()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("v1", dir));
        var child = VideoEntryTimeline("v1", dir);
        var parent = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(ExportFixtures.NestCarrier(child, 0, duration: 100, trimStart: 10))]);
        var byId = new Dictionary<string, Timeline> { [child.Id] = child, [parent.Id] = parent };

        var xml = XmemlExporter.Render(parent, resolver, id => byId.GetValueOrDefault(id));

        var clipitem = xml.Split(["<clipitem"], StringSplitOptions.None).FirstOrDefault(s => s.Contains("sequence-2")) ?? "";
        clipitem.ShouldContain("<in>10</in>");
        clipitem.ShouldContain("<out>60</out>");
        clipitem.ShouldContain("<end>50</end>");
    }

    /// Source: emptyOrMissingChildDropsCarrier (XMEMLNestExportTests)
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

        var xml = XmemlExporter.Render(parent, resolver, id => byId.GetValueOrDefault(id));

        xml.ShouldNotContain("<clipitem");
        xml.ShouldNotContain("sequence-2");
    }

    /// Source: linkedCarrierPairEmitsLinkedClipitems
    [Fact]
    public void LinkedCarrierPair_EmitsLinkedClipitems()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("v1", dir));
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

        var xml = XmemlExporter.Render(parent, resolver, id => byId.GetValueOrDefault(id));

        Count(xml, "<sequence id=\"sequence-2\">").ShouldBe(1);
        Count(xml, "<sequence id=\"sequence-2\"/>").ShouldBe(1);
        xml.ShouldContain($"<linkclipref>clipitem-{video.Id}</linkclipref>");
        xml.ShouldContain($"<linkclipref>clipitem-{audio.Id}</linkclipref>");
    }

    // MARK: - Export service / round trip via ExportAsync

    /// New (not a direct Swift port): exercises `XmemlExporter.ExportAsync` end to end with the
    /// injected `ISourceTimingReader` seam, and confirms the file parses as well-formed XML.
    [Fact]
    public async Task ExportAsync_WritesFileAndReadsTimecodeThroughInjectedTimingReader()
    {
        var dir = ExportFixtures.NewTempDir();
        var resolver = ExportFixtures.ResolverFor(ExportFixtures.VideoEntry("media-v", dir));
        var clip = ExportFixtures.Clip(id: "c1", mediaRef: "media-v", start: 0, duration: 30);
        var timeline = ExportFixtures.Timeline(tracks: [ExportFixtures.VideoTrack(clip)]);
        var timingReader = new FakeSourceTimingReader(new Dictionary<string, SourceTimecode>
        {
            ["media-v"] = new SourceTimecode(90, 30, false),
        });
        var outPath = Path.Combine(dir, "out.xml");

        await XmemlExporter.ExportAsync(timeline, resolver, timingReader, outPath);

        File.Exists(outPath).ShouldBeTrue();
        var xml = File.ReadAllText(outPath);
        xml.ShouldContain("<string>00:00:03:00</string>");
        Should.NotThrow(() => XDocument.Parse(xml));
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
}

/// Ported from Tests/PalmierProTests/Export/XMLExporterTimecodeTests.swift — pure functions, no I/O.
public class XmemlTimecodeTests
{
    // MARK: - TimecodeTagsFor follows the track, not the video rate

    /// Source: nonDropSourceEmitsNonDropTimecodeRegardlessOfVideoNtsc
    [Fact]
    public void NonDropSource_EmitsNonDropTimecodeRegardlessOfVideoNtsc()
    {
        // 29.97 NDF source: start 18:13:40:20 → frame 1968620 at quanta 30, drop-frame FALSE.
        var tc = XmemlExporter.TimecodeTagsFor(new SourceTimecode(1968620, 30, false), videoTimebase: 30, videoNtsc: true);

        tc.Base.ShouldBe(30);
        tc.Ntsc.ShouldBeTrue();
        tc.DropFrame.ShouldBeFalse();
        tc.String.ShouldBe("18:13:40:20");
        tc.String.ShouldNotContain(";");
    }

    /// Source: dropFrameSourceOn60pUsesTrackQuantaNotVideoRate
    [Fact]
    public void DropFrameSourceOn60p_UsesTrackQuantaNotVideoRate()
    {
        var tc = XmemlExporter.TimecodeTagsFor(new SourceTimecode(42966, 30, true), videoTimebase: 60, videoNtsc: true);

        tc.Base.ShouldBe(30);
        tc.DropFrame.ShouldBeTrue();
        tc.Frame.ShouldBe(42966);
        tc.String.ShouldBe("00;23;53;18");
    }

    /// Source: cleanThirtyFpsSourceStaysNonNtsc
    [Fact]
    public void CleanThirtyFpsSource_StaysNonNtsc()
    {
        var tc = XmemlExporter.TimecodeTagsFor(new SourceTimecode(0, 30, false), videoTimebase: 30, videoNtsc: false);

        tc.Ntsc.ShouldBeFalse();
        tc.String.ShouldBe("00:00:00:00");
    }

    /// Source: noTimecodeTrackFallsBackToVideoRateAndZero
    [Fact]
    public void NoTimecodeTrack_FallsBackToVideoRateAndZero()
    {
        var tc = XmemlExporter.TimecodeTagsFor(null, videoTimebase: 30, videoNtsc: true);

        tc.Frame.ShouldBe(0);
        tc.Base.ShouldBe(30);
        tc.DropFrame.ShouldBeTrue();
        tc.String.ShouldBe("00;00;00;00");
    }

    // MARK: - FormatTimecode math

    /// Source: nonDropFormattingRollsFieldsAtFps
    [Fact]
    public void NonDropFormatting_RollsFieldsAtFps()
    {
        XmemlExporter.FormatTimecode(0, 25, false).ShouldBe("00:00:00:00");
        XmemlExporter.FormatTimecode(1688098, 25, false).ShouldBe("18:45:23:23");
        XmemlExporter.FormatTimecode(24 * 3600, 24, false).ShouldBe("01:00:00:00");
    }

    /// Source: dropFrameSkipsDroppedFrameNumbers
    [Fact]
    public void DropFrame_SkipsDroppedFrameNumbers()
    {
        XmemlExporter.FormatTimecode(0, 30, true).ShouldBe("00;00;00;00");
        XmemlExporter.FormatTimecode(42966, 30, true).ShouldBe("00;23;53;18");
    }

    /// Source: zeroFpsDoesNotCrash
    [Fact]
    public void ZeroFps_DoesNotCrash()
    {
        XmemlExporter.FormatTimecode(100, 0, false).ShouldBe("00:00:00:00");
    }
}
