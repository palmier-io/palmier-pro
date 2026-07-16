namespace PalmierPro.App.Controls;

/// Drag-vs-click pixel-threshold state machine — mirrors ScrubbableNumberField.swift's AppKit
/// ScrubArea (mouseDown/mouseDragged/mouseUp). Below the threshold, a full press+release is a
/// click (open text entry); past it, it's a scrub gesture the caller commits exactly once at
/// release, giving every drag a single undo entry regardless of how many pixels it crossed.
public sealed class ScrubGesture
{
    public const double DragThreshold = 3;

    private double _startX;

    public bool IsDragging { get; private set; }

    public void Begin(double startX)
    {
        _startX = startX;
        IsDragging = false;
    }

    /// Call on every pointer-move while pressed. Returns true the instant the threshold is
    /// crossed this gesture; false every other call (including once dragging is already true).
    public bool Update(double currentX, out double deltaX)
    {
        deltaX = currentX - _startX;
        if (IsDragging || Math.Abs(deltaX) <= DragThreshold)
        {
            return false;
        }
        IsDragging = true;
        return true;
    }

    /// Call on release/capture-loss. Returns true if the gesture ended as a drag (caller commits
    /// the live value); false if it was a click (caller opens text entry). Resets state either way.
    public bool End()
    {
        var wasDragging = IsDragging;
        IsDragging = false;
        return wasDragging;
    }
}
