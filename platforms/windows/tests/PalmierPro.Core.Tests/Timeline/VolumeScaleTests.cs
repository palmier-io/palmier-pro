using PalmierPro.Core.Models;
using Shouldly;
using Xunit;

namespace PalmierPro.Core.Tests;

/// Ported from Inspector/InspectorView.swift's VolumeScale — hand-computed values, since the
/// Mac side has no dedicated test for this (found via grep, per the task brief).
public class VolumeScaleTests
{
    [Fact]
    public void LinearFromDbZeroIsUnityGain()
    {
        VolumeScale.LinearFromDb(0).ShouldBe(1.0, 1e-9);
    }

    [Fact]
    public void LinearFromDbMinusSixIsRoughlyHalf()
    {
        // 20*log10(0.5) ~= -6.02 dB.
        Math.Abs(VolumeScale.LinearFromDb(-6.0206) - 0.5).ShouldBeLessThan(1e-3);
    }

    [Fact]
    public void LinearFromDbAtOrBelowFloorIsZero()
    {
        VolumeScale.LinearFromDb(-60).ShouldBe(0.0);
        VolumeScale.LinearFromDb(-100).ShouldBe(0.0);
    }

    [Fact]
    public void LinearFromDbClampsAboveCeiling()
    {
        // Ceiling is 15 dB -> 10^(15/20).
        var expected = Math.Pow(10, 15.0 / 20);
        VolumeScale.LinearFromDb(15).ShouldBe(expected, 1e-9);
        VolumeScale.LinearFromDb(100).ShouldBe(expected, 1e-9); // clamps, doesn't keep climbing
    }

    [Fact]
    public void DbFromLinearZeroOrBelowSnapsToFloor()
    {
        VolumeScale.DbFromLinear(0).ShouldBe(VolumeScale.FloorDb);
        VolumeScale.DbFromLinear(-1).ShouldBe(VolumeScale.FloorDb);
    }

    [Fact]
    public void DbFromLinearUnityGainIsZeroDb()
    {
        VolumeScale.DbFromLinear(1.0).ShouldBe(0.0, 1e-9);
    }

    [Fact]
    public void DbFromLinearClampsToFloorAndCeiling()
    {
        VolumeScale.DbFromLinear(1e-9).ShouldBe(VolumeScale.FloorDb);
        VolumeScale.DbFromLinear(1000).ShouldBe(VolumeScale.CeilingDb);
    }

    [Fact]
    public void DbFromLinearAndLinearFromDbRoundTripInBounds()
    {
        foreach (var db in new[] { -40.0, -20.0, -6.0, 0.0, 6.0, 14.0 })
        {
            var linear = VolumeScale.LinearFromDb(db);
            var back = VolumeScale.DbFromLinear(linear);
            Math.Abs(back - db).ShouldBeLessThan(1e-6);
        }
    }
}
