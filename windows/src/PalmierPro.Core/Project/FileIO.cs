namespace PalmierPro.Core.Project;

public sealed class FileTooLargeException(string path, long actualBytes, long maxBytes)
    : IOException($"File {path} is {actualBytes} bytes; limit is {maxBytes}.")
{
    public long ActualBytes { get; } = actualBytes;
    public long MaxBytes { get; } = maxBytes;
}

/// <summary>
/// Synchronous file helpers. Callers are responsible for invoking these from an off-UI-thread context.
/// </summary>
public static class FileIO
{
    /// <summary>Write via a unique temp sibling then atomically move into place.</summary>
    public static void WriteAtomic(string path, byte[] data)
    {
        var directory = Path.GetDirectoryName(path)
            ?? throw new IOException($"No parent directory for {path}");
        Directory.CreateDirectory(directory);
        var temp = Path.Combine(directory, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllBytes(temp, data);
            File.Move(temp, path, overwrite: true);
        }
        catch
        {
            try
            {
                if (File.Exists(temp)) File.Delete(temp);
            }
            catch
            {
                // Cleanup is best-effort; the original error matters more.
            }
            throw;
        }
    }

    /// <summary>
    /// Copies a staged file to a hidden sibling of the package directory so the final
    /// install is a same-volume atomic move. Returns the prepared path.
    /// </summary>
    public static string PrepareStagedFile(string sourcePath, string packagePath, long? maxBytes = null)
    {
        var info = new FileInfo(sourcePath);
        if (!info.Exists) throw new FileNotFoundException("Staged file missing.", sourcePath);
        if (maxBytes is { } limit && info.Length > limit)
            throw new FileTooLargeException(sourcePath, info.Length, limit);

        var parent = Path.GetDirectoryName(Path.TrimEndingDirectorySeparator(packagePath))
            ?? throw new IOException($"No parent directory for {packagePath}");
        Directory.CreateDirectory(parent);
        var prepared = Path.Combine(parent, $".palmier-stage-{Guid.NewGuid():N}");
        try
        {
            File.Copy(sourcePath, prepared, overwrite: false);
            return prepared;
        }
        catch
        {
            try { if (File.Exists(prepared)) File.Delete(prepared); } catch { }
            throw;
        }
    }

    /// <summary>
    /// Moves a prepared same-volume file into its final destination, replacing any
    /// existing item. The prepared file is always consumed (deleted on failure).
    /// </summary>
    public static void InstallPreparedFile(string preparedPath, string destinationPath)
    {
        try
        {
            var directory = Path.GetDirectoryName(destinationPath)
                ?? throw new IOException($"No parent directory for {destinationPath}");
            Directory.CreateDirectory(directory);
            File.Move(preparedPath, destinationPath, overwrite: true);
        }
        finally
        {
            try { if (File.Exists(preparedPath)) File.Delete(preparedPath); } catch { }
        }
    }

    /// <summary>Move that replaces the destination and always consumes the source temp.</summary>
    public static void MoveReplacingDestination(string sourcePath, string destinationPath)
    {
        try
        {
            var directory = Path.GetDirectoryName(destinationPath)
                ?? throw new IOException($"No parent directory for {destinationPath}");
            Directory.CreateDirectory(directory);
            File.Move(sourcePath, destinationPath, overwrite: true);
        }
        finally
        {
            try { if (File.Exists(sourcePath)) File.Delete(sourcePath); } catch { }
        }
    }

    public static void CopyDirectory(string source, string destination)
    {
        Directory.CreateDirectory(destination);
        foreach (var dir in Directory.EnumerateDirectories(source, "*", SearchOption.AllDirectories))
        {
            Directory.CreateDirectory(Path.Combine(destination, Path.GetRelativePath(source, dir)));
        }
        foreach (var file in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
        {
            File.Copy(file, Path.Combine(destination, Path.GetRelativePath(source, file)), overwrite: true);
        }
    }
}
