using System.Text.Json;
using PalmierPro.Core.Models;

namespace PalmierPro.Services.Project;

/// Ports `PalmierProjectExporter` (`Export/PalmierProjectExporter.swift`): writes a
/// self-contained `.palmier` package, copying every resolvable media reference into the new
/// package's `media/` directory and rewriting it to a project-relative source.
public static class PalmierProjectExporter
{
    public sealed record MissingMedia(string Id, string Name);

    public sealed class Report
    {
        /// Entry ids that were external and are now bundled.
        public List<string> Collected { get; } = [];
        /// Already-internal media files copied across.
        public int CopiedInternal { get; set; }
        /// Entries whose source file couldn't be found, so they couldn't be included.
        public List<MissingMedia> Missing { get; } = [];
        /// Total bytes copied into the new package.
        public long TotalBytes { get; set; }

        public IReadOnlyList<string> Warnings
        {
            get
            {
                if (Missing.Count == 0)
                {
                    return [];
                }
                var files = Missing.Count == 1 ? "media file was" : "media files were";
                return [$"{Missing.Count} {files} missing and could not be included."];
            }
        }
    }

    public static Report Export(
        ProjectFile projectFile,
        MediaManifest manifest,
        GenerationLog generationLog,
        string? sourceProjectPath,
        string destinationPath,
        IProgress<double>? progress = null,
        CancellationToken cancellationToken = default)
    {
        var parent = Path.GetDirectoryName(Path.GetFullPath(destinationPath));
        if (string.IsNullOrEmpty(parent))
        {
            throw new ArgumentException($"'{destinationPath}' has no parent directory.", nameof(destinationPath));
        }
        Directory.CreateDirectory(parent);
        var staging = Path.Combine(parent, $".palmier-export-{Guid.NewGuid():N}.partial");
        var mediaDir = Path.Combine(staging, ProjectPackage.MediaDirectoryName);
        Directory.CreateDirectory(mediaDir);

        try
        {
            var report = new Report();
            var newEntries = new List<MediaManifestEntry>();
            // Dedup: absolute source path -> media/<file>, case-insensitive to match Windows paths.
            var relativePathBySource = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            var total = Math.Max(1, manifest.Entries.Count);

            for (var index = 0; index < manifest.Entries.Count; index++)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var entry = manifest.Entries[index];
                try
                {
                    var srcPath = SourcePath(entry.Source, sourceProjectPath);
                    if (srcPath is null || !File.Exists(srcPath))
                    {
                        report.Missing.Add(new MissingMedia(entry.Id, entry.Name));
                        newEntries.Add(entry);
                        continue;
                    }

                    var key = Path.GetFullPath(srcPath);
                    string relativePath;
                    if (relativePathBySource.TryGetValue(key, out var existingRelativePath))
                    {
                        relativePath = existingRelativePath;
                    }
                    else
                    {
                        var dest = UniquePath(mediaDir, FileNameFor(entry, srcPath));
                        CopyFile(srcPath, dest, cancellationToken);
                        relativePath = $"{ProjectPackage.MediaDirectoryName}/{Path.GetFileName(dest)}";
                        relativePathBySource[key] = relativePath;
                        report.TotalBytes += new FileInfo(dest).Length;
                        if (entry.Source.Kind == MediaSourceKind.Project)
                        {
                            report.CopiedInternal++;
                        }
                    }

                    if (entry.Source.Kind == MediaSourceKind.External)
                    {
                        report.Collected.Add(entry.Id);
                    }

                    var rewritten = CloneEntry(entry);
                    rewritten.Source = MediaSource.Project(relativePath);
                    newEntries.Add(rewritten);
                }
                finally
                {
                    progress?.Report((double)(index + 1) / total);
                }
            }

            var newManifest = new MediaManifest
            {
                Version = manifest.Version,
                Entries = newEntries,
                Folders = [.. manifest.Folders],
            };

            cancellationToken.ThrowIfCancellationRequested();
            File.WriteAllBytes(ProjectPackage.TimelinePath(staging), JsonSerializer.SerializeToUtf8Bytes(projectFile));
            File.WriteAllBytes(ProjectPackage.ManifestPath(staging), JsonSerializer.SerializeToUtf8Bytes(newManifest));
            File.WriteAllBytes(ProjectPackage.GenerationLogPath(staging), JsonSerializer.SerializeToUtf8Bytes(generationLog));

            // Carry across non-media package contents (thumbnail, chat history) when present.
            if (sourceProjectPath is not null)
            {
                cancellationToken.ThrowIfCancellationRequested();
                CopyFileIfPresent(ProjectPackage.ThumbnailFilename, sourceProjectPath, staging);
                CopyDirectoryIfPresent(ProjectPackage.ChatDirectoryName, sourceProjectPath, staging);
            }

            cancellationToken.ThrowIfCancellationRequested();
            ReplacePackageDirectory(staging, destinationPath);
            return report;
        }
        finally
        {
            if (Directory.Exists(staging))
            {
                Directory.Delete(staging, recursive: true);
            }
        }
    }

    /// `MediaManifestEntry` is a reference type (unlike Swift's value-type struct), so mutating a
    /// plain `entry` alias would corrupt the caller's original manifest — deep-clone via JSON
    /// round-trip first, mirroring `MediaResolver.Snapshot()`'s use of the same technique.
    private static MediaManifestEntry CloneEntry(MediaManifestEntry entry) =>
        JsonSerializer.Deserialize<MediaManifestEntry>(JsonSerializer.SerializeToUtf8Bytes(entry))!;

    private static string? SourcePath(MediaSource source, string? projectPath) => source.Kind switch
    {
        MediaSourceKind.External => source.Path,
        MediaSourceKind.Project => projectPath is null ? null : Path.Combine(projectPath, source.Path),
        _ => throw new ArgumentOutOfRangeException(nameof(source)),
    };

    private static string FileNameFor(MediaManifestEntry entry, string sourcePath) => entry.Source.Kind switch
    {
        MediaSourceKind.Project => Path.GetFileName(sourcePath), // preserve existing internal name
        MediaSourceKind.External => ImportName(entry, sourcePath),
        _ => throw new ArgumentOutOfRangeException(nameof(entry)),
    };

    private static string ImportName(MediaManifestEntry entry, string sourcePath)
    {
        var ext = Path.GetExtension(sourcePath); // includes the leading '.', or "" when absent
        var idPrefix = entry.Id.Length > 8 ? entry.Id[..8] : entry.Id;
        return $"import-{idPrefix}{ext}";
    }

    /// Appends `-1`, `-2`, … to avoid clobbering an already-written file of the same name.
    private static string UniquePath(string dir, string preferredName)
    {
        var candidate = Path.Combine(dir, preferredName);
        if (!File.Exists(candidate))
        {
            return candidate;
        }
        var ext = Path.GetExtension(preferredName);
        var baseName = Path.GetFileNameWithoutExtension(preferredName);
        var n = 1;
        while (true)
        {
            var path = Path.Combine(dir, $"{baseName}-{n}{ext}");
            if (!File.Exists(path))
            {
                return path;
            }
            n++;
        }
    }

    private static void CopyFile(string source, string destination, CancellationToken cancellationToken)
    {
        try
        {
            const int bufferSize = 4 * 1024 * 1024;
            using var reader = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read, bufferSize, FileOptions.SequentialScan);
            using var writer = new FileStream(destination, FileMode.Create, FileAccess.Write, FileShare.None, bufferSize);
            var buffer = new byte[bufferSize];
            int read;
            while ((read = reader.Read(buffer, 0, buffer.Length)) > 0)
            {
                cancellationToken.ThrowIfCancellationRequested();
                writer.Write(buffer, 0, read);
            }
        }
        catch
        {
            if (File.Exists(destination))
            {
                File.Delete(destination);
            }
            throw;
        }
    }

    private static void CopyFileIfPresent(string name, string sourceDirectory, string stagingDirectory)
    {
        var source = Path.Combine(sourceDirectory, name);
        if (!File.Exists(source))
        {
            return;
        }
        File.Copy(source, Path.Combine(stagingDirectory, name), overwrite: true);
    }

    private static void CopyDirectoryIfPresent(string name, string sourceDirectory, string stagingDirectory)
    {
        var source = Path.Combine(sourceDirectory, name);
        if (!Directory.Exists(source))
        {
            return;
        }
        DirectoryCopy.Recursive(source, Path.Combine(stagingDirectory, name));
    }

    /// Windows has no single-syscall atomic directory replace (unlike macOS's
    /// `FileManager.replaceItemAt` on a directory bundle): rename the existing package aside,
    /// swap the staged one in, then drop the old one — with rollback if the swap itself fails, so
    /// a mid-swap crash never leaves the destination missing.
    private static void ReplacePackageDirectory(string staging, string destination)
    {
        if (File.Exists(destination))
        {
            File.Delete(destination);
        }
        if (!Directory.Exists(destination))
        {
            Directory.Move(staging, destination);
            return;
        }

        var backup = $"{destination}.{Guid.NewGuid():N}.bak";
        Directory.Move(destination, backup);
        try
        {
            Directory.Move(staging, destination);
        }
        catch
        {
            if (Directory.Exists(destination))
            {
                Directory.Delete(destination, recursive: true);
            }
            Directory.Move(backup, destination);
            throw;
        }
        Directory.Delete(backup, recursive: true);
    }
}
