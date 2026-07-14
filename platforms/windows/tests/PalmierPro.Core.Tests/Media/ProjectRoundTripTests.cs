using System.Text.Json;
using System.Text.Json.Nodes;
using PalmierPro.Core.Models;
using Shouldly;
using Xunit;

namespace PalmierPro.Core.Tests;

/// JSON fidelity for the timeline model cluster. Mirrors the spirit of
/// Tests/PalmierProTests/Media/ProjectRoundTripTests.swift: decode a hand-authored fixture
/// shaped exactly like the Swift encoder's output, re-encode, and assert semantic equality —
/// plus explicit coverage of every lenient-decode fallback and every still-strict spot
/// (Keyframe/KeyframeTrack/AnimPair/Crop/MulticamSource have no custom Swift decoder, so they
/// stay strict; Timeline/Track/Clip/Effect/Transform do, so they're lenient per-field).
public class ProjectRoundTripTests
{
    private static void AssertRoundTripsSemantically(string fixtureJson)
    {
        var original = JsonNode.Parse(fixtureJson);
        var decoded = JsonSerializer.Deserialize<Models.Timeline>(fixtureJson)!;
        var reencoded = JsonSerializer.Serialize(decoded);
        var reparsed = JsonNode.Parse(reencoded);
        JsonNode.DeepEquals(original, reparsed).ShouldBeTrue($"expected semantic equality.\nOriginal: {original}\nReencoded: {reparsed}");
    }

    [Fact]
    public void FullTimelineRoundTripsSemantically()
    {
        const string json = """
        {
          "id": "tl1", "name": "Main", "fps": 30, "width": 1920, "height": 1080,
          "settingsConfigured": true, "folderId": "folder1",
          "tracks": [
            {
              "id": "trackV", "type": "video", "muted": false, "hidden": false, "syncLocked": true,
              "displayHeight": 60,
              "clips": [
                {
                  "id": "clipA", "mediaRef": "media1", "mediaType": "video", "sourceClipType": "video",
                  "startFrame": 0, "durationFrames": 90, "trimStartFrame": 0, "trimEndFrame": 0,
                  "speed": 1.0, "volume": 1.0, "fadeInFrames": 0, "fadeOutFrames": 0,
                  "fadeInInterpolation": "linear", "fadeOutInterpolation": "linear", "opacity": 1.0,
                  "transform": {"centerX": 0.5, "centerY": 0.5, "width": 1, "height": 1, "rotation": 0, "flipHorizontal": false, "flipVertical": false},
                  "crop": {"left": 0, "top": 0, "right": 0, "bottom": 0}
                },
                {
                  "id": "clipB", "mediaRef": "media2", "mediaType": "video", "sourceClipType": "video",
                  "startFrame": 90, "durationFrames": 60, "trimStartFrame": 5, "trimEndFrame": 3,
                  "speed": 1.5, "volume": 0.8, "fadeInFrames": 10, "fadeOutFrames": 15,
                  "fadeInInterpolation": "smooth", "fadeOutInterpolation": "hold", "opacity": 0.9,
                  "transform": {"centerX": 0.6, "centerY": 0.4, "width": 0.5, "height": 0.5, "rotation": 15, "flipHorizontal": true, "flipVertical": false},
                  "crop": {"left": 0.1, "top": 0, "right": 0.1, "bottom": 0},
                  "linkGroupId": "link1", "multicamGroupId": "mc1",
                  "opacityTrack": {"keyframes": [
                    {"frame": 0, "value": 0, "interpolationOut": "linear"},
                    {"frame": 30, "value": 1, "interpolationOut": "smooth"}
                  ]},
                  "positionTrack": {"keyframes": [
                    {"frame": 0, "value": {"a": 0.1, "b": 0.2}, "interpolationOut": "hold"}
                  ]},
                  "effects": [
                    {"id": "fx1", "type": "color.exposure", "enabled": true, "params": {"ev": {"value": 1.5}}}
                  ],
                  "blendMode": "screen"
                }
              ]
            },
            {
              "id": "trackA", "type": "audio", "muted": true, "hidden": false, "syncLocked": false,
              "displayHeight": 50,
              "clips": [
                {
                  "id": "clipC", "mediaRef": "media3", "mediaType": "audio", "sourceClipType": "audio",
                  "startFrame": 0, "durationFrames": 120, "trimStartFrame": 0, "trimEndFrame": 0,
                  "speed": 1.0, "volume": 1.0, "fadeInFrames": 0, "fadeOutFrames": 0,
                  "fadeInInterpolation": "linear", "fadeOutInterpolation": "linear", "opacity": 1.0,
                  "transform": {"centerX": 0.5, "centerY": 0.5, "width": 1, "height": 1, "rotation": 0, "flipHorizontal": false, "flipVertical": false},
                  "crop": {"left": 0, "top": 0, "right": 0, "bottom": 0},
                  "volumeTrack": {"keyframes": [
                    {"frame": 0, "value": -6, "interpolationOut": "linear"},
                    {"frame": 60, "value": 0, "interpolationOut": "linear"}
                  ]}
                }
              ]
            }
          ]
        }
        """;
        AssertRoundTripsSemantically(json);
    }

