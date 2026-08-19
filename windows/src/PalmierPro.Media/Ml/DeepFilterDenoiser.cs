using Microsoft.ML.OnnxRuntime;

namespace PalmierPro.Media.Ml;

/// <summary>
/// Optional DeepFilter ONNX denoise. Platform substitute: Mac uses DeepFilterNet3 via MLX;
/// Windows uses spectral-gate denoise until a packaged DeepFilterNet ONNX with documented
/// multi-tensor STFT I/O ships. This type only probes model presence.
/// </summary>
public static class DeepFilterDenoiser
{
    private static readonly object Gate = new();
    private static InferenceSession? _session;
    private static bool _tried;

    /// <summary>
    /// Always returns null today — spectral gate is the Windows denoise path.
    /// Kept so fetch-models -Extra and IsAvailable stay meaningful for future I/O wiring.
    /// </summary>
    public static float[]? TryDenoise(float[] mono, double amount)
    {
        if (mono.Length == 0) return null;
        var session = GetSession();
        if (session is null) return null;
        _ = session;
        _ = amount;
        return null;
    }

    public static bool IsAvailable => OnnxModelPaths.ResolveDeepFilter() is not null;

    private static InferenceSession? GetSession()
    {
        lock (Gate)
        {
            if (_tried) return _session;
            _tried = true;
            var path = OnnxModelPaths.ResolveDeepFilter();
            if (path is null) return null;
            try
            {
                _session = new InferenceSession(path);
            }
            catch
            {
                _session = null;
            }
            return _session;
        }
    }
}
