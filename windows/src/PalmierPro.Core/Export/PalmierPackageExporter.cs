using System.IO.Compression;

namespace PalmierPro.Core.Export;

/// <summary>Copies or zips a live .palmier package directory to an export destination.</summary>
public static class PalmierPackageExporter
{
    public static ExportRunReport Export(string packagePath, string outputPath, bool overwrite)
    {
        if (!Directory.Exists(packagePath))
            throw new DirectoryNotFoundException($"Package not found: {packagePath}");

        var destFull = Path.GetFullPath(outputPath);
        var srcFull = Path.GetFullPath(packagePath);
        if (string.Equals(destFull, srcFull, StringComparison.OrdinalIgnoreCase)
            || destFull.StartsWith(srcFull + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Cannot export package onto itself.");

        if (File.Exists(destFull) || Directory.Exists(destFull))
        {
            if (!overwrite)
                throw new IOException($"Output already exists: {destFull}");
            if (Directory.Exists(destFull)) Directory.Delete(destFull, recursive: true);
            else File.Delete(destFull);
        }

        var parent = Path.GetDirectoryName(destFull);
        if (!string.IsNullOrEmpty(parent)) Directory.CreateDirectory(parent);

        // Prefer a directory package when the destination has no extension or ends with .palmier.
        var zip = destFull.EndsWith(".zip", StringComparison.OrdinalIgnoreCase);
        if (zip)
        {
            ZipFile.CreateFromDirectory(srcFull, destFull, CompressionLevel.Optimal, includeBaseDirectory: false);
        }
        else
        {
            CopyDirectory(srcFull, destFull);
        }

        long bytes = 0;
        if (File.Exists(destFull)) bytes = new FileInfo(destFull).Length;
        else if (Directory.Exists(destFull))
            bytes = Directory.EnumerateFiles(destFull, "*", SearchOption.AllDirectories)
                .Select(f => new FileInfo(f).Length).Sum();

        return new ExportRunReport
        {
            OutputBytes = bytes,
            Warnings = zip
                ? ["Exported as zip archive of the .palmier package."]
                : ["Exported as a .palmier package directory copy."],
        };
    }

    private static void CopyDirectory(string source, string dest)
    {
        Directory.CreateDirectory(dest);
        foreach (var file in Directory.GetFiles(source))
        {
            var name = Path.GetFileName(file);
            File.Copy(file, Path.Combine(dest, name), overwrite: true);
        }
        foreach (var dir in Directory.GetDirectories(source))
        {
            var name = Path.GetFileName(dir);
            CopyDirectory(dir, Path.Combine(dest, name));
        }
    }
}
