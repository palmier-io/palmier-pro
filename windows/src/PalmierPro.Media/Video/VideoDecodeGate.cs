using PalmierPro.Core.Concurrency;

namespace PalmierPro.Media.Video;

/// <summary>Process-wide cap on concurrent Media Foundation source readers.</summary>
public static class VideoDecodeGate
{
    public const int MaxConcurrentDecoders = 4;

    private static readonly AsyncSemaphore Gate = new(MaxConcurrentDecoders);

    public static Task<IDisposable> EnterAsync(CancellationToken ct = default)
        => Gate.WaitAsync(ct);
}
