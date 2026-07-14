using System.Text.Json;
using System.Text.Json.Nodes;
using PalmierPro.Core.Models;
using Shouldly;
using Xunit;

namespace PalmierPro.Core.Tests;

/// Mirrors the model-only half of Tests/PalmierProTests/Rendering/EffectTests.swift —
/// EffectRenderingTests (real CI pixel rendering) has no Core analog yet.
public class EffectModelTests
{
    [Fact]
    public void ClipEffectsRoundTripThroughCodable()
    {
        var clip = Fixtures.Clip(id: "c1", mediaRef: "m", start: 0, duration: 30);
        clip.Effects = [Effect.Make("color.exposure", new Dictionary<string, double> { ["ev"] = 1.5 })];

        var json = JsonSerializer.Serialize(clip);
        var decoded = JsonSerializer.Deserialize<Clip>(json)!;

        decoded.Effects!.Count.ShouldBe(1);
        decoded.Effects[0].Type.ShouldBe("color.exposure");
        decoded.Effects[0].Params["ev"].Value.ShouldBe(1.5);
        decoded.Effects[0].Enabled.ShouldBeTrue();
    }

    [Fact]
    public void ClipWithoutEffectsOmitsKey()
    {
        var clip = Fixtures.Clip(id: "c1", mediaRef: "m", start: 0, duration: 30);
        var json = JsonSerializer.Serialize(clip);
        json.ShouldNotContain("\"effects\"");
    }

    /// Effects from a newer build survive decode + re-encode even when the descriptor is
    /// unknown to this build (there's no local EffectRegistry gate on decode).
    [Fact]
    public void UnknownEffectTypeIsPreserved()
    {
        var clip = Fixtures.Clip(id: "c1", mediaRef: "m", start: 0, duration: 30);
        clip.Effects = [Effect.Make("future.hologram", new Dictionary<string, double> { ["wobble"] = 0.7 })];

        var json = JsonSerializer.Serialize(clip);
        var decoded = JsonSerializer.Deserialize<Clip>(json)!;
        var reencoded = JsonSerializer.Serialize(decoded);
        var final = JsonSerializer.Deserialize<Clip>(reencoded)!;

        final.Effects![0].Type.ShouldBe("future.hologram");
        final.Effects[0].Params["wobble"].Value.ShouldBe(0.7);
    }

    [Fact]
    public void ParamResolvesKeyframeTrackWhenPresent()
    {
        var param = new EffectParam(1.0);
        param.Resolved(10, 0).ShouldBe(1.0);
        param.Track = new KeyframeTrack<double>([
            new Keyframe<double>(0, 0.0, Interpolation.Linear),
            new Keyframe<double>(20, 2.0, Interpolation.Linear),
        ]);
        Math.Abs(param.Resolved(10, 0) - 1.0).ShouldBeLessThan(0.001);
        Math.Abs(param.Resolved(20, 0) - 2.0).ShouldBeLessThan(0.001);
    }

    [Fact]
    public void ParamResolvedFallsBackToDefaultWhenValueAndTrackAreAbsent()
    {
        var param = new EffectParam();
        param.Resolved(0, 3.5).ShouldBe(3.5);
    }

    [Fact]
    public void ParamResolvedPrefersValueOverDefaultWhenTrackInactive()
    {
        var param = new EffectParam(1.0) { Track = new KeyframeTrack<double>() };
        param.Track.IsActive.ShouldBeFalse();
        param.Resolved(5, 9.0).ShouldBe(1.0);
    }

    [Fact]
    public void EffectParamOmitsNullFieldsOnWrite()
    {
        var json = JsonSerializer.Serialize(new EffectParam(1.5));
        var node = JsonNode.Parse(json)!.AsObject();
        node.ContainsKey("value").ShouldBeTrue();
        node.ContainsKey("string").ShouldBeFalse();
        node.ContainsKey("track").ShouldBeFalse();
    }
}
