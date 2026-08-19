using System.Text.Json;
using PalmierPro.Core.Models;
using PalmierPro.Core.Serialization;
using Xunit;

namespace PalmierPro.Core.Tests;

public class ProjectFileSerializationTests
{
    [Fact]
    public void RoundTripsRepresentativeProject()
    {
        var clip = new Clip
        {
            MediaRef = "ASSET-1",
            MediaType = ClipType.Video,
            SourceClipType = ClipType.Video,
            StartFrame = 30,
            DurationFrames = 120,
            TrimStartFrame = 5,
            Speed = 1.5,
            Volume = 0.8,
            FadeInFrames = 12,
            FadeInInterpolation = Interpolation.Smooth,
            Opacity = 0.9,
            EdgeRounding = 0.25,
            LinkGroupId = "LINK-1",
            BlendMode = BlendMode.ColorBurn,
            Effects =
            [
                Effect.Make("audio.denoise", new Dictionary<string, double> { ["amount"] = 0.7 }),
            ],
        };
        clip.UpsertKeyframe(AnimatableProperty.Opacity, 40, 0.5);
        clip.UpsertKeyframe(AnimatableProperty.Position, 30, new AnimPair(0.1, 0.2));
        clip.UpsertCropKeyframe(60, new Crop { Left = 0.1 });

        var textClip = new Clip
        {
            MediaRef = "TEXT-1",
            MediaType = ClipType.Text,
            SourceClipType = ClipType.Text,
            StartFrame = 0,
            DurationFrames = 90,
            TextContent = "Hello",
            TextStyle = new TextStyle { FontName = "Inter", FontSize = 72, Alignment = TextAlignment.Left },
            TextAnimation = new TextAnimation { Preset = TextAnimationPreset.WordPop, PerWordFrames = 8 },
            WordTimings = [new WordTiming("Hello", 0, 30)],
            TextFillMode = TextFillMode.Footage,
        };

        var file = new ProjectFile
        {
            Timelines =
            [
                new Timeline
                {
                    Name = "Main",
                    Fps = 24,
                    Width = 3840,
                    Height = 2160,
                    SettingsConfigured = true,
                    Tracks =
                    [
                        new Track { Type = ClipType.Video, Clips = [clip, textClip], DisplayHeight = 64 },
                        new Track { Type = ClipType.Audio, Muted = true, SyncLocked = false },
                    ],
                },
            ],
            ActiveTimelineId = "T1",
            ViewStates = new Dictionary<string, TimelineViewState>
            {
                ["T1"] = new() { PlayheadFrame = 42, ZoomScale = 2.5 },
            },
            Speakers = [new SpeakerRegistryEntry { Id = 1, Name = "Alice", Color = [0.1, 0.2, 0.3, 1], Centroid = [0.5f, 0.25f] }],
            MulticamGroups =
            [
                new MulticamSource
                {
                    Name = "Interview",
                    MasterMemberId = "M1",
                    Members =
                    [
                        new MulticamSource.Member
                        {
                            Id = "M1",
                            MediaRef = "ASSET-1",
                            Kind = MulticamSource.MemberKind.Both,
                            AngleLabel = "Wide",
                            Sync = new MulticamSource.SyncMap { OffsetSeconds = 1.25, Confidence = 0.9 },
                        },
                    ],
                },
            ],
        };

        var encoded = PalmierJson.Encode(file);
        var decoded = ProjectFile.Decode(encoded);

        var timeline = Assert.Single(decoded.Timelines);
        Assert.Equal("Main", timeline.Name);
        Assert.Equal(24, timeline.Fps);
        Assert.Equal(2, timeline.Tracks.Count);

        var decodedClip = timeline.Tracks[0].Clips[0];
        Assert.Equal(clip.Id, decodedClip.Id);
        Assert.Equal(1.5, decodedClip.Speed);
        Assert.Equal(BlendMode.ColorBurn, decodedClip.BlendMode);
        Assert.Equal(0.25, decodedClip.EdgeRounding);
        Assert.Equal(0.5, decodedClip.OpacityTrack!.Keyframes[0].Value);
        Assert.Equal(new AnimPair(0.1, 0.2), decodedClip.PositionTrack!.Keyframes[0].Value);
        Assert.Equal(0.1, decodedClip.CropTrack!.Keyframes[0].Value.Left);
        Assert.Equal(0.7, decodedClip.Effects![0].Params["amount"].Value);

        var decodedText = timeline.Tracks[0].Clips[1];
        Assert.Equal("Hello", decodedText.TextContent);
        Assert.Equal(TextAnimationPreset.WordPop, decodedText.TextAnimation!.Preset);
        Assert.Equal(TextFillMode.Footage, decodedText.TextFillMode);
        Assert.Equal(TextAlignment.Left, decodedText.TextStyle!.Alignment);

        Assert.Equal(42, decoded.ViewStates!["T1"].PlayheadFrame);
        Assert.Equal("Alice", decoded.Speakers![0].Name);
        Assert.Equal(1.25, decoded.MulticamGroups![0].Members[0].Sync.OffsetSeconds);
    }

