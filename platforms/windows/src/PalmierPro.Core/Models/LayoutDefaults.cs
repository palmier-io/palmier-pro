namespace PalmierPro.Core.Models;

/// Subset of Utilities/Constants.swift needed by the timeline model cluster (Track.displayHeight
/// clamping, TimelineViewState's default zoom). The rest of Constants.swift is UI layout — belongs
/// with the App/ViewModel port, not Core.
public static class TrackSize
{
    public const double MinHeight = 32;
    public const double MaxHeight = 200;
}

public static class Defaults
{
    public const double PixelsPerFrame = 4.0;
    public const double ImageDurationSeconds = 5.0;
}
