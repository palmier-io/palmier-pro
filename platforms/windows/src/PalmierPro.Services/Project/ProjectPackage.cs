namespace PalmierPro.Services.Project;

/// Package layout constants ported from `Utilities/Constants.swift`'s `enum Project`. On Windows
/// a `.palmier` package is a plain directory (there's no bundle/UTType-directory concept), so
/// every path helper below just joins onto that directory — no NSDocument-style opaque-file
/// treatment.
public static class ProjectPackage
{
    public const string FileExtension = "palmier";
    public const string TypeIdentifier = "io.palmier.project";
    public const string DefaultProjectName = "Untitled Project";
    public const string TimelineFilename = "project.json";
    public const string ManifestFilename = "media.json";
    public const string GenerationLogFilename = "generation-log.json";
    public const string ThumbnailFilename = "thumbnail.jpg";
    public const string MediaDirectoryName = "media";
    public const string ChatDirectoryName = "chat";
    public const string RegistryFilename = "project-registry.json";

    public static string TimelinePath(string packageDirectory) => Path.Combine(packageDirectory, TimelineFilename);
    public static string ManifestPath(string packageDirectory) => Path.Combine(packageDirectory, ManifestFilename);
    public static string GenerationLogPath(string packageDirectory) => Path.Combine(packageDirectory, GenerationLogFilename);
    public static string ThumbnailPath(string packageDirectory) => Path.Combine(packageDirectory, ThumbnailFilename);
    public static string MediaDirectoryPath(string packageDirectory) => Path.Combine(packageDirectory, MediaDirectoryName);
    public static string ChatDirectoryPath(string packageDirectory) => Path.Combine(packageDirectory, ChatDirectoryName);

    /// `directory/name.palmier` — the package's own root directory path.
    public static string PackagePath(string containingDirectory, string projectName) =>
        Path.Combine(containingDirectory, $"{projectName}.{FileExtension}");

    /// Windows equivalent of Swift's `Project.storageDirectory` (`~/Documents/Palmier Pro`) — the
    /// default location the Home browser offers for new/opened projects. Deliberately separate
    /// from <see cref="AppPaths.AppDataDirectory"/>, which holds per-machine app state (the
    /// registry), not user documents.
    public static string DefaultProjectsDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Palmier Pro");

    public static void EnsureDefaultProjectsDirectory() => Directory.CreateDirectory(DefaultProjectsDirectory);
}
