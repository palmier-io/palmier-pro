namespace PalmierPro.Core.Export;

public enum ExportFormat
{
    H264,
    H265,
    ProRes,
    HevcHdr,
    Xml,
    Fcpxml,
    Palmier,
}

public enum ExportResolution
{
    R720p,
    R1080p,
    R1440p,
    R4k,
    MatchTimeline,
}

public enum ExportJobStatus
{
    Queued,
    Preparing,
    Rendering,
    Canceling,
    Completed,
    Failed,
    Canceled,
}

public enum ExportJobSource
{
    Manual,
    Agent,
}

public static class ExportFormatExtensions
{
    public static string FileExtension(this ExportFormat format) => format switch
    {
        ExportFormat.H264 or ExportFormat.H265 => "mp4",
        ExportFormat.ProRes or ExportFormat.HevcHdr => "mov",
        ExportFormat.Xml => "xml",
        ExportFormat.Fcpxml => "fcpxml",
        ExportFormat.Palmier => "palmier",
        _ => "bin",
    };

    public static bool IsVideo(this ExportFormat format)
        => format is ExportFormat.H264 or ExportFormat.H265 or ExportFormat.ProRes or ExportFormat.HevcHdr;
}

public static class ExportResolutionMath
{
    public static int? ShortSidePixels(ExportResolution resolution) => resolution switch
    {
        ExportResolution.R720p => 720,
        ExportResolution.R1080p => 1080,
        ExportResolution.R1440p => 1440,
        ExportResolution.R4k => 2160,
        _ => null,
    };

    /// <summary>Even-dimension render size matching Mac ExportResolution.renderSize.</summary>
    public static (int Width, int Height) RenderSize(
        ExportResolution resolution, int canvasWidth, int canvasHeight)
    {
        if (ShortSidePixels(resolution) is not { } shortSide)
            return EvenSize(canvasWidth, canvasHeight);

        var canvasShort = Math.Min(canvasWidth, canvasHeight);
        if (canvasShort <= 0) return EvenSize(canvasWidth, canvasHeight);
        var scale = shortSide / (double)canvasShort;
        return EvenSize(
            (int)Math.Round(canvasWidth * scale),
            (int)Math.Round(canvasHeight * scale));
    }

    public static (int Width, int Height) EvenSize(int width, int height)
        => (Math.Max(2, width / 2 * 2), Math.Max(2, height / 2 * 2));
}

public sealed class ExportRequest
{
    public required string ProjectId { get; init; }
    public required string Filename { get; init; }
    public required string OutputPath { get; init; }
    public required ExportFormat Format { get; init; }
    public ExportResolution Resolution { get; init; } = ExportResolution.MatchTimeline;
    public ExportJobSource Source { get; init; } = ExportJobSource.Manual;
    public string? TimelineId { get; init; }
    public bool Overwrite { get; init; }
    /// <summary>delivery|high|mezzanine — mezzanine raises HEVC bitrate (Windows intermediate).</summary>
    public string? Quality { get; init; }
}

public sealed class ExportJob
{
    public string Id { get; init; } = Guid.NewGuid().ToString().ToUpperInvariant();
    public required string ProjectId { get; init; }
    public required string Filename { get; init; }
    public required string OutputPath { get; init; }
    public required ExportFormat Format { get; init; }
    public ExportResolution Resolution { get; init; }
    public ExportJobSource Source { get; init; }
    public string? TimelineId { get; init; }
    public string? Quality { get; set; }

    public ExportJobStatus Status { get; set; } = ExportJobStatus.Queued;
    public double Progress { get; set; }
    public string? Error { get; set; }
    public List<string> Warnings { get; } = [];
    public DateTimeOffset CreatedAt { get; init; } = DateTimeOffset.UtcNow;
    public DateTimeOffset? CompletedAt { get; set; }
}

public sealed class ExportRunReport
{
    public long OutputBytes { get; init; }
    public IReadOnlyList<string> OfflineMediaRefs { get; init; } = [];
    public IReadOnlyList<string> Warnings { get; init; } = [];
}
