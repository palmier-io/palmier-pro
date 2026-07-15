namespace PalmierPro.App.Editing;

/// Drag/zoom/trim constants mirrored from Utilities/Constants.swift's `Zoom`/`Snap`/`Trim`/
/// `TimelineAutoScroll` enums — the counterparts to `TimelineGeometry.Layout` (which already
/// mirrors that file's `Layout` enum). Kept local to `PalmierPro.App` rather than `AppThemeTokens`
/// for the same reason `TimelineGeometry.Layout` is: these are editor-interaction constants, not
/// design-system tokens — the Mac keeps them in a separate file from AppTheme.swift too.
public static class TimelineInputConstants
{
    public static class Zoom
    {
        public const double Min = 0.05;
        public const double Max = 40.0;
        public const double ToolbarStepFactor = 1.25;
        /// Multiplies a wheel-delta before exponentiating — see <see cref="TimelineZoom.Apply"/>.
        public const double ScrollSensitivity = 0.04;
    }

    public static class Snap
    {
        public const double ThresholdPixels = 8.0;
        public const double StickyMultiplier = 1.5;
        public const double PlayheadMultiplier = 1.5;
    }

    /// Mac's `Trim.handleWidth` is 4pt (trackpad-precise); widened here for a mouse-driven app.
    public static class Trim
    {
        public const double HandleWidth = 6.0;
    }

    public static class DragState
    {
        public const double ThresholdPixels = 3.0;
    }
}
