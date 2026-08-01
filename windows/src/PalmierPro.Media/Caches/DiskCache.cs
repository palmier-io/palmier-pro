using System.Security.Cryptography;
using System.Text;

namespace PalmierPro.Media.Caches;

/// <summary>
/// Named disk cache directory under %LOCALAPPDATA%\PalmierPro\Caches, mirroring the Mac
/// app's ~/Library/Caches/PalmierPro/&lt;name&gt; layout.
/// </summary>
public sealed class DiskCache
{
    public string Directory { get; }

    public DiskCache(string name)
    {
        var root = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "PalmierPro", "Caches", name);
        System.IO.Directory.CreateDirectory(root);
        Directory = root;
    }

    public string PathFor(string fileName) => Path.Combine(Directory, fileName);

    public void Clear()
    {
        if (!System.IO.Directory.Exists(Directory)) return;
        foreach (var file in System.IO.Directory.EnumerateFileSystemEntries(Directory))
        {
            try
            {
                if (File.Exists(file)) File.Delete(file);
                else System.IO.Directory.Delete(file, recursive: true);
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    /// <summary>
    /// Content-identity key: SHA256("path|size|mtime") truncated to 16 bytes hex,
    /// so source file edits naturally invalidate cache entries. Returns null when
    /// the file is missing (offline media).
    /// </summary>
    public static string? KeyFor(string path)
    {
        FileInfo info;
        try
        {
            info = new FileInfo(path);
            if (!info.Exists) return null;
        }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }

        var mtime = info.LastWriteTimeUtc;
        var epochSeconds = (mtime - DateTime.UnixEpoch).TotalSeconds;
        var seed = $"{path}|{info.Length}|{epochSeconds}";
        var digest = SHA256.HashData(Encoding.UTF8.GetBytes(seed));
        var builder = new StringBuilder(32);
        for (var i = 0; i < 16; i++) builder.Append(digest[i].ToString("x2"));
        return builder.ToString();
    }
}
