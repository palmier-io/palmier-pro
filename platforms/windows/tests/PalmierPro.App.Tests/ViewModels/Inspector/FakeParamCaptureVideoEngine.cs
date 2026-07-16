using PalmierPro.Rendering;
using PalmierPro.Services.Engine;

namespace PalmierPro.App.Tests.ViewModels.Inspector;

/// Hand-rolled <see cref="IVideoEngine"/> double for Transform/Color tab tests — only
/// <see cref="RefreshParams"/> (the live-drag fast path both tabs push to — see
/// TransformViewModel.PushLiveRefresh/ColorViewModel.PushWheelPreview) does anything, recording
/// every patch for assertions; everything else throws, matching FakeScopesVideoEngine's convention
/// of failing loudly on unexpected use rather than silently no-opping.
internal sealed class FakeParamCaptureVideoEngine : IVideoEngine
{
    public List<TimelineParamPatch> Patches { get; } = [];

    public void RefreshParams(TimelineParamPatch patch) => Patches.Add(patch);

    public Task OpenTimelineSessionAsync(string timelineId, TimelineSnapshotBuildResult snapshot, CancellationToken ct = default) =>
        throw new NotSupportedException();

    public Task UpdateTimelineAsync(string timelineId, TimelineSnapshotBuildResult snapshot, CancellationToken ct = default) =>
        throw new NotSupportedException();

    public void EvictTimeline(string timelineId) => throw new NotSupportedException();

    public void Seek(string timelineId, int frame, PreviewSeekMode mode) => throw new NotSupportedException();

    public void Play(string timelineId) => throw new NotSupportedException();

    public void Pause(string timelineId) => throw new NotSupportedException();

    public void SetRate(string timelineId, double rate) => throw new NotSupportedException();

    public Task<ColorScopesResult?> GetColorScopesAsync(string timelineId, int frame, CancellationToken ct = default) =>
        throw new NotSupportedException();

    public bool IsPlaying(string timelineId) => throw new NotSupportedException();

    public AudioLevels GetAudioLevels(string timelineId) => throw new NotSupportedException();

    public Task OpenAssetPreviewAsync(string mediaPath, CancellationToken ct = default) => throw new NotSupportedException();

    public void SeekAssetPreview(int frame, PreviewSeekMode mode, int timelineFps) => throw new NotSupportedException();

    public void CloseAssetPreview() => throw new NotSupportedException();

    public void SetActiveTimeline(string? timelineId) => throw new NotSupportedException();

    public void SetAssetPreviewActive(bool active) => throw new NotSupportedException();

    public void AttachSwapChain(object swapChainPanel, int width, int height) => throw new NotSupportedException();

    public void ResizeSwapChain(int width, int height) => throw new NotSupportedException();

    public void DetachSwapChain() => throw new NotSupportedException();

    public event EventHandler<PlayheadChangedEventArgs>? PlayheadChanged;
    public event EventHandler<bool>? IsPlayingChanged;
    public event EventHandler<MediaStatus>? MediaStatusChanged;
}
