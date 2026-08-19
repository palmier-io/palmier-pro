namespace PalmierPro.Media.Ml;

/// <summary>
/// Resolves optional ONNX assets under models/ (bundled, LocalAppData, or env overrides).
/// Missing files are normal — callers fall back to CPU stubs.
/// </summary>
public static class OnnxModelPaths
{
    public static string? ResolveSiglip()
        => Resolve("PALMIER_SIGLIP_MODEL", "siglip.onnx", "siglip_vision.onnx");

    public static string? ResolveDeepFilter()
        => Resolve("PALMIER_DEEPFILTER_MODEL", "deepfilter.onnx", "deepfilternet.onnx");

    public static string? ResolveBeat()
        => Resolve("PALMIER_BEAT_MODEL", "beat.onnx", "beat_tracker.onnx");

    public static string? ResolveSpeaker()
        => Resolve("PALMIER_SPEAKER_MODEL", "speaker.onnx", "speaker_embed.onnx");

    public static bool HasSiglip => ResolveSiglip() is not null;
    public static bool HasDeepFilter => ResolveDeepFilter() is not null;

    private static string? Resolve(string envName, params string[] fileNames)
    {
        var env = Environment.GetEnvironmentVariable(envName);
        if (!string.IsNullOrWhiteSpace(env) && File.Exists(env))
            return Path.GetFullPath(env);

        foreach (var dir in LocalModelPaths.CandidateModelDirectories())
        {
            if (!Directory.Exists(dir)) continue;
            foreach (var name in fileNames)
            {
                var path = Path.Combine(dir, name);
                if (File.Exists(path) && new FileInfo(path).Length > 256)
                    return path;
            }
        }
        return null;
    }
}
