using PalmierPro.Core.Models;
using PalmierPro.Core.Serialization;

namespace PalmierPro.Core.Project;

public sealed class ProjectPackageContents
{
    public required ProjectFile ProjectFile { get; init; }
    public MediaManifest? Manifest { get; init; }
    public bool ManifestUnreadable { get; init; }
}

public sealed class ProjectPackageSnapshot
{
    public required byte[] Timeline { get; init; }
    public byte[]? Manifest { get; init; }
    public byte[]? Thumbnail { get; init; }
    public List<(string Name, byte[] Data)> ChatSessionFiles { get; init; } = [];
}

/// <summary>
/// Reads and writes .palmier directory packages with the exact layout the macOS app uses:
/// project.json, media.json, thumbnail.jpg, media/, chat/.
/// </summary>
public static class ProjectPackage
{
    public static ProjectPackageContents Read(string packagePath)
    {
        var timelinePath = Path.Combine(packagePath, ProjectConstants.TimelineFilename);
        byte[] data;
        try
        {
            data = File.ReadAllBytes(timelinePath);
        }
        catch (Exception e)
        {
            throw new IOException($"Missing {ProjectConstants.TimelineFilename} in package {packagePath}", e);
        }

        var projectFile = ProjectFile.Decode(data);

        MediaManifest? manifest = null;
        var manifestUnreadable = false;
        var manifestPath = Path.Combine(packagePath, ProjectConstants.ManifestFilename);
        if (File.Exists(manifestPath))
        {
            try
            {
                manifest = PalmierJson.Decode<MediaManifest>(File.ReadAllBytes(manifestPath));
            }
            catch
            {
                // A bad manifest must not lose the project; degrade to "media offline" and keep the file for recovery.
                manifestUnreadable = true;
            }
        }

        return new ProjectPackageContents
        {
            ProjectFile = projectFile,
            Manifest = manifest,
            ManifestUnreadable = manifestUnreadable,
        };
    }

    public static void Write(ProjectPackageSnapshot snapshot, string packagePath, string? sourcePath)
    {
        CreatePackageDirectory(packagePath);
        FileIO.WriteAtomic(Path.Combine(packagePath, ProjectConstants.TimelineFilename), snapshot.Timeline);

        if (snapshot.Manifest is { } manifest)
        {
            FileIO.WriteAtomic(Path.Combine(packagePath, ProjectConstants.ManifestFilename), manifest);
        }
        else
        {
            CopyPreservedFile(ProjectConstants.ManifestFilename, sourcePath, packagePath);
        }

        if (snapshot.Thumbnail is { } thumbnail)
        {
            FileIO.WriteAtomic(Path.Combine(packagePath, ProjectConstants.ThumbnailFilename), thumbnail);
        }
        else
        {
            CopyPreservedFile(ProjectConstants.ThumbnailFilename, sourcePath, packagePath);
        }

        WriteChatDirectory(snapshot.ChatSessionFiles, packagePath);
        CopyMediaDirectoryIfNeeded(sourcePath, packagePath);
        Directory.CreateDirectory(Path.Combine(packagePath, ProjectConstants.MediaDirectoryName));
    }

    private static void CreatePackageDirectory(string path)
    {
        if (File.Exists(path))
        {
            File.Delete(path);
        }
        Directory.CreateDirectory(path);
    }

    private static void WriteChatDirectory(List<(string Name, byte[] Data)> files, string packagePath)
    {
        var chatPath = Path.Combine(packagePath, ProjectConstants.ChatDirectoryName);
        if (Directory.Exists(chatPath))
        {
            Directory.Delete(chatPath, recursive: true);
        }
        Directory.CreateDirectory(chatPath);
        foreach (var (name, data) in files)
        {
            FileIO.WriteAtomic(Path.Combine(chatPath, name), data);
        }
    }

    private static void CopyPreservedFile(string name, string? sourcePath, string packagePath)
    {
        if (sourcePath is null || SamePath(sourcePath, packagePath)) return;
        var source = Path.Combine(sourcePath, name);
        if (!File.Exists(source)) return;
        File.Copy(source, Path.Combine(packagePath, name), overwrite: true);
    }

    private static void CopyMediaDirectoryIfNeeded(string? sourcePath, string packagePath)
    {
        if (sourcePath is null || SamePath(sourcePath, packagePath)) return;
        var source = Path.Combine(sourcePath, ProjectConstants.MediaDirectoryName);
        var destination = Path.Combine(packagePath, ProjectConstants.MediaDirectoryName);
        if (Directory.Exists(destination))
        {
            Directory.Delete(destination, recursive: true);
        }
        if (!Directory.Exists(source)) return;
        FileIO.CopyDirectory(source, destination);
    }

    private static bool SamePath(string lhs, string rhs)
        => string.Equals(Path.GetFullPath(lhs).TrimEnd(Path.DirectorySeparatorChar),
            Path.GetFullPath(rhs).TrimEnd(Path.DirectorySeparatorChar),
            StringComparison.OrdinalIgnoreCase);
}
