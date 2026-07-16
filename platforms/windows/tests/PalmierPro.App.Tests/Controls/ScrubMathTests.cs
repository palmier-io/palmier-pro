using PalmierPro.App.Controls;
using Shouldly;
using Xunit;

namespace PalmierPro.App.Tests.Controls;

/// Exercises ScrubMath against ScrubbableNumberField.swift/AdjustSlider.swift's actual math —
/// onDragChanged, commitEdit, and value(atX:width:).
public class ScrubMathTests
{
    // MARK: Clamp / fraction / position

    [Fact]
    public void ClampKeepsInRangeValuesUnchanged() =>
        ScrubMath.Clamp(5, 0, 10).ShouldBe(5);

    [Fact]
    public void ClampPinsBelowMinimum() =>
        ScrubMath.Clamp(-5, 0, 10).ShouldBe(0);

    [Fact]
    public void ClampPinsAboveMaximum() =>
        ScrubMath.Clamp(15, 0, 10).ShouldBe(10);

    [Fact]
    public void FractionOfMidpointIsOneHalf() =>
        ScrubMath.FractionOf(5, 0, 10).ShouldBe(0.5);

    [Fact]
    public void FractionOfDegenerateRangeIsZero() =>
        ScrubMath.FractionOf(5, 10, 10).ShouldBe(0);

    [Fact]
    public void ValueAtFractionRoundTripsFractionOf()
    {
        var value = ScrubMath.ValueAtFraction(ScrubMath.FractionOf(37, -50, 100), -50, 100);
        value.ShouldBe(37, 0.0001);
    }

    [Theory]
    [InlineData(0, 100, 0, 10)]
    [InlineData(50, 100, 0, 10, 5d)]
    [InlineData(100, 100, 0, 10)]
    [InlineData(-20, 100, 0, 10)] // negative x clamps to the low end, like AdjustSlider.value(atX:)
    [InlineData(200, 100, 0, 10)] // past the far edge clamps to the high end
    public void ValueAtPositionClampsAndScales(double x, double width, double min, double max, double? expected = null)
    {
        var result = ScrubMath.ValueAtPosition(x, width, min, max);
        var want = expected ?? (x <= 0 ? min : max);
        result.ShouldBe(want, 0.0001);
    }

    [Fact]
    public void ValueAtPositionWithZeroWidthIsMinimum() =>
        ScrubMath.ValueAtPosition(5, 0, -1, 1).ShouldBe(-1);

    // MARK: NextDragValue — Shift = coarse (10x), Alt = fine (0.1x)

    [Fact]
    public void NextDragValuePlainMovesByPixelDeltaOverMultiplier()
    {
        // displayMultiplier 1, dragSensitivity 1: 10px of drag = 10 units.
        ScrubMath.NextDragValue(0, 10, ScrubModifiers.None, 1, 1, -1000, 1000).ShouldBe(10);
    }

    [Fact]
    public void NextDragValueShiftIsTenTimesCoarser()
    {
        var plain = ScrubMath.NextDragValue(0, 10, ScrubModifiers.None, 1, 1, -1000, 1000);
        var shift = ScrubMath.NextDragValue(0, 10, ScrubModifiers.Shift, 1, 1, -1000, 1000);
        shift.ShouldBe(plain * 10);
    }

    [Fact]
    public void NextDragValueAltIsTenTimesFiner()
    {
        var plain = ScrubMath.NextDragValue(0, 10, ScrubModifiers.None, 1, 1, -1000, 1000);
        var alt = ScrubMath.NextDragValue(0, 10, ScrubModifiers.Alt, 1, 1, -1000, 1000);
        alt.ShouldBe(plain * 0.1, 0.0001);
    }

    [Fact]
    public void NextDragValueShiftAndAltCombineToNetPlainSensitivity()
    {
        // 10x coarse * 0.1x fine cancel back out to the unmodified sensitivity.
        var plain = ScrubMath.NextDragValue(0, 10, ScrubModifiers.None, 1, 1, -1000, 1000);
        var both = ScrubMath.NextDragValue(0, 10, ScrubModifiers.Shift | ScrubModifiers.Alt, 1, 1, -1000, 1000);
        both.ShouldBe(plain, 0.0001);
    }

    [Fact]
    public void NextDragValueDividesByDisplayMultiplier()
    {
        // A 0-1 raw range shown as a 0-100 percentage: 10px should move the raw value by 0.1.
        var next = ScrubMath.NextDragValue(0, 10, ScrubModifiers.None, 1, 100, 0, 1);
        next.ShouldBe(0.1, 0.0001);
    }

    [Fact]
    public void NextDragValueTreatsZeroDisplayMultiplierAsOne()
    {
        var withZero = ScrubMath.NextDragValue(0, 10, ScrubModifiers.None, 1, 0, -1000, 1000);
        var withOne = ScrubMath.NextDragValue(0, 10, ScrubModifiers.None, 1, 1, -1000, 1000);
        withZero.ShouldBe(withOne);
    }

    [Fact]
    public void NextDragValueClampsToRange() =>
        ScrubMath.NextDragValue(9, 100, ScrubModifiers.None, 1, 1, 0, 10).ShouldBe(10);

    // MARK: TryParseCommit — mirrors commitEdit's suffix-strip / comma-to-dot / clamp pipeline

    [Fact]
    public void TryParseCommitParsesPlainNumber()
    {
        ScrubMath.TryParseCommit("42", "", 1, 0, 100, out var result).ShouldBeTrue();
        result.ShouldBe(42);
    }

    [Fact]
    public void TryParseCommitStripsMatchingSuffix()
    {
        ScrubMath.TryParseCommit("50%", "%", 100, 0, 1, out var result).ShouldBeTrue();
        result.ShouldBe(0.5, 0.0001);
    }

    [Fact]
    public void TryParseCommitAcceptsCommaDecimal()
    {
        ScrubMath.TryParseCommit("3,5", "", 1, 0, 10, out var result).ShouldBeTrue();
        result.ShouldBe(3.5);
    }

    [Fact]
    public void TryParseCommitTrimsSurroundingWhitespaceBeforeAndAfterSuffixStrip()
    {
        ScrubMath.TryParseCommit("  12 dB  ", " dB", 1, -100, 100, out var result).ShouldBeTrue();
        result.ShouldBe(12);
    }

    [Fact]
    public void TryParseCommitClampsToRange()
    {
        ScrubMath.TryParseCommit("999", "", 1, 0, 100, out var result).ShouldBeTrue();
        result.ShouldBe(100);
    }

    [Fact]
    public void TryParseCommitRejectsUnparseableText()
    {
        ScrubMath.TryParseCommit("not a number", "", 1, 0, 100, out _).ShouldBeFalse();
    }

    [Fact]
    public void TryParseCommitDividesByDisplayMultiplier()
    {
        ScrubMath.TryParseCommit("50", "%", 100, 0, 1, out var result).ShouldBeTrue();
        result.ShouldBe(0.5, 0.0001);
    }

    // MARK: FormatDisplay — the "%.Nf" subset ScrubbableNumberField call sites actually use

    [Theory]
    [InlineData("%.0f", 3.7, "4")]
    [InlineData("%.1f", 3.14, "3.1")]
    [InlineData("%.2f", 3.14159, "3.14")]
    public void FormatDisplayHonorsPrintfPrecision(string format, double raw, string expected) =>
        ScrubMath.FormatDisplay(raw, 1, format, "").ShouldBe(expected);

    [Fact]
    public void FormatDisplayAppliesMultiplierAndSuffix() =>
        ScrubMath.FormatDisplay(0.5, 100, "%.0f", "%").ShouldBe("50%");
}
