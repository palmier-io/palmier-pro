using PalmierPro.Rendering;
using PalmierPro.Services.Engine;

namespace PalmierPro.App.Tests.ViewModels.Inspector;

/// Hand-rolled <see cref="IVideoEngine"/> double for ScopesViewModelTests — only the members
/// ScopesViewModel actually calls (<see cref="GetColorScopesAsync"/>, <see cref="IsPlaying"/>,
/// <see cref="PlayheadChanged"/>, <see cref="IsPlayingChanged"/>) do anything; everything else
/// throws, matching FakeVideoEngine's (Preview tests) convention of failing loudly on unexpected
/// use rather than silently no-opping.
internal sealed class FakeScopesVideoEngine : IVideoEngine
{
    private readonly Queue<TaskCompletionSource<ColorScopesResult?>> _pending = new();

    public bool Playing { get; set; }

    public List<int> RequestedFrames { get; } = [];

    public Task<ColorScopesResult?> GetColorScopesAsync(string timelineId, int frame, CancellationToken ct = default)
    {
        RequestedFrames.Add(frame);
        var tcs = new TaskCompletionSource<ColorScopesResult?>();
        ct.Register(() => tcs.TrySetCanceled(ct));
        _pending.Enqueue(tcs);
        return tcs.Task;
    }

    /// Completes the oldest outstanding <see cref="GetColorScopesAsync"/> call, then yields once so
    /// ScopesViewModel's continuation (dispatched synchronously — tests never supply a real
    /// DispatcherQueue) has run before the caller inspects <see cref="RequestedFrames"/>/Result.
    public async Task Complete(ColorScopesResult? result)
    {
        _pending.Dequeue().SetResult(result);
        await Task.Yield();
    }

    public bool IsPlaying(string timelineId) => Playing;

    public void RaisePlayheadChanged(string timelineId, int frame) =>
        PlayheadChanged?.Invoke(this, new PlayheadChangedEventArgs(timelineId, frame));

    public void RaiseIsPlayingChanged(bool isPlaying) => IsPlayingChanged?.Invoke(this, isPlaying);

    public event EventHandler<PlayheadChangedEventArgs>? PlayheadChanged;
    public event EventHandler<bool>? IsPlayingChanged;
    public event EventHandler<MediaStatus>? MediaStatusChanged;

    public Task OpenTimelineSessionAsync(string timelineId, TimelineSnapshotBuildResult snapshot, CancellationToken ct = default) =>
        throw new NotSupportedException();

    public Task UpdateTimelineAsync(string timelineId, TimelineSnapshotBuildResult snapshot, CancellationToken ct = default) =>
        throw new NotSupportedException();

    public void RefreshParams(TimelineParamPatch patch) => throw new NotSupportedException();

    public void EvictTimeline(string timelineId) => throw new NotSupportedException();

    public void Seek(string timelineId, int frame, PreviewSeekMode mode) => throw new NotSupportedException();

    public void Play(string timelineId) => throw new NotSupportedException();

    public void Pause(string timelineId) => throw new NotSupportedException();

    public void SetRate(string timelineId, double rate) => throw new NotSupportedException();

    public AudioLevels GetAudioLevels(string timelineId) => throw new NotSupportedException();

    public Task OpenAssetPreviewAsync(string mediaPath, CancellationToken ct = default) => throw new NotSupportedException();

    public void SeekAssetPreview(int frame, PreviewSeekMode mode, int timelineFps) => throw new NotSupportedException();

    public void CloseAssetPreview() => throw new NotSupportedException();

    public void SetActiveTimeline(string? timelineId) => throw new NotSupportedException();

    public void SetAssetPreviewActive(bool active) => throw new NotSupportedException();

    public void AttachSwapChain(object swapChainPanel, int width, int height) => throw new NotSupportedException();

    public void ResizeSwapChain(int width, int height) => throw new NotSupportedException();

    public void DetachSwapChain() => throw new NotSupportedException();
}
