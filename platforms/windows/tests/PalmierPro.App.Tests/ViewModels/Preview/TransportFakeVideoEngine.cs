using PalmierPro.Rendering;
using PalmierPro.Services.Engine;

namespace PalmierPro.App.Tests.ViewModels.Preview;

/// Hand-rolled <see cref="IVideoEngine"/> double for <c>TransportViewModelTests</c> — distinct from
/// <see cref="FakeVideoEngine"/> (that one's shaped for source-asset-preview scenarios) because this
/// one needs to (a) record every <see cref="Seek"/> call for assertion and (b) let a test manually
/// raise <see cref="PlayheadChanged"/>/<see cref="IsPlayingChanged"/> — field-like events can only
/// be invoked from inside their declaring type, so a shared fake can't expose that to callers.
internal sealed class TransportFakeVideoEngine : IVideoEngine
{
    public List<(string TimelineId, int Frame, PreviewSeekMode Mode)> SeekCalls { get; } = [];
    public List<string> PlayCalls { get; } = [];
    public List<string> PauseCalls { get; } = [];

    /// Mirrors `VideoEngine.Play`/`Pause` throwing (via `GetOpenTimelineOrThrow`) when no session is
    /// open yet for the target timeline — default false since a real session is normally already
    /// open by the time transport calls fire; a test flips this on to exercise the graceful-degrade
    /// race explicitly.
    public bool PlayPauseThrowsNoSession { get; set; }

    /// Mirrors `VideoEngine.Seek` throwing when no session is open yet for the target timeline.
    public bool SeekThrowsNoSession { get; set; }

    public Task OpenTimelineSessionAsync(string timelineId, TimelineSnapshotBuildResult snapshot, CancellationToken ct = default) =>
        Task.CompletedTask;

    public Task UpdateTimelineAsync(string timelineId, TimelineSnapshotBuildResult snapshot, CancellationToken ct = default) =>
        Task.CompletedTask;

    public void RefreshParams(TimelineParamPatch patch)
    {
    }

    public void EvictTimeline(string timelineId)
    {
    }

    public void Seek(string timelineId, int frame, PreviewSeekMode mode)
    {
        if (SeekThrowsNoSession)
        {
            throw new InvalidOperationException($"No open timeline session for '{timelineId}'.");
        }
        SeekCalls.Add((timelineId, frame, mode));
    }

    public void Play(string timelineId)
    {
        if (PlayPauseThrowsNoSession)
        {
            throw new InvalidOperationException($"No open timeline session for '{timelineId}'.");
        }
        PlayCalls.Add(timelineId);
    }

    public void Pause(string timelineId)
    {
        if (PlayPauseThrowsNoSession)
        {
            throw new InvalidOperationException($"No open timeline session for '{timelineId}'.");
        }
        PauseCalls.Add(timelineId);
    }

    public void SetRate(string timelineId, double rate) => throw new NotSupportedException();

    public Task<ColorScopesResult?> GetColorScopesAsync(string timelineId, int frame, CancellationToken ct = default) =>
        throw new NotSupportedException();

    public bool IsPlaying(string timelineId) => throw new NotSupportedException();

    public AudioLevels GetAudioLevels(string timelineId) => throw new NotSupportedException();

    public Task OpenAssetPreviewAsync(string mediaPath, CancellationToken ct = default) => Task.CompletedTask;

    public void SeekAssetPreview(int frame, PreviewSeekMode mode, int timelineFps)
    {
    }

    public void CloseAssetPreview()
    {
    }

    public void SetActiveTimeline(string? timelineId)
    {
    }

    public void SetAssetPreviewActive(bool active)
    {
    }

    public void AttachSwapChain(object swapChainPanel, int width, int height)
    {
    }

    public void ResizeSwapChain(int width, int height)
    {
    }

    public void DetachSwapChain()
    {
    }

    public void RaisePlayheadChanged(string timelineId, int frame) =>
        PlayheadChanged?.Invoke(this, new PlayheadChangedEventArgs(timelineId, frame));

    public void RaiseIsPlayingChanged(bool isPlaying) => IsPlayingChanged?.Invoke(this, isPlaying);

    public event EventHandler<PlayheadChangedEventArgs>? PlayheadChanged;

    public event EventHandler<bool>? IsPlayingChanged;

    public event EventHandler<MediaStatus>? MediaStatusChanged;
}
