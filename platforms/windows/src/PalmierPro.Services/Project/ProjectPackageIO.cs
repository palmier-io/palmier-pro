using System.Text.Json;
using PalmierPro.Core.Models;

namespace PalmierPro.Services.Project;

/// Thrown for a package that's missing its `project.json` or otherwise isn't a readable package
/// directory. Mirrors Swift's `requiredData` throwing `CocoaError(.fileReadCorruptFile)`.
public sealed class ProjectPackageCorruptException(string message) : Exception(message);

/// Decoded package contents. Ports `ProjectPackageContents` (`VideoProject.swift`).
public sealed record ProjectPackageContents(
    ProjectFile ProjectFile,
    MediaManifest? Manifest,
    GenerationLog? GenerationLog,
    bool ManifestUnreadable);

/// Encoded bytes ready to write. Ports `ProjectPackageSnapshot` (`VideoProject.swift`).
public sealed record ProjectPackageSnapshot(
    byte[] Timeline,
    byte[]? Manifest,
    byte[]? GenerationLog,
    byte[]? Thumbnail,
    IReadOnlyList<(string Name, byte[] Data)> ChatSessionFiles);

/// Reads/writes one package directory. Ports the file-level half of `VideoProject.swift`
/// (`readProjectPackage`/`writeProjectPackage` and their helpers) — document lifecycle
/// (dirty tracking, undo, autosave scheduling) lives in <see cref="ProjectDocument"/>.
public static class ProjectPackageIO
{
    public static ProjectPackageContents Load(string packageDirectory)
    {
        var timelinePath = ProjectPackage.TimelinePath(packageDirectory);
        if (!File.Exists(timelinePath))
        {
            throw new ProjectPackageCorruptException($"Missing {ProjectPackage.TimelineFilename} in '{packageDirectory}'.");
        }
        var projectFile = ProjectFile.Decode(File.ReadAllBytes(timelinePath));

        MediaManifest? manifest = null;
        var manifestUnreadable = false;
        var manifestPath = ProjectPackage.ManifestPath(packageDirectory);
        if (File.Exists(manifestPath))
        {
            try
            {
                manifest = JsonSerializer.Deserialize<MediaManifest>(File.ReadAllBytes(manifestPath));
                if (manifest is null)
                {
                    manifestUnreadable = true;
                }
            }
            catch (JsonException)
            {
                manifestUnreadable = true;
            }
        }

        GenerationLog? generationLog = null;
        var logPath = ProjectPackage.GenerationLogPath(packageDirectory);
        if (File.Exists(logPath))
        {
            try
            {
                generationLog = JsonSerializer.Deserialize<GenerationLog>(File.ReadAllBytes(logPath));
            }
            catch (JsonException)
            {
                generationLog = null;
            }
        }

        return new ProjectPackageContents(projectFile, manifest, generationLog, manifestUnreadable);
    }

    /// `loadFailed` guard from `VideoProject.manifestSnapshot(manifest:loadFailed:)`: if the
    /// on-disk manifest failed to decode and the in-memory one is still the untouched empty
    /// default, don't clobber the (recoverable) original with an empty one on save.
    public static MediaManifest? ManifestSnapshot(MediaManifest manifest, bool loadFailed)
    {
        if (loadFailed && manifest.Entries.Count == 0 && manifest.Folders.Count == 0)
        {
            return null;
        }
        return manifest;
    }

    public static void Write(ProjectPackageSnapshot snapshot, string packageDirectory, string? sourceDirectory)
    {
        CreatePackageDirectory(packageDirectory);
        AtomicFile.Write(ProjectPackage.TimelinePath(packageDirectory), snapshot.Timeline);

        if (snapshot.Manifest is { } manifestBytes)
        {
            AtomicFile.Write(ProjectPackage.ManifestPath(packageDirectory), manifestBytes);
        }
        else
        {
            CopyPreservedFile(ProjectPackage.ManifestFilename, sourceDirectory, packageDirectory);
        }

        if (snapshot.GenerationLog is { } logBytes)
        {
            AtomicFile.Write(ProjectPackage.GenerationLogPath(packageDirectory), logBytes);
        }

        if (snapshot.Thumbnail is { } thumbnailBytes)
        {
            AtomicFile.Write(ProjectPackage.ThumbnailPath(packageDirectory), thumbnailBytes);
        }
        else
        {
            CopyPreservedFile(ProjectPackage.ThumbnailFilename, sourceDirectory, packageDirectory);
        }

        WriteChatDirectory(snapshot.ChatSessionFiles, sourceDirectory, packageDirectory);
        CopyMediaDirectoryIfNeeded(sourceDirectory, packageDirectory);
    }

