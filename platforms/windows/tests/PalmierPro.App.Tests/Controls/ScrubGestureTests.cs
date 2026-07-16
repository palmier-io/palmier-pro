using PalmierPro.App.Controls;
using Shouldly;
using Xunit;

namespace PalmierPro.App.Tests.Controls;

/// Exercises ScrubGesture against the Mac's AppKit ScrubArea (mouseDown/mouseDragged/mouseUp) in
/// ScrubbableNumberField.swift — the drag-vs-click threshold and the "commit fires once per
/// gesture end" invariant ScrubbableNumberBox/ParamSlider both depend on for single undo entries.
public class ScrubGestureTests
{
    [Fact]
    public void FreshGestureIsNotDragging()
    {
        var gesture = new ScrubGesture();
        gesture.IsDragging.ShouldBeFalse();
    }

    [Fact]
    public void MovementAtOrBelowThresholdDoesNotStartDragging()
    {
        var gesture = new ScrubGesture();
        gesture.Begin(100);
        gesture.Update(100 + ScrubGesture.DragThreshold, out _).ShouldBeFalse();
        gesture.IsDragging.ShouldBeFalse();
    }

    [Fact]
    public void MovementPastThresholdStartsDragging()
    {
        var gesture = new ScrubGesture();
        gesture.Begin(100);
        gesture.Update(100 + ScrubGesture.DragThreshold + 1, out var deltaX).ShouldBeTrue();
        gesture.IsDragging.ShouldBeTrue();
        deltaX.ShouldBe(ScrubGesture.DragThreshold + 1);
    }

    [Fact]
    public void ThresholdCrossingIsOnlySignaledOnce()
    {
        var gesture = new ScrubGesture();
        gesture.Begin(0);
        gesture.Update(10, out _).ShouldBeTrue(); // crosses here
        gesture.Update(11, out _).ShouldBeFalse(); // already dragging — no second "just started" signal
        gesture.Update(50, out _).ShouldBeFalse();
        gesture.IsDragging.ShouldBeTrue();
    }

    [Fact]
    public void DeltaXIsRelativeToPressPositionNotPreviousMove()
    {
        var gesture = new ScrubGesture();
        gesture.Begin(100);
        gesture.Update(150, out var firstDelta);
        gesture.Update(180, out var secondDelta);
        firstDelta.ShouldBe(50);
        secondDelta.ShouldBe(80); // cumulative from the press, not incremental
    }

    [Fact]
    public void NegativeMovementPastThresholdStartsDragging()
    {
        var gesture = new ScrubGesture();
        gesture.Begin(100);
        gesture.Update(100 - ScrubGesture.DragThreshold - 1, out var deltaX).ShouldBeTrue();
        deltaX.ShouldBe(-(ScrubGesture.DragThreshold + 1));
    }

    [Fact]
    public void EndWithoutCrossingThresholdIsAClick()
    {
        var gesture = new ScrubGesture();
        gesture.Begin(0);
        gesture.Update(1, out _);
        gesture.End().ShouldBeFalse();
        gesture.IsDragging.ShouldBeFalse();
    }

    [Fact]
    public void EndAfterCrossingThresholdIsADrag()
    {
        var gesture = new ScrubGesture();
        gesture.Begin(0);
        gesture.Update(10, out _);
        gesture.End().ShouldBeTrue();
    }

    [Fact]
    public void EndResetsDraggingSoASecondGestureStartsClean()
    {
        var gesture = new ScrubGesture();
        gesture.Begin(0);
        gesture.Update(10, out _);
        gesture.End();
        gesture.IsDragging.ShouldBeFalse();

        gesture.Begin(0);
        gesture.IsDragging.ShouldBeFalse();
        gesture.Update(1, out _).ShouldBeFalse(); // fresh gesture — old drag state doesn't leak
    }

    [Fact]
    public void EndWithoutAnyUpdateIsAClick()
    {
        var gesture = new ScrubGesture();
        gesture.Begin(0);
        gesture.End().ShouldBeFalse();
    }

    [Fact]
    public void BeginMidGestureResetsDragging()
    {
        var gesture = new ScrubGesture();
        gesture.Begin(0);
        gesture.Update(10, out _);
        gesture.IsDragging.ShouldBeTrue();

        gesture.Begin(500); // e.g. a capture-loss cleanup follow by a fresh press
        gesture.IsDragging.ShouldBeFalse();
    }
}
