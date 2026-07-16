namespace PalmierPro.Rendering;

/// Mirrors native `PE_LottieInfo` (docs/lottie-bake-v1.md §8) — the metadata
/// <see cref="EngineSession.ProbeLottieMetadata"/> returns.
public sealed record LottieInfo(double DurationSeconds, double Width, double Height, double FrameRate);
