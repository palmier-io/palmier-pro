namespace PalmierPro.Core.Project;

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