    [Fact]
    public void TextClipWithWordTimingsAndOpaqueTextStyleRoundTrips()
    {
        // textStyle/textAnimation are out of this cluster's scope and travel as raw JSON — an
        // arbitrary/future shape here must survive byte-for-byte.
        const string json = """
        {
          "id": "tl1", "fps": 30, "width": 1920, "height": 1080,
          "tracks": [
            {
              "type": "text",
              "clips": [
                {
                  "mediaRef": "caption-1", "mediaType": "text", "sourceClipType": "text",
                  "startFrame": 0, "durationFrames": 60,
                  "textContent": "Hello world",
                  "textStyle": {"fontName": "Helvetica-Bold", "fontSize": 42, "future": {"nested": [1, 2, 3]}},
                  "textAnimation": {"preset": "wordReveal", "perWordFrames": 4},
                  "wordTimings": [
                    {"text": "Hello", "startFrame": 0, "endFrame": 20},
                    {"text": "world", "startFrame": 20, "endFrame": 40}
                  ]
                }
              ]
            }
          ]
        }
        """;
        var decoded = JsonSerializer.Deserialize<Models.Timeline>(json)!;
        var clip = decoded.Tracks[0].Clips[0];
        clip.WordTimings!.Count.ShouldBe(2);
        clip.WordTimings[0].Text.ShouldBe("Hello");
        clip.WordTimings[1].EndFrame.ShouldBe(40);
        clip.TextStyle.ShouldNotBeNull();

        // The fixture omits many defaulted fields (name, track id, trimStartFrame, ...), so it
        // won't match the fully-populated re-encode byte-for-byte — but the opaque textStyle
        // subtree specifically must survive verbatim, and re-encoding must be idempotent.
        var reencoded = JsonSerializer.Serialize(decoded);
        var redecoded = JsonSerializer.Deserialize<Models.Timeline>(reencoded)!;
        JsonNode.DeepEquals(
            JsonNode.Parse(JsonSerializer.Serialize(decoded.Tracks[0].Clips[0].TextStyle)),
            JsonNode.Parse(JsonSerializer.Serialize(redecoded.Tracks[0].Clips[0].TextStyle))
        ).ShouldBeTrue("opaque textStyle must survive a decode/encode/decode cycle unchanged");
        JsonNode.DeepEquals(JsonNode.Parse(reencoded), JsonNode.Parse(JsonSerializer.Serialize(redecoded)))
            .ShouldBeTrue("re-encoding a decoded Timeline must be idempotent");
    }

    // MARK: - Timeline leniency

    [Fact]
    public void TimelineFallsBackToDefaultsForMissingOptionalFields()
    {
        const string json = """{"fps": 24, "width": 100, "height": 100, "tracks": []}""";
        var tl = JsonSerializer.Deserialize<Models.Timeline>(json)!;
        tl.Name.ShouldBe("Timeline 1");
        tl.SettingsConfigured.ShouldBeFalse();
        tl.FolderId.ShouldBeNull();
        tl.Id.ShouldNotBeNullOrEmpty();
    }

    [Fact]
    public void TimelineSwallowsMistypedOptionalFields()
    {
        // Swift's `try? c.decode(...)` swallows type mismatches too, not just missing keys.
        const string json = """{"fps": 24, "width": 100, "height": 100, "tracks": [], "name": 12345, "settingsConfigured": "yes"}""";
        var tl = JsonSerializer.Deserialize<Models.Timeline>(json)!;
        tl.Name.ShouldBe("Timeline 1");
        tl.SettingsConfigured.ShouldBeFalse();
    }

    [Theory]
    [InlineData("""{"width": 100, "height": 100, "tracks": []}""")] // missing fps
    [InlineData("""{"fps": 24, "height": 100, "tracks": []}""")] // missing width
    [InlineData("""{"fps": 24, "width": 100, "tracks": []}""")] // missing height
    [InlineData("""{"fps": 24, "width": 100, "height": 100}""")] // missing tracks
    public void TimelineThrowsWhenARequiredFieldIsMissing(string json)
    {
        Should.Throw<JsonException>(() => JsonSerializer.Deserialize<Models.Timeline>(json));
    }

