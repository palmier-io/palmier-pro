using System.IO.Compression;
using System.Text.Json;

namespace PalmierPro.Services.Media;

/// Shared dotLottie (`.lottie`, a zip archive per the dotLottie spec) -> plain-JSON extraction
/// (docs/lottie-bake-v1.md §12), used by both <see cref="LottieBakeService"/> (bake orchestration)
/// and <see cref="EngineMediaProbe"/> (metadata probe) — native only ever opens a plain-JSON Lottie
/// path; ThorVG has no dotLottie container awareness (see doc §12's rationale for resolving the
/// container C#-side via the BCL's <see cref="ZipFile"/> instead of vendoring a second native
/// zip/inflate dependency).
public static class DotLottieExtractor
{
    public static bool IsDotLottiePath(string path) =>
        string.Equals(Path.GetExtension(path), ".lottie", StringComparison.OrdinalIgnoreCase);

    /// Extracts the manifest-designated (or first) animation's JSON to `extractDir\animation.json`,
    /// and — when `includeAssets` — the whole `assets/` directory too, so an animation JSON that
    /// references an external raster asset by relative path still resolves relative to where it's
    /// extracted (§3's named v1 gap: rendering it is still deferred, but the path resolves). Callers
    /// own deleting `extractDir` when done. Throws <see cref="InvalidDataException"/> if the archive
    /// has no recognizable animation entry.
    public static string Extract(string lottiePath, string extractDir, bool includeAssets)
    {
        Directory.CreateDirectory(extractDir);
        using ZipArchive archive = ZipFile.OpenRead(lottiePath);

        string? animationId = ReadDefaultAnimationId(archive);
        ZipArchiveEntry? jsonEntry = animationId is not null
            ? archive.GetEntry($"animations/{animationId}.json")
            : null;
        jsonEntry ??= archive.Entries.FirstOrDefault(e =>
            e.FullName.StartsWith("animations/", StringComparison.OrdinalIgnoreCase) &&
            e.FullName.EndsWith(".json", StringComparison.OrdinalIgnoreCase));
        if (jsonEntry is null)
        {
            throw new InvalidDataException($"'{lottiePath}' has no animations/*.json entry.");
        }

        string jsonPath = Path.Combine(extractDir, "animation.json");
        jsonEntry.ExtractToFile(jsonPath, overwrite: true);

        if (includeAssets)
        {
            foreach (ZipArchiveEntry entry in archive.Entries)
            {
                if (entry.FullName.EndsWith('/') ||
                    !entry.FullName.StartsWith("assets/", StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }
                string destPath = Path.Combine(extractDir, entry.FullName.Replace('/', Path.DirectorySeparatorChar));
                Directory.CreateDirectory(Path.GetDirectoryName(destPath)!);
                entry.ExtractToFile(destPath, overwrite: true);
            }
        }

        return jsonPath;
    }

    /// `manifest.json`'s first (or manifest-designated default) `animations[].id` — null if the
    /// manifest is absent/malformed, so the caller falls back to the first `animations/*.json`.
    private static string? ReadDefaultAnimationId(ZipArchive archive)
    {
        ZipArchiveEntry? manifestEntry = archive.GetEntry("manifest.json");
        if (manifestEntry is null)
        {
            return null;
        }
        try
        {
            using Stream stream = manifestEntry.Open();
            using JsonDocument doc = JsonDocument.Parse(stream);
            if (doc.RootElement.TryGetProperty("activeAnimationId", out JsonElement active) && active.ValueKind == JsonValueKind.String)
            {
                return active.GetString();
            }
            if (doc.RootElement.TryGetProperty("animations", out JsonElement animations) &&
                animations.ValueKind == JsonValueKind.Array && animations.GetArrayLength() > 0 &&
                animations[0].TryGetProperty("id", out JsonElement id))
            {
                return id.GetString();
            }
        }
        catch (JsonException)
        {
        }
        return null;
    }
}