    [Fact]
    public void EnumsEncodeAsSwiftRawValues()
    {
        var clip = new Clip
        {
            MediaRef = "A",
            StartFrame = 0,
            DurationFrames = 10,
            BlendMode = BlendMode.ColorBurn,
            FadeInInterpolation = Interpolation.Smooth,
            MediaType = ClipType.Lottie,
        };
        var json = PalmierJson.EncodeToString(clip);
        Assert.Contains("\"blendMode\":\"colorBurn\"", json);
        Assert.Contains("\"fadeInInterpolation\":\"smooth\"", json);
        Assert.Contains("\"mediaType\":\"lottie\"", json);
    }

    [Fact]
    public void NilOptionalsAreOmitted()
    {
        var clip = new Clip { MediaRef = "A", StartFrame = 0, DurationFrames = 10 };
        var json = PalmierJson.EncodeToString(clip);
        Assert.DoesNotContain("linkGroupId", json);
        Assert.DoesNotContain("textStyle", json);
        Assert.DoesNotContain("opacityTrack", json);
        Assert.DoesNotContain("effects", json);
    }

    [Fact]
    public void DecodesSwiftShapedClipJson()
    {
        const string json = """
        {
            "id": "C1",
            "mediaRef": "M1",
            "mediaType": "video",
            "sourceClipType": "video",
            "startFrame": 10,
            "durationFrames": 50,
            "speed": 2.0,
            "opacityTrack": { "keyframes": [ { "frame": 0, "value": 0.25, "interpolationOut": "hold" } ] },
            "transform": { "centerX": 0.4, "centerY": 0.6, "width": 0.5, "height": 0.5, "rotation": 45, "flipHorizontal": true, "flipVertical": false }
        }
        """;
        var clip = PalmierJson.Decode<Clip>(json)!;
        Assert.Equal("C1", clip.Id);
        Assert.Equal(2.0, clip.Speed);
        Assert.Equal(Interpolation.Hold, clip.OpacityTrack!.Keyframes[0].InterpolationOut);
        Assert.Equal(0.4, clip.Transform.CenterX);
        Assert.True(clip.Transform.FlipHorizontal);
        // Missing keys pick up Swift defaults.
        Assert.Equal(1.0, clip.Volume);
        Assert.Equal(Interpolation.Linear, clip.FadeInInterpolation);
        Assert.Equal(1.0, clip.Opacity);
    }

    [Fact]
    public void LegacyTransformTopLeftKeysConvertToCenter()
    {
        const string json = """{ "x": 0.1, "y": 0.2, "width": 0.5, "height": 0.4 }""";
        var transform = PalmierJson.Decode<Transform>(json)!;
        // centerX = oldX + width - 0.5 per the Swift decoder.
        Assert.Equal(0.1 + 0.5 - 0.5, transform.CenterX, 12);
        Assert.Equal(0.2 + 0.4 - 0.5, transform.CenterY, 12);
    }

