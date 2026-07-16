using PalmierPro.Rendering;
using PalmierPro.Services.Engine;

namespace PalmierPro.App.Tests.ViewModels.Preview;

/// Hand-rolled <see cref="IVideoEngine"/> double for PreviewViewModel tests — mirrors the real
/// VideoEngine's swap-chain-exclusivity and "no session/no asset preview open" guard semantics
/// closely enough to catch a PreviewViewModel call-ordering bug, without needing a native
/// PalmierEngine.dll session (see MediaTabViewModelTests for the alternative, a real EngineSession,
/// which isn't an option here — asset preview needs a real decodable file).
internal sealed class FakeVideoEngine : IVideoEngine
{
    public List<string> OpenedOrUpdatedTimelineIds { get; } = [];
    public string? LastActiveTimelineId { get; private set; }
    public List<bool> AssetPreviewActiveCalls { get; } = [];
    public List<string> OpenAssetPreviewPaths { get; } = [];
    public List<(int Frame, PreviewSeekMode Mode, int TimelineFps)> AssetPreviewSeeks { get; } = [];
    public int CloseAssetPreviewCallCount { get; private set; }
    public bool IsAssetPreviewOpen { get; private set; }

    /// Set by a test to make the next <see cref="OpenAssetPreviewAsync"/> fail, mirroring a bad
    /// path/unreadable file — mirrors VideoEngine.OpenAssetPreviewAsync's own EngineException.
    public Exception? NextOpenAssetPreviewFailure { get; set; }

    public Task OpenTimelineSessionAsync(string timelineId, TimelineSnapshotBuildResult snapshot, CancellationToken ct = default)
    {
        OpenedOrUpdatedTimelineIds.Add(timelineId);
        return Task.CompletedTask;
    }

    public Task UpdateTimelineAsync(string timelineId, TimelineSnapshotBuildResult snapshot, CancellationToken ct = default)
    {
        OpenedOrUpdatedTimelineIds.Add(timelineId);
        return Task.CompletedTask;
    }

    public void RefreshParams(TimelineParamPatch patch)
    {
    }

    public void EvictTimeline(string timelineId)
    {
    }

    public void Seek(string timelineId, int frame, PreviewSeekMode mode)
    {
    }

    public void Play(string timelineId) => throw new NotSupportedException();

    public void Pause(string timelineId) => throw new NotSupportedException();

    public void SetRate(string timelineId, double rate) => throw new NotSupportedException();

    public Task<ColorScopesResult?> GetColorScopesAsync(string timelineId, int frame, CancellationToken ct = default) =>
        throw new NotSupportedException();

    public bool IsPlaying(string timelineId) => throw new NotSupportedException();

    public AudioLevels GetAudioLevels(string timelineId) => throw new NotSupportedException();

    public Task OpenAssetPreviewAsync(string mediaPath, CancellationToken ct = default)
    {
        if (NextOpenAssetPreviewFailure is { } failure)
        {
            NextOpenAssetPreviewFailure = null;
            return Task.FromException(failure);
        }
        OpenAssetPreviewPaths.Add(mediaPath);
        IsAssetPreviewOpen = true;
        return Task.CompletedTask;
    }

    public void SeekAssetPreview(int frame, PreviewSeekMode mode, int timelineFps)
    {
        if (!IsAssetPreviewOpen)
        {
            throw new InvalidOperationException("No asset preview is open — call OpenAssetPreviewAsync first.");
        }
        AssetPreviewSeeks.Add((frame, mode, timelineFps));
    }

    public void CloseAssetPreview()
    {
        CloseAssetPreviewCallCount++;
        IsAssetPreviewOpen = false;
    }

    public void SetActiveTimeline(string? timelineId) => LastActiveTimelineId = timelineId;

    public void SetAssetPreviewActive(bool active) => AssetPreviewActiveCalls.Add(active);

    public void AttachSwapChain(object swapChainPanel, int width, int height)
    {
    }

    public void ResizeSwapChain(int width, int height)
    {
    }

    public void DetachSwapChain()
    {
    }

    public event EventHandler<PlayheadChangedEventArgs>? PlayheadChanged;

    public event EventHandler<bool>? IsPlayingChanged;

    public event EventHandler<MediaStatus>? MediaStatusChanged;
}
