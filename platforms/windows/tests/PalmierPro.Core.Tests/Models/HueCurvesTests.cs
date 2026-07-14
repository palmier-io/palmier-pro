using System.Text.Json;
using PalmierPro.Core.Models;
using Shouldly;
using Xunit;

namespace PalmierPro.Core.Tests;

/// Mirrors the pure-math/model half of HueCurves.swift + Tests/PalmierProTests/Rendering/HueCurvesTests.swift
/// (the CoreImage rendering half, HueCurveKernel, has no Core analog yet).
public class HueCurvesEvalTests
{
    [Fact]
    public void EmptyPointsUseDefaultPointsAllNeutral()
    {
        HueCurves.Eval([], 0.1).ShouldBe(HueCurves.NeutralY);
        HueCurves.Eval([], 0.9).ShouldBe(HueCurves.NeutralY);
    }

    [Fact]
    public void CyclicEvalIsSeamlessAtHueWrap()
    {
        // Ported directly from the Swift test of the same name.
        List<CurvePoint> pts = [new(0, 0.9), new(5.0 / 6, 0.2)];
        var nearOne = HueCurves.Eval(pts, 0.999);
        var atZero = HueCurves.Eval(pts, 0.0);
        Math.Abs(nearOne - atZero).ShouldBeLessThan(0.05);
    }

    [Fact]
    public void WrapsPastLastPointTowardFirst()
    {
        List<CurvePoint> pts = [new(0, 0.2), new(0.5, 0.8)];
        // x=0.75 is between the last point (0.5) and the wrapped first point (1.0, y=0.2) -> midway.
        HueCurves.Eval(pts, 0.75).ShouldBe(0.5, 1e-12);
    }

    [Fact]
    public void WrapsBeforeFirstPointTowardLast()
    {
        List<CurvePoint> pts = [new(0.5, 0.8), new(0.9, 0.4)];
        // x=0.2 is before the first point (0.5); wraps from the last point shifted by -1: (-0.1, 0.4).
        // t = (0.2 - -0.1) / (0.5 - -0.1) = 0.5 -> lerp(0.4, 0.8, 0.5) = 0.6.
        HueCurves.Eval(pts, 0.2).ShouldBe(0.6, 1e-12);
    }

    [Fact]
    public void DefaultPointsHaveSixEntriesAtNeutral()
    {
        HueCurves.DefaultPoints.Count.ShouldBe(6);
        HueCurves.DefaultPoints.ShouldAllBe(p => p.Y == HueCurves.NeutralY);
        HueCurves.DefaultPoints[1].X.ShouldBe(1.0 / 6, 1e-12);
    }
}

public class HueCurvesIdentityTests
{
    [Fact]
    public void FreshCurvesAreIdentity()
    {
        new HueCurves().IsIdentity.ShouldBeTrue();
    }

    [Fact]
    public void IsNeutralAcceptsEmptyOrAllAtNeutralY()
    {
        HueCurves.IsNeutral([]).ShouldBeTrue();
        HueCurves.IsNeutral([new CurvePoint(0, 0.5), new CurvePoint(0.5, 0.5)]).ShouldBeTrue();
        HueCurves.IsNeutral([new CurvePoint(0, 0.9)]).ShouldBeFalse();
    }

    [Fact]
    public void AnyPushedChannelBreaksIdentity()
    {
        var curves = new HueCurves { HueVsSat = [new CurvePoint(0, 0.9)] };
        curves.IsIdentity.ShouldBeFalse();
    }

    [Fact]
    public void PointsAndSetRoundTripPerChannel()
    {
        var curves = new HueCurves();
        var pts = new List<CurvePoint> { new(0, 0.7) };
        curves.Set(HueCurvesChannel.Sat, pts);
        curves.Points(HueCurvesChannel.Sat).ShouldBe(pts);
        curves.Points(HueCurvesChannel.Hue).ShouldBeEmpty();
    }
}

public class HueCurvesJsonTests
{
    [Fact]
    public void ToJsonAndFromJsonRoundTrip()
    {
        var curves = new HueCurves { HueVsHue = [new CurvePoint(0, 0.8)] };
        var json = curves.ToJson()!;
        var decoded = HueCurves.FromJson(json)!;
        decoded.HueVsHue[0].Y.ShouldBe(0.8);
    }

    [Fact]
    public void FromJsonReturnsNullOnGarbage()
    {
        HueCurves.FromJson("nope").ShouldBeNull();
        HueCurves.FromJson("{}").ShouldBeNull(); // all three channels required
    }

