using NAudio.Wave;
using PalmierPro.Core.Analysis;
using PalmierPro.Media.Ml;

namespace PalmierPro.Media.Audio;

/// <summary>
/// Bakes a denoised WAV beside the package cache. Prefer DeepFilter ONNX when
/// <c>PALMIER_DEEPFILTER_MODEL</c> / models/deepfilter.onnx exists; else spectral gate.
/// </summary>
public static class AudioEnhancer
{
    public static string CacheDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "PalmierPro", "denoise");

    public static string? CachedDenoisedPath(string mediaRef)
    {
        var path = Path.Combine(CacheDirectory, Sanitize(mediaRef) + ".wav");
        return File.Exists(path) ? path : null;
    }

    public static string BakeDenoisedWav(string sourcePath, string mediaRef, double amount)
    {
        Directory.CreateDirectory(CacheDirectory);
        var dest = Path.Combine(CacheDirectory, Sanitize(mediaRef) + ".wav");
        if (File.Exists(dest)) return dest;

        var mono = AudioPcmDecoder.DecodeMono(sourcePath, TimelineAudioPlayerSampleRate());
        var wet = DeepFilterDenoiser.TryDenoise(mono, amount)
                  ?? SpectralGateDenoiser.Process(mono, amount);

        WriteMonoWav(dest, wet, TimelineAudioPlayerSampleRate());
        return dest;
    }

    public static bool TryBake(string sourcePath, string mediaRef, double amount, out string? path, out string note)
    {
        try
        {
            Directory.CreateDirectory(CacheDirectory);
            var dest = Path.Combine(CacheDirectory, Sanitize(mediaRef) + ".wav");
            var usedDeepFilter = false;
            if (!File.Exists(dest))
            {
                var mono = AudioPcmDecoder.DecodeMono(sourcePath, TimelineAudioPlayerSampleRate());
                var df = DeepFilterDenoiser.TryDenoise(mono, amount);
                usedDeepFilter = df is not null;
                WriteMonoWav(dest, df ?? SpectralGateDenoiser.Process(mono, amount), TimelineAudioPlayerSampleRate());
            }

            path = dest;
            note = usedDeepFilter
                ? "Denoised WAV baked with DeepFilter ONNX."
                : DeepFilterDenoiser.IsAvailable
                    ? "Denoised WAV baked with spectral gate (DeepFilter ONNX present but not runnable)."
                    : "Denoised WAV baked with spectral gate (DeepFilter model not present).";
            return true;
        }
        catch (Exception ex)
        {
            path = null;
            note = $"Denoise bake failed: {ex.Message}";
            return false;
        }
    }

    private static int TimelineAudioPlayerSampleRate() => 48000;

    private static void WriteMonoWav(string path, float[] samples, int sampleRate)
    {
        var staging = path + ".partial";
        using (var writer = new WaveFileWriter(staging, WaveFormat.CreateIeeeFloatWaveFormat(sampleRate, 1)))
            writer.WriteSamples(samples, 0, samples.Length);
        File.Move(staging, path, overwrite: true);
    }

    private static string Sanitize(string id)
    {
        foreach (var c in Path.GetInvalidFileNameChars())
            id = id.Replace(c, '_');
        return id.Length > 64 ? id[..64] : id;
    }
}
