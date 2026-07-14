using System.Text.Json;
using PalmierPro.Core.Models;
using Shouldly;
using Xunit;

namespace PalmierPro.Core.Tests;

/// Mirrors GradeCurve.swift's pure math (GradeCurveKernelTests.swift exercises the CoreImage
/// rendering half, which has no Core analog yet — see EffectTests.cs's split for the same reason).
public class GradeCurveEvalTests
{
    [Fact]
    public void EmptyPointsUseIdentityAndPassThrough()
    {
        GradeCurve.Eval([], 0.3).ShouldBe(0.3);
        GradeCurve.Eval([], 0.0).ShouldBe(0.0);
        GradeCurve.Eval([], 1.0).ShouldBe(1.0);
    }

    [Fact]
    public void ClampsFlatBelowFirstPoint()
    {
        List<CurvePoint> pts = [new(0.2, 0.5), new(0.8, 0.9)];
        GradeCurve.Eval(pts, 0.0).ShouldBe(0.5);
        GradeCurve.Eval(pts, -1.0).ShouldBe(0.5);
    }

    [Fact]
    public void ClampsFlatAboveLastPoint()
    {
        List<CurvePoint> pts = [new(0.2, 0.5), new(0.8, 0.9)];
        GradeCurve.Eval(pts, 1.0).ShouldBe(0.9);
        GradeCurve.Eval(pts, 2.0).ShouldBe(0.9);
    }

    [Fact]
    public void InterpolatesLinearlyBetweenTwoPoints()
    {
        List<CurvePoint> pts = [new(0, 0), new(1, 1)];
        GradeCurve.Eval(pts, 0.25).ShouldBe(0.25);
        GradeCurve.Eval(pts, 0.5).ShouldBe(0.5, 1e-12);
        GradeCurve.Eval(pts, 0.75).ShouldBe(0.75, 1e-12);
    }

    [Fact]
    public void UnsortedInputIsSortedBeforeEvaluating()
    {
        List<CurvePoint> pts = [new(1, 1), new(0, 0), new(0.5, 0.5)];
        GradeCurve.Eval(pts, 0.25).ShouldBe(0.25, 1e-12);
    }

    [Fact]
    public void ThreePointCurveSelectsCorrectSegment()
    {
        List<CurvePoint> pts = [new(0, 0), new(0.5, 0.8), new(1, 1)];
        // Below the midpoint uses segment [0, 0.5] -> [0, 0.8].
        GradeCurve.Eval(pts, 0.25).ShouldBe(0.4, 1e-12);
        // Above the midpoint uses segment [0.5, 1] -> [0.8, 1].
        GradeCurve.Eval(pts, 0.75).ShouldBe(0.9, 1e-12);
    }

    [Fact]
    public void SinglePointCoversTheWholeDomain()
    {
        List<CurvePoint> pts = [new(0.5, 0.7)];
        GradeCurve.Eval(pts, 0.0).ShouldBe(0.7);
        GradeCurve.Eval(pts, 0.5).ShouldBe(0.7);
        GradeCurve.Eval(pts, 1.0).ShouldBe(0.7);
    }
}

public class GradeCurveIdentityTests
{
    [Fact]
    public void FreshCurveIsIdentity()
    {
        new GradeCurve().IsIdentity.ShouldBeTrue();
    }

    [Fact]
    public void ExplicitIdentityPointsAreStillIdentity()
    {
        var curve = new GradeCurve { Master = [new CurvePoint(0, 0), new CurvePoint(1, 1)] };
        curve.IsIdentity.ShouldBeTrue();
    }

    [Fact]
    public void AnyNonIdentityChannelBreaksIdentity()
    {
        var curve = new GradeCurve { Red = [new CurvePoint(0, 0), new CurvePoint(0.5, 0.8), new CurvePoint(1, 1)] };
        curve.IsIdentity.ShouldBeFalse();
    }

    [Fact]
    public void PointOrderMattersForIdentityLikeSwiftArrayEquality()
    {
        // Swift's Equatable array comparison is order-sensitive; reversing the identity points
        // must NOT still read as identity.
        var curve = new GradeCurve { Master = [new CurvePoint(1, 1), new CurvePoint(0, 0)] };
        curve.IsIdentity.ShouldBeFalse();
    }
}

public class GradeCurveJsonTests
{
    [Fact]
    public void ToJsonAndFromJsonRoundTrip()
    {
        var curve = new GradeCurve
        {
            Master = [new CurvePoint(0, 0), new CurvePoint(1, 1)],
            Red = [new CurvePoint(0, 0.1), new CurvePoint(1, 0.9)],
        };
        var json = curve.ToJson()!;
        var decoded = GradeCurve.FromJson(json)!;
        decoded.Master.Count.ShouldBe(2);
        decoded.Red[0].Y.ShouldBe(0.1);
        decoded.Green.ShouldBeEmpty();
    }

    [Fact]
    public void FromJsonReturnsNullOnGarbage()
    {
        GradeCurve.FromJson("not json").ShouldBeNull();
        GradeCurve.FromJson("{}").ShouldBeNull(); // master/red/green/blue all required
    }

    [Fact]
    public void FullFixtureRoundTripsThroughJsonSerializer()
    {
        const string json = """{"master": [{"x": 0, "y": 0}, {"x": 1, "y": 1}], "red": [], "green": [], "blue": []}""";
        var curve = JsonSerializer.Deserialize<GradeCurve>(json)!;
        curve.Master.Count.ShouldBe(2);
        curve.IsIdentity.ShouldBeTrue();
        var reencoded = JsonSerializer.Serialize(curve);
        JsonSerializer.Deserialize<GradeCurve>(reencoded)!.Master[1].Y.ShouldBe(1);
    }

    [Theory]
    [InlineData("""{"red": [], "green": [], "blue": []}""")] // missing master
    [InlineData("""{"master": [], "green": [], "blue": []}""")] // missing red
    [InlineData("""{"master": [], "red": [], "blue": []}""")] // missing green
    [InlineData("""{"master": [], "red": [], "green": []}""")] // missing blue
    public void ThrowsWhenARequiredChannelIsMissing(string json)
    {
        Should.Throw<JsonException>(() => JsonSerializer.Deserialize<GradeCurve>(json));
    }

    [Fact]
    public void CurvePointThrowsWhenYIsMissing()
    {
        Should.Throw<JsonException>(() => JsonSerializer.Deserialize<CurvePoint>("""{"x": 0.5}"""));
    }
}
