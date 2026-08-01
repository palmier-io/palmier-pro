using PalmierPro.Core.Analysis;
using PalmierPro.Core.Transcription;

namespace PalmierPro.Media.Ml;

public static class LocalMlBootstrap
{
    private static int _registered;

    public static void EnsureRegistered()
    {
        if (Interlocked.CompareExchange(ref _registered, 1, 0) != 0) return;

        RegisterAvailableEngines();

        // Do not block UI startup on a multi‑MB download — fill LocalAppData in the background.
        if (LocalModelPaths.ResolveWhisperModel() is null || LocalModelPaths.ResolveSileroModel() is null)
        {
            _ = Task.Run(() =>
            {
                try
                {
                    ModelAssetInstaller.EnsureModelsPresent();
                    RefreshEngines();
                }
                catch { /* offline */ }
            });
        }
    }

    private static void RegisterAvailableEngines()
    {
        if (LocalStt.Transcriber is IDisposable previous)
        {
            try { previous.Dispose(); } catch { /* ignore */ }
            LocalStt.Transcriber = null;
        }

        var whisper = new WhisperEngine();
        if (whisper.IsAvailable)
            LocalStt.Transcriber = whisper;

        var silero = new SileroVadEngine();
        if (silero.IsAvailable)
            VadService.Engine = silero;
    }

    /// <summary>Re-scan after a background download or Whisper size change.</summary>
    public static void RefreshEngines() => RegisterAvailableEngines();
}