    private static void CreatePackageDirectory(string dir)
    {
        if (File.Exists(dir))
        {
            File.Delete(dir);
        }
        Directory.CreateDirectory(dir);
    }

    private static void CopyPreservedFile(string name, string? sourceDirectory, string packageDirectory)
    {
        if (sourceDirectory is null || SameDirectory(sourceDirectory, packageDirectory))
        {
            return;
        }
        var source = Path.Combine(sourceDirectory, name);
        if (!File.Exists(source))
        {
            return;
        }
        File.Copy(source, Path.Combine(packageDirectory, name), overwrite: true);
    }

    /// Swift always rewrites `chat/` from the live agent sessions (Windows has no agent service
    /// yet — Phase 2), so an empty file list here preserves whatever chat history the source
    /// package already had instead of wiping it on every save.
    private static void WriteChatDirectory(IReadOnlyList<(string Name, byte[] Data)> files, string? sourceDirectory, string packageDirectory)
    {
        var chatDir = ProjectPackage.ChatDirectoryPath(packageDirectory);
        if (files.Count == 0)
        {
            if (sourceDirectory is null || SameDirectory(sourceDirectory, packageDirectory))
            {
                return;
            }
            var source = ProjectPackage.ChatDirectoryPath(sourceDirectory);
            if (!Directory.Exists(source))
            {
                return;
            }
            if (Directory.Exists(chatDir))
            {
                Directory.Delete(chatDir, recursive: true);
            }
            DirectoryCopy.Recursive(source, chatDir);
            return;
        }

        if (Directory.Exists(chatDir))
        {
            Directory.Delete(chatDir, recursive: true);
        }
        Directory.CreateDirectory(chatDir);
        foreach (var (name, data) in files)
        {
            AtomicFile.Write(Path.Combine(chatDir, name), data);
        }
    }

    private static void CopyMediaDirectoryIfNeeded(string? sourceDirectory, string packageDirectory)
    {
        if (sourceDirectory is null || SameDirectory(sourceDirectory, packageDirectory))
        {
            return;
        }
        var source = ProjectPackage.MediaDirectoryPath(sourceDirectory);
        var destination = ProjectPackage.MediaDirectoryPath(packageDirectory);
        if (Directory.Exists(destination))
        {
            Directory.Delete(destination, recursive: true);
        }
        if (!Directory.Exists(source))
        {
            return;
        }
        DirectoryCopy.Recursive(source, destination);
    }

    private static bool SameDirectory(string a, string b) =>
        string.Equals(NormalizeDirectory(a), NormalizeDirectory(b), StringComparison.OrdinalIgnoreCase);

    private static string NormalizeDirectory(string path) =>
        Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
}

/// Temp-file-then-swap write, replacing Swift's `Data.write(options: .atomic)`. `File.Replace`
/// needs an existing destination (it fails outright on a brand-new file), so new files fall back
/// to a plain `File.Move` of the temp file into place — both are single rename-class filesystem
/// operations, so a crash/power-loss mid-write never leaves a half-written file at the real path.
internal static class AtomicFile
{
    public static void Write(string path, byte[] data)
    {
        var dir = Path.GetDirectoryName(path);
        if (string.IsNullOrEmpty(dir))
        {
            throw new ArgumentException($"'{path}' has no directory component.", nameof(path));
        }
        Directory.CreateDirectory(dir);
        var tmp = Path.Combine(dir, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
        File.WriteAllBytes(tmp, data);
        try
        {
            if (File.Exists(path))
            {
                File.Replace(tmp, path, null);
            }
            else
            {
                File.Move(tmp, path);
            }
        }
        catch
        {
            if (File.Exists(tmp))
            {
                File.Delete(tmp);
            }
            throw;
        }
    }
}

internal static class DirectoryCopy
{
    public static void Recursive(string sourceDirectory, string destinationDirectory)
    {
        Directory.CreateDirectory(destinationDirectory);
        foreach (var file in Directory.GetFiles(sourceDirectory))
        {
            File.Copy(file, Path.Combine(destinationDirectory, Path.GetFileName(file)), overwrite: true);
        }
        foreach (var dir in Directory.GetDirectories(sourceDirectory))
        {
            Recursive(dir, Path.Combine(destinationDirectory, Path.GetFileName(dir)));
        }
    }
}
