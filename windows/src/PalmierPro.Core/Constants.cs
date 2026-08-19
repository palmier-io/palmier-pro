namespace PalmierPro.Core;

public static class EditorDefaults
{
    public const double PixelsPerFrame = 4.0;
    public const double ImageDurationSeconds = 5.0;
    public const double AudioTTSDurationSeconds = 10.0;
    public const double AudioMusicDurationSeconds = 60.0;
    public const double TextDurationSeconds = 3.0;
    public const double AspectTolerance = 0.02;
}

public static class Snap
{
    public const double ThresholdPixels = 8.0;
    public const double StickyMultiplier = 1.5;
    public const double PlayheadMultiplier = 1.5;
}

public static class TrackSize
{
    public const double MinHeight = 32;
    public const double MaxHeight = 200;
    public const double ResizeHandleZone = 6;
}

public static class Zoom
{
    public const double Min = 0.05;
    public const double Floor = 0.0001;
    public const double Max = 40.0;
    public const double ToolbarStepFactor = 1.25;
    public const double ScrollSensitivity = 0.04;
    public const double MagnifySensitivity = 1.5;
    public const double PanSpeed = 5.0;
    public const double FitAllBuffer = 3.0;
}

public static class ProjectConstants
{
    public const string FileExtension = "palmier";
    public const string RegistryFilename = "project-registry.json";
    public const string TypeIdentifier = "io.palmier.project";
    public const string DefaultProjectName = "Untitled Project";
    public const string TimelineFilename = "project.json";
    public const string ManifestFilename = "media.json";
    public const string ThumbnailFilename = "thumbnail.jpg";
    public const string MediaDirectoryName = "media";
    public const string ChatDirectoryName = "chat";

    public static string StorageDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Palmier Pro");

    public static void EnsureStorageDirectory()
    {
        try
        {
            Directory.CreateDirectory(StorageDirectory);
        }
        catch
        {
            // Best-effort, mirrors the Swift try? behavior; failures surface on first real write.
        }
    }
}

public static class MathUtil
{
    public static int Gcd(int a, int b) => b == 0 ? a : Gcd(b, a % b);
}
