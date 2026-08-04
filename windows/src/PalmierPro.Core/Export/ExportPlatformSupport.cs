namespace PalmierPro.Core.Export;

/// <summary>
/// Windows-capable export formats and stable refusal text for platform limits.
/// </summary>
public static class ExportPlatformSupport
{
    public const string ProResUnsupportedMessage =
        "ProRes export is not available on Windows — Media Foundation has no ProRes encoder. Use H.264, H.265, or HEVC HDR.";

    public const string PalmierUnsupportedMessage =
        "mode=palmier failed — package path unavailable.";

    /// <summary>
    /// DNxHR / UtVideo are not exposed by Media Foundation. Use HEVC (H.265) with
    /// quality=mezzanine for a high-bitrate intermediate on Windows.
    /// </summary>
    public const string MezzanineGuidance =
        "Windows mezzanine: export codec=h265 with quality=mezzanine (high-bitrate HEVC). DNxHR and UtVideo are not available via Media Foundation.";

    /// <summary>Formats the export dialog and agent may offer as runnable.</summary>
    public static IReadOnlyList<ExportFormat> RunnableFormats { get; } =
    [
        ExportFormat.H264,
        ExportFormat.H265,
        ExportFormat.HevcHdr,
        ExportFormat.Fcpxml,
        ExportFormat.Xml,
        ExportFormat.Palmier,
    ];

    public static bool IsRunnable(ExportFormat format) => RunnableFormats.Contains(format);

    public static string? RefusalMessage(ExportFormat format) => format switch
    {
        ExportFormat.ProRes => ProResUnsupportedMessage,
        _ => IsRunnable(format) ? null : $"Export format not supported on Windows: {format}",
    };

    public static string DisplayName(ExportFormat format) => format switch
    {
        ExportFormat.H264 => "H.264 MPEG-4 (.mp4)",
        ExportFormat.H265 => "H.265 MPEG-4 (.mp4)",
        ExportFormat.HevcHdr => "HEVC 10-bit HDR (.mov)",
        ExportFormat.ProRes => "ProRes (.mov) — unavailable on Windows",
        ExportFormat.Fcpxml => "Final Cut Pro XML (.fcpxml)",
        ExportFormat.Xml => "Premiere XML (.xml)",
        ExportFormat.Palmier => "Palmier package (.palmier)",
        _ => format.ToString(),
    };

    public static string FileFilterLabel(ExportFormat format) => format switch
    {
        ExportFormat.H264 => "H.264 MPEG-4",
        ExportFormat.H265 => "H.265 MPEG-4",
        ExportFormat.HevcHdr => "HEVC 10-bit HDR",
        ExportFormat.Fcpxml => "Final Cut Pro XML",
        ExportFormat.Xml => "Premiere XML",
        ExportFormat.Palmier => "Palmier package",
        _ => format.ToString(),
    };
}