    [Fact]
    public void TimelineThrowsWhenARequiredValueTypeFieldIsExplicitlyNull()
    {
        // Regression guard for the unconstrained-generic-erasure bug this cluster hit during
        // development: `Require<int>` must still throw for a present-but-null "fps", not just
        // a missing one — value types can't silently swallow JSON null into a default.
        const string json = """{"fps": null, "width": 100, "height": 100, "tracks": []}""";
        Should.Throw<JsonException>(() => JsonSerializer.Deserialize<Models.Timeline>(json));
    }

    // MARK: - Track leniency

    [Fact]
    public void TrackFallsBackToDefaultsForMissingOptionalFields()
    {
        const string json = """{"type": "video"}""";
        var track = JsonSerializer.Deserialize<Models.Track>(json)!;
        track.Muted.ShouldBeFalse();
        track.Hidden.ShouldBeFalse();
        track.SyncLocked.ShouldBeTrue();
        track.Clips.ShouldBeEmpty();
        track.DisplayHeight.ShouldBe(50);
    }

    [Fact]
    public void TrackThrowsWhenTypeIsMissing()
    {
        Should.Throw<JsonException>(() => JsonSerializer.Deserialize<Models.Track>("{}"));
    }

    [Fact]
    public void TrackClipsFallsBackToEmptyWhenAnyClipInTheArrayIsMalformed()
    {
        // One bad clip (missing required mediaRef) fails the WHOLE array decode, which Track's
        // `try? ... ?? []` then swallows to an empty list — not "drop just the bad one".
        const string json = """
        {"type": "video", "clips": [
          {"mediaRef": "ok", "startFrame": 0, "durationFrames": 10},
          {"startFrame": 20, "durationFrames": 10}
        ]}
        """;
        var track = JsonSerializer.Deserialize<Models.Track>(json)!;
        track.Clips.ShouldBeEmpty();
    }

    [Fact]
    public void TrackDisplayHeightClampsToTrackSizeBounds()
    {
        const string json = """{"type": "video", "displayHeight": 9999}""";
        var track = JsonSerializer.Deserialize<Models.Track>(json)!;
        track.DisplayHeight.ShouldBe(TrackSize.MaxHeight);
    }

    [Fact]
    public void TrackDisplayHeightFallsBackTo50WhenMistyped()
    {
        const string json = """{"type": "video", "displayHeight": "tall"}""";
        var track = JsonSerializer.Deserialize<Models.Track>(json)!;
        track.DisplayHeight.ShouldBe(50);
    }

    // MARK: - Clip leniency

    [Fact]
    public void ClipFallsBackToDefaultsForEveryOptionalField()
    {
        const string json = """{"mediaRef": "m", "startFrame": 0, "durationFrames": 10}""";
        var clip = JsonSerializer.Deserialize<Models.Clip>(json)!;
        clip.MediaType.ShouldBe(ClipType.Video);
        clip.SourceClipType.ShouldBe(ClipType.Video);
        clip.TrimStartFrame.ShouldBe(0);
        clip.Speed.ShouldBe(1.0);
        clip.Volume.ShouldBe(1.0);
        clip.FadeInInterpolation.ShouldBe(Interpolation.Linear);
        clip.Opacity.ShouldBe(1.0);
        clip.Transform.ShouldNotBeNull();
        clip.Crop.ShouldNotBeNull();
        clip.Effects.ShouldBeNull();
        clip.BlendMode.ShouldBeNull();
        clip.OpacityTrack.ShouldBeNull();
    }

    [Theory]
    [InlineData("""{"startFrame": 0, "durationFrames": 10}""")] // missing mediaRef
    [InlineData("""{"mediaRef": "m", "durationFrames": 10}""")] // missing startFrame
    [InlineData("""{"mediaRef": "m", "startFrame": 0}""")] // missing durationFrames
    public void ClipThrowsWhenARequiredFieldIsMissing(string json)
    {
        Should.Throw<JsonException>(() => JsonSerializer.Deserialize<Models.Clip>(json));
    }

    [Fact]
    public void ClipSwallowsMistypedSpeedAndFallsBackToOne()
    {
        const string json = """{"mediaRef": "m", "startFrame": 0, "durationFrames": 10, "speed": "fast"}""";
        var clip = JsonSerializer.Deserialize<Models.Clip>(json)!;
        clip.Speed.ShouldBe(1.0);
    }

    [Fact]
    public void ClipCropFallsBackToIdentityWhenIncomplete()
    {
        // Crop is fully strict on its own (no custom Swift init) — a partial crop object fails
        // to decode as a whole, and Clip's `try? ... ?? Crop()` swallows that to identity.
        const string json = """{"mediaRef": "m", "startFrame": 0, "durationFrames": 10, "crop": {"left": 0.2}}""";
        var clip = JsonSerializer.Deserialize<Models.Clip>(json)!;
        clip.Crop.IsIdentity.ShouldBeTrue();
    }

