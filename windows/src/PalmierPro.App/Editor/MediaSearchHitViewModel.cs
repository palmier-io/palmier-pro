namespace PalmierPro.App.Editor;

public sealed class MediaSearchHitViewModel
{
    public required string Title { get; init; }
    public required string Detail { get; init; }
    public string? MediaRef { get; init; }
    public int? StartFrame { get; init; }
}