    [Fact]
    public void LegacyBareTimelineDecodesAsSingleTimelineProject()
    {
        const string json = """
        {
            "id": "T-LEGACY",
            "name": "Old",
            "fps": 30,
            "width": 1920,
            "height": 1080,
            "tracks": [ { "type": "video", "clips": [] } ]
        }
        """;
        var file = ProjectFile.Decode(System.Text.Encoding.UTF8.GetBytes(json));
        var timeline = Assert.Single(file.Timelines);
        Assert.Equal("T-LEGACY", timeline.Id);
        Assert.Equal("T-LEGACY", file.ActiveTimelineId);
        Assert.Equal(["T-LEGACY"], file.OpenTimelineIds);
    }

    [Fact]
    public void InvalidProjectJsonThrows()
    {
        Assert.ThrowsAny<Exception>(() => ProjectFile.Decode("{ \"nothing\": true }"u8.ToArray()));
    }

    [Fact]
    public void OutOfRangeEdgeValuesResetToZero()
    {
        const string json = """{ "mediaRef": "M", "startFrame": 0, "durationFrames": 10, "edgeRounding": 4.5, "edgeSoftness": -1 }""";
        var clip = PalmierJson.Decode<Clip>(json)!;
        Assert.Equal(0, clip.EdgeRounding);
        Assert.Equal(0, clip.EdgeSoftness);
    }

    [Fact]
    public void TrackDisplayHeightClampsOnDecode()
    {
        const string json = """{ "type": "video", "clips": [], "displayHeight": 1000 }""";
        var track = PalmierJson.Decode<Track>(json)!;
        Assert.Equal(TrackSize.MaxHeight, track.DisplayHeight);
    }

    [Fact]
    public void MediaSourceUsesSwiftAssociatedValueShape()
    {
        var external = new MediaSource.External(@"C:\media\a.mp4");
        var project = new MediaSource.Project(@"media/b.mp4");
        Assert.Equal("""{"external":{"absolutePath":"C:\\media\\a.mp4"}}""", PalmierJson.EncodeToString<MediaSource>(external));
        Assert.Equal("""{"project":{"relativePath":"media/b.mp4"}}""", PalmierJson.EncodeToString<MediaSource>(project));

        var decoded = PalmierJson.Decode<MediaSource>("""{"project":{"relativePath":"media/x.wav"}}""");
        Assert.Equal(new MediaSource.Project("media/x.wav"), decoded);
    }

    [Fact]
    public void DatesEncodeAsSecondsSinceAppleReferenceDate()
    {
        var entry = new MediaManifestEntry
        {
            Id = "A",
            Name = "clip",
            Type = ClipType.Video,
            Source = new MediaSource.Project("media/a.mp4"),
            Duration = 5,
            CachedRemoteURLExpiresAt = new DateTime(2001, 1, 2, 0, 0, 0, DateTimeKind.Utc),
        };
        var json = PalmierJson.EncodeToString(entry);
        Assert.Contains("\"cachedRemoteURLExpiresAt\":86400", json);

        var decoded = PalmierJson.Decode<MediaManifestEntry>(json)!;
        Assert.Equal(entry.CachedRemoteURLExpiresAt, decoded.CachedRemoteURLExpiresAt);
    }

    [Fact]
    public void ManifestVersionDefaultsToOneWhenAbsent()
    {
        // Swift decodes a missing version as 1 (pre-folder manifests).
        var manifest = PalmierJson.Decode<MediaManifest>("""{ "entries": [] }""")!;
        // C# initializer is 2; Swift's decoder overrides to 1 when the key is missing.
        // Compatibility requires the C# default to match Swift's decode default.
        Assert.Equal(1, manifest.Version);
    }
}
