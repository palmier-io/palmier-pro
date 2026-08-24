using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;

namespace PalmierPro.Media.Ml;

/// <summary>
/// Optional SigLIP ONNX visual embedder. Returns null when the model is absent or
/// the session cannot run — callers keep <see cref="EmbeddingMath.FrameFeatureEmbed"/>.
/// </summary>
public static class SiglipEmbedder
{
    private static readonly object Gate = new();
    private static InferenceSession? _session;
    private static bool _tried;

    public static float[]? TryEmbed(ReadOnlySpan<byte> bgra, int width, int height, int stride)
    {
        if (width < 8 || height < 8) return null;
        var session = GetSession();
        if (session is null) return null;

        try
        {
            // Resize/normalize into a common 224×224 RGB float tensor (NCHW).
            const int side = 224;
            var tensor = new DenseTensor<float>([1, 3, side, side]);
            for (var y = 0; y < side; y++)
            for (var x = 0; x < side; x++)
            {
                var sx = x * width / side;
                var sy = y * height / side;
                var i = sy * stride + sx * 4;
                if (i + 2 >= bgra.Length) continue;
                // BGRA → RGB, ImageNet-ish normalize.
                tensor[0, 0, y, x] = (bgra[i + 2] / 255f - 0.485f) / 0.229f;
                tensor[0, 1, y, x] = (bgra[i + 1] / 255f - 0.456f) / 0.224f;
                tensor[0, 2, y, x] = (bgra[i] / 255f - 0.406f) / 0.225f;
            }

            var inputName = session.InputMetadata.Keys.First();
            using var results = session.Run(
                [NamedOnnxValue.CreateFromTensor(inputName, tensor)]);
            var output = results.FirstOrDefault()?.AsEnumerable<float>().ToArray();
            if (output is null || output.Length == 0) return null;
            double n = 0;
            for (var i = 0; i < output.Length; i++) n += output[i] * output[i];
            if (n > 0)
            {
                var inv = (float)(1.0 / Math.Sqrt(n));
                for (var i = 0; i < output.Length; i++) output[i] *= inv;
            }
            return output;
        }
        catch
        {
            return null;
        }
    }

    private static InferenceSession? GetSession()
    {
        lock (Gate)
        {
            if (_tried) return _session;
            _tried = true;
            var path = OnnxModelPaths.ResolveSiglip();
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
