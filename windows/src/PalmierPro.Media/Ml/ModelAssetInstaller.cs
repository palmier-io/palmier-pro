namespace PalmierPro.Media.Ml;

/// <summary>
/// Ensures Whisper + Silero assets exist under LocalAppData (or windows/models).
/// Downloads the preferred Whisper size when missing.
/// </summary>
public static class ModelAssetInstaller
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromMinutes(30) };
    private static int _attempted;

    public static string UserModelsDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "PalmierPro", "models");

    public static void EnsureModelsPresent()
    {
        if (Interlocked.CompareExchange(ref _attempted, 1, 0) != 0) return;
        try
        {
            Directory.CreateDirectory(UserModelsDirectory);
            var size = LocalModelPaths.PreferredWhisperSize;
            var whisperDest = Path.Combine(UserModelsDirectory, LocalModelPaths.WhisperFileName(size));
            EnsureFile(
                LocalModelPaths.ResolveWhisperModel(),
                whisperDest,
                Environment.GetEnvironmentVariable("PALMIER_WHISPER_MODEL_URL")
                ?? LocalModelPaths.WhisperDownloadUrl(size));
            EnsureFile(
                LocalModelPaths.ResolveSileroModel(),
                Path.Combine(UserModelsDirectory, "silero_vad.onnx"),
                Environment.GetEnvironmentVariable("PALMIER_SILERO_MODEL_URL")
                ?? "https://github.com/snakers4/silero-vad/raw/master/src/silero_vad/data/silero_vad.onnx");
        }
        catch
        {
            // Offline — EnergyVad + placeholder STT remain available.
        }
    }

    /// <summary>Force download of a specific Whisper size into user models dir.</summary>
    public static async Task<string?> EnsureWhisperSizeAsync(string size, CancellationToken ct = default)
    {
        size = size.Trim().ToLowerInvariant();
        if (size is not ("tiny" or "base" or "small")) size = "tiny";
        Directory.CreateDirectory(UserModelsDirectory);
        var dest = Path.Combine(UserModelsDirectory, LocalModelPaths.WhisperFileName(size));
        if (File.Exists(dest) && new FileInfo(dest).Length > 1024) return dest;
        var url = LocalModelPaths.WhisperDownloadUrl(size);
        var tmp = dest + ".partial";
        try
        {
            using var response = await Http.GetAsync(url, ct).ConfigureAwait(false);
            response.EnsureSuccessStatusCode();
            await using var stream = await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
            await using var file = File.Create(tmp);
            await stream.CopyToAsync(file, ct).ConfigureAwait(false);
            await file.FlushAsync(ct).ConfigureAwait(false);
            File.Move(tmp, dest, overwrite: true);
            return dest;
        }
        catch
        {
            try { if (File.Exists(tmp)) File.Delete(tmp); } catch { }
            return File.Exists(dest) ? dest : null;
        }
    }

    private static void EnsureFile(string? existing, string dest, string url)
    {
        if (!string.IsNullOrWhiteSpace(existing) && File.Exists(existing)) return;
        if (File.Exists(dest) && new FileInfo(dest).Length > 1024) return;
        var tmp = dest + ".partial";
        try
        {
            using var response = Http.GetAsync(url).GetAwaiter().GetResult();
            response.EnsureSuccessStatusCode();
            using var stream = response.Content.ReadAsStream();
            using var file = File.Create(tmp);
            stream.CopyTo(file);
            file.Flush();
            File.Move(tmp, dest, overwrite: true);
        }
        catch
        {
            try { if (File.Exists(tmp)) File.Delete(tmp); } catch { }
            throw;
        }
    }
}