    [Theory]
    [InlineData("""{"hueVsSat": [], "hueVsLum": []}""")] // missing hueVsHue
    [InlineData("""{"hueVsHue": [], "hueVsLum": []}""")] // missing hueVsSat
    [InlineData("""{"hueVsHue": [], "hueVsSat": []}""")] // missing hueVsLum
    public void ThrowsWhenARequiredChannelIsMissing(string json)
    {
        Should.Throw<JsonException>(() => JsonSerializer.Deserialize<HueCurves>(json));
    }

    [Fact]
    public void FullFixtureRoundTripsThroughJsonSerializer()
    {
        const string json = """{"hueVsHue": [{"x": 0, "y": 0.6}], "hueVsSat": [], "hueVsLum": []}""";
        var curves = JsonSerializer.Deserialize<HueCurves>(json)!;
        curves.HueVsHue[0].Y.ShouldBe(0.6);
        var reencoded = JsonSerializer.Serialize(curves);
        JsonSerializer.Deserialize<HueCurves>(reencoded)!.HueVsHue[0].Y.ShouldBe(0.6);
    }
}

/// Mirrors HueCurves.read(from:)/upsert(into:), including canonical insertion order.
public class HueCurvesEffectUpsertTests
{
    [Fact]
    public void ReadReturnsIdentityWhenNoMatchingEffectExists()
    {
        HueCurves.Read([]).IsIdentity.ShouldBeTrue();
    }

    [Fact]
    public void UpsertOnIdentityRemovesAnExistingEffectAndAddsNothing()
    {
        var effects = new List<Effect> { new(HueCurves.EffectType) };
        new HueCurves().Upsert(effects);
        effects.ShouldBeEmpty();
    }

    [Fact]
    public void UpsertInsertsANewEffectWhenNonIdentity()
    {
        List<Effect> effects = [];
        var curves = new HueCurves { HueVsHue = [new CurvePoint(0, 0.9)] };
        curves.Upsert(effects);
        effects.Count.ShouldBe(1);
        effects[0].Type.ShouldBe(HueCurves.EffectType);
        effects[0].Params["curves"].StringValue.ShouldNotBeNull();
    }

    [Fact]
    public void UpsertUpdatesAnExistingEffectInPlaceRatherThanDuplicating()
    {
        var existing = new Effect(HueCurves.EffectType);
        existing.Params["curves"] = new EffectParam(stringValue: "{}");
        List<Effect> effects = [existing];

        var curves = new HueCurves { HueVsSat = [new CurvePoint(0, 0.9)] };
        curves.Upsert(effects);

        effects.Count.ShouldBe(1);
        ReferenceEquals(effects[0], existing).ShouldBeTrue();
    }

    [Fact]
    public void ReadRoundTripsWhatUpsertWrote()
    {
        List<Effect> effects = [];
        var curves = new HueCurves { HueVsLum = [new CurvePoint(0, 0.3), new CurvePoint(0.5, 0.7)] };
        curves.Upsert(effects);

        var readBack = HueCurves.Read(effects);
        readBack.HueVsLum.Count.ShouldBe(2);
        readBack.HueVsLum[1].Y.ShouldBe(0.7);
    }

    [Fact]
    public void UpsertInsertsAtTheCanonicalPositionBetweenCurvesAndLut()
    {
        List<Effect> effects =
        [
            new("color.curves"),
            new("color.lut"),
            new("stylize.grain"),
        ];
        var curves = new HueCurves { HueVsHue = [new CurvePoint(0, 0.9)] };
        curves.Upsert(effects);

        effects.Select(e => e.Type).ShouldBe(["color.curves", HueCurves.EffectType, "color.lut", "stylize.grain"]);
    }

    [Fact]
    public void UpsertAppendsAtTheEndWhenNoLaterCanonicalEffectExists()
    {
        List<Effect> effects = [new("color.exposure")];
        var curves = new HueCurves { HueVsHue = [new CurvePoint(0, 0.9)] };
        curves.Upsert(effects);
        effects[^1].Type.ShouldBe(HueCurves.EffectType);
    }

    [Fact]
    public void UpsertInsertsBeforeAnUnknownEffectType()
    {
        // An effect type absent from the canonical order ranks as Int.max, i.e. always "after".
        List<Effect> effects = [new("some.future.effect")];
        var curves = new HueCurves { HueVsHue = [new CurvePoint(0, 0.9)] };
        curves.Upsert(effects);
        effects.Select(e => e.Type).ShouldBe([HueCurves.EffectType, "some.future.effect"]);
    }
}