    [Fact]
    public void ClipTransformLegacyXYKeysMigrateToCenter()
    {
        // Legacy pre-centerX/Y projects stored top-left x/y; width/height decode first so the
        // migration math (oldX + w - 0.5) can run.
        const string json = """{"mediaRef": "m", "startFrame": 0, "durationFrames": 10, "transform": {"x": 0.25, "y": 0.1, "width": 0.5, "height": 0.4}}""";
        var clip = JsonSerializer.Deserialize<Models.Clip>(json)!;
        clip.Transform.CenterX.ShouldBe(0.25 + 0.5 - 0.5, 1e-9);
        clip.Transform.CenterY.ShouldBe(0.1 + 0.4 - 0.5, 1e-9);
    }

    [Fact]
    public void ClipTransformPrefersCenterXYOverLegacyXY()
    {
        const string json = """{"mediaRef": "m", "startFrame": 0, "durationFrames": 10, "transform": {"centerX": 0.7, "x": 0.0, "width": 1, "height": 1}}""";
        var clip = JsonSerializer.Deserialize<Models.Clip>(json)!;
        clip.Transform.CenterX.ShouldBe(0.7);
    }

    [Fact]
    public void ClipEffectsFallsBackToNullWhenAnyEffectInTheArrayIsMalformed()
    {
        const string json = """
        {"mediaRef": "m", "startFrame": 0, "durationFrames": 10, "effects": [
          {"type": "color.exposure"},
          {"enabled": true}
        ]}
        """;
        var clip = JsonSerializer.Deserialize<Models.Clip>(json)!;
        clip.Effects.ShouldBeNull();
    }

    [Fact]
    public void ClipKeyframeTrackFallsBackToNullWhenInnerKeyframeIsIncomplete()
    {
        // interpolationOut is required on Keyframe (no Swift custom init) — a keyframe missing
        // it fails the whole track, which Clip's `try?` swallows to null.
        const string json = """
        {"mediaRef": "m", "startFrame": 0, "durationFrames": 10,
         "opacityTrack": {"keyframes": [{"frame": 0, "value": 1.0}]}}
        """;
        var clip = JsonSerializer.Deserialize<Models.Clip>(json)!;
        clip.OpacityTrack.ShouldBeNull();
    }

    // MARK: - Effect leniency

    [Fact]
    public void EffectFallsBackToDefaultsForMissingOptionalFields()
    {
        const string json = """{"type": "color.exposure"}""";
        var effect = JsonSerializer.Deserialize<Effect>(json)!;
        effect.Enabled.ShouldBeTrue();
        effect.Params.ShouldBeEmpty();
        effect.Id.ShouldNotBeNullOrEmpty();
    }

    [Fact]
    public void EffectThrowsWhenTypeIsMissing()
    {
        Should.Throw<JsonException>(() => JsonSerializer.Deserialize<Effect>("{}"));
    }

    [Fact]
    public void EffectParamsFallsBackToEmptyWhenMistyped()
    {
        const string json = """{"type": "color.exposure", "params": "nope"}""";
        var effect = JsonSerializer.Deserialize<Effect>(json)!;
        effect.Params.ShouldBeEmpty();
    }

    // MARK: - Strict types (no Swift custom decoder anywhere in the chain)

    [Fact]
    public void KeyframeThrowsWhenInterpolationOutIsMissingEvenThoughItHasADefault()
    {
        // The classic Swift gotcha this port must not get backwards: a default property value
        // does NOT make synthesized Codable lenient — only Optional-typed properties get that.
        const string json = """{"frame": 0, "value": 1.0}""";
        Should.Throw<JsonException>(() => JsonSerializer.Deserialize<Keyframe<double>>(json));
    }

    [Fact]
    public void KeyframeTrackThrowsWhenKeyframesIsMissing()
    {
        Should.Throw<JsonException>(() => JsonSerializer.Deserialize<KeyframeTrack<double>>("{}"));
    }

    [Fact]
    public void AnimPairThrowsWhenEitherComponentIsMissing()
    {
        Should.Throw<JsonException>(() => JsonSerializer.Deserialize<AnimPair>("""{"a": 1.0}"""));
    }

    [Fact]
    public void CropThrowsWhenAnyEdgeIsMissingWhenDecodedStandalone()
    {
        Should.Throw<JsonException>(() => JsonSerializer.Deserialize<Crop>("""{"left": 0, "top": 0, "right": 0}"""));
    }
}
