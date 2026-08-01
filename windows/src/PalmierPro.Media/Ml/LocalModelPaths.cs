using PalmierPro.Core.Settings;

namespace PalmierPro.Media.Ml;

internal static class LocalModelPaths
{
    public static string PreferredWhisperSize
    {
        get
        {
            var size = (SettingsStore.Shared.Current.WhisperModelSize ?? "tiny").Trim().ToLowerInvariant();
            return size is "base" or "small" or "tiny" ? size : "tiny";
        }
    }

    public static string WhisperFileName(string size) => $"ggml-{size}.bin";

    public static string WhisperDownloadUrl(string size) =>
        $"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/{WhisperFileName(size)}";

    public static string? ResolveWhisperModel()
    {
        var env = Environment.GetEnvironmentVariable("PALMIER_WHISPER_MODEL");
        if (!string.IsNullOrWhiteSpace(env) && File.Exists(env))
            return Path.GetFullPath(env);

        var preferred = PreferredWhisperSize;
        // Prefer exact size, then fall back to best available (small > base > tiny).
        foreach (var size in PreferOrder(preferred))
        {
            foreach (var dir in CandidateModelDirectories())
            {
                var path = Path.Combine(dir, WhisperFileName(size));
                if (File.Exists(path)) return path;
            }
        }

        foreach (var dir in CandidateModelDirectories())
        {
            if (!Directory.Exists(dir)) continue;
            var match = Directory.GetFiles(dir, "ggml-*.bin")
                .OrderByDescending(RankWhisperFile)
                .FirstOrDefault();
            if (match is not null) return match;
        }
        return null;
    }

    public static string? ResolveSileroModel()
    {
        var env = Environment.GetEnvironmentVariable("PALMIER_SILERO_MODEL");
        if (!string.IsNullOrWhiteSpace(env) && File.Exists(env))
            return Path.GetFullPath(env);

        foreach (var dir in CandidateModelDirectories())
        {
            var path = Path.Combine(dir, "silero_vad.onnx");
            if (File.Exists(path)) return path;
        }
        return null;
    }

    public static IEnumerable<string> CandidateModelDirectories()
    {
        yield return Path.Combine(AppContext.BaseDirectory, "models");
        yield return ModelAssetInstaller.UserModelsDirectory;

        var dir = AppContext.BaseDirectory;
        for (var depth = 0; depth < 8 && !string.IsNullOrEmpty(dir); depth++)
        {
            var windowsModels = Path.Combine(dir, "windows", "models");
            if (Directory.Exists(windowsModels))
                yield return windowsModels;

            var siblingModels = Path.Combine(dir, "models");
            if (Directory.Exists(siblingModels))
                yield return siblingModels;

            dir = Directory.GetParent(dir)?.FullName ?? string.Empty;
        }
    }

    private static IEnumerable<string> PreferOrder(string preferred)
    {
        yield return preferred;
        foreach (var size in new[] { "small", "base", "tiny" })
            if (size != preferred) yield return size;
    }

    private static int RankWhisperFile(string path)
    {
        var name = Path.GetFileName(path).ToLowerInvariant();
        if (name.Contains("small")) return 3;
        if (name.Contains("base")) return 2;
        if (name.Contains("tiny")) return 1;
        return 0;
    }
}
