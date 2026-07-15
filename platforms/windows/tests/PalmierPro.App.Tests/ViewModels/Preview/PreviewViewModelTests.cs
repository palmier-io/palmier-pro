using PalmierPro.App.ViewModels.Editor;
using PalmierPro.App.ViewModels.Preview;
using PalmierPro.App.Tests.ViewModels.Editor;
using PalmierPro.Core.Models;
using PalmierPro.Rendering;
using PalmierPro.Services.Engine;
using Shouldly;
using Xunit;

namespace PalmierPro.App.Tests.ViewModels.Preview;

/// PreviewViewModel's source-asset preview toggle (M4, Stage D) — mode switching and asset-preview
/// session lifetime against a <see cref="FakeVideoEngine"/> double (no native engine/decodable
/// file needed; see that class's remarks). Timeline-session composition itself
/// (TimelineSnapshotBuilder output, media status) is TimelineSnapshotBuilderTests' territory.
public sealed class PreviewViewModelTests
{
    private static MediaAsset MakeAsset(string name = "Clip", double duration = 4.0, int? width = 640, int? height = 360) =>
        new($@"C:\fake\{name}.mp4", ClipType.Video, name, duration: duration) { SourceWidth = width, SourceHeight = height };

    private static async Task<(PreviewViewModel Preview, FakeVideoEngine Engine, TempDirectory Temp)> MakeAsync()
    {
        var (timeline, temp) = await EditorFixtures.MakeAsync();
        var engine = new FakeVideoEngine();
        var preview = new PreviewViewModel(timeline.Document, timeline, engine);
        await WaitUntilAsync(() => engine.OpenedOrUpdatedTimelineIds.Contains(timeline.ActiveTimelineId));
        return (preview, engine, temp);
    }

    private static async Task WaitUntilAsync(Func<bool> condition, int timeoutMs = 5_000)
    {
        var deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (DateTime.UtcNow < deadline)
        {
            if (condition())
            {
                return;
            }
            await Task.Delay(10);
        }
        condition().ShouldBeTrue("timed out waiting for condition");
    }

    [Fact]
    public async Task Construction_opens_the_active_timeline_session_and_starts_in_Timeline_mode()
    {
        var (preview, engine, temp) = await MakeAsync();
        using var t = temp;
        using var p = preview;

        preview.Mode.ShouldBe(PreviewMode.Timeline);
        preview.SourceAsset.ShouldBeNull();
        engine.LastActiveTimelineId.ShouldBe(preview.Timeline.ActiveTimelineId);
    }

    [Fact]
    public async Task OpenSourcePreviewAsync_switches_to_Source_mode_and_activates_the_asset_preview_surface()
    {
        var (preview, engine, temp) = await MakeAsync();
        using var t = temp;
        using var p = preview;
        var asset = MakeAsset();
        var modeChangedCount = 0;
        preview.ModeChanged += (_, _) => modeChangedCount++;

        await preview.OpenSourcePreviewAsync(asset);

        preview.Mode.ShouldBe(PreviewMode.Source);
        preview.SourceAsset.ShouldBe(asset);
        engine.OpenAssetPreviewPaths.ShouldBe([asset.Url]);
        engine.AssetPreviewActiveCalls.ShouldBe([true]);
        engine.AssetPreviewSeeks.ShouldBe([(0, PreviewSeekMode.Exact, preview.Timeline.Timeline.Fps)]);
        modeChangedCount.ShouldBe(1);
    }

    [Fact]
    public async Task OpenSourcePreviewAsync_does_not_disturb_the_timelines_own_active_designation()
    {
        var (preview, engine, temp) = await MakeAsync();
        using var t = temp;
        using var p = preview;
        var timelineId = preview.Timeline.ActiveTimelineId;

        await preview.OpenSourcePreviewAsync(MakeAsset());

        // SetAssetPreviewActive(true) is how the swap chain actually moves — SetActiveTimeline's
        // own bookkeeping is untouched, so ShowTimeline can hand the swap chain straight back
        // without re-resolving which timeline that even was.
        engine.LastActiveTimelineId.ShouldBe(timelineId);
    }

    [Fact]
    public async Task ShowTimeline_reverts_mode_and_closes_the_asset_preview_cleanly()
    {
        var (preview, engine, temp) = await MakeAsync();
        using var t = temp;
        using var p = preview;
        await preview.OpenSourcePreviewAsync(MakeAsset());
        var modeChangedCount = 0;
        preview.ModeChanged += (_, _) => modeChangedCount++;

        preview.ShowTimeline();

        preview.Mode.ShouldBe(PreviewMode.Timeline);
        preview.SourceAsset.ShouldBeNull();
        engine.CloseAssetPreviewCallCount.ShouldBe(1);
        engine.IsAssetPreviewOpen.ShouldBeFalse();
        modeChangedCount.ShouldBe(1);
    }

    [Fact]
    public async Task ShowTimeline_while_already_on_Timeline_is_a_noop()
    {
        var (preview, engine, temp) = await MakeAsync();
        using var t = temp;
        using var p = preview;
        var modeChangedCount = 0;
        preview.ModeChanged += (_, _) => modeChangedCount++;

        preview.ShowTimeline();

        engine.CloseAssetPreviewCallCount.ShouldBe(0);
        modeChangedCount.ShouldBe(0);
    }

    [Fact]
    public async Task OpenSourcePreviewAsync_failure_leaves_the_current_view_untouched()
    {
        var (preview, engine, temp) = await MakeAsync();
        using var t = temp;
        using var p = preview;
        engine.NextOpenAssetPreviewFailure = new EngineException(1, "decode failed");
        var modeChangedCount = 0;
        preview.ModeChanged += (_, _) => modeChangedCount++;

        await preview.OpenSourcePreviewAsync(MakeAsset("Broken"));

        preview.Mode.ShouldBe(PreviewMode.Timeline);
        preview.SourceAsset.ShouldBeNull();
        engine.AssetPreviewActiveCalls.ShouldBeEmpty();
        modeChangedCount.ShouldBe(0);
    }

    [Fact]
    public async Task SeekSource_in_Timeline_mode_does_not_call_the_engine()
    {
        var (preview, engine, temp) = await MakeAsync();
        using var t = temp;
        using var p = preview;

        preview.SeekSource(10);

        engine.AssetPreviewSeeks.ShouldBeEmpty();
    }

    [Fact]
    public async Task SeekSource_in_Source_mode_forwards_to_the_engine_and_clamps_to_duration()
    {
        var (preview, engine, temp) = await MakeAsync();
        using var t = temp;
        using var p = preview;
        // 2s asset at the fixture timeline's 30fps default → 60 frames.
        await preview.OpenSourcePreviewAsync(MakeAsset(duration: 2.0));
        engine.AssetPreviewSeeks.Clear();

        preview.SeekSource(1_000, PreviewSeekMode.InteractiveScrub);

        preview.SourceFrame.ShouldBe(preview.SourceDurationFrames);
        engine.AssetPreviewSeeks.ShouldBe(
            [(preview.SourceDurationFrames, PreviewSeekMode.InteractiveScrub, preview.Timeline.Timeline.Fps)]);
    }

    // Regression coverage for the source-preview fps mismatch bug: `SeekSource`/
    // `OpenSourcePreviewAsync` must forward the ACTIVE TIMELINE's fps (not some fixed/default
    // value, and not anything asset-derived — this ViewModel never even sees the asset's own
    // decoded fps) on every engine seek call, since VideoEngine.PerformAssetPreviewSeek now
    // divides `frame` by whatever fps it's given. A timeline fps that differs from the fixture's
    // 30fps default (see FakeVideoEngine's remarks) proves this isn't a coincidental match.
    [Fact]
    public async Task SeekSource_and_OpenSourcePreviewAsync_forward_the_timelines_own_fps_not_a_fixed_default()
    {
        var (preview, engine, temp) = await MakeAsync();
        using var t = temp;
        using var p = preview;
        preview.Timeline.Timeline.Fps.ShouldBe(30); // sanity: the fixture default this test deviates from
        preview.Timeline.Timeline.Fps = 24;

        await preview.OpenSourcePreviewAsync(MakeAsset(duration: 2.0));
        preview.SeekSource(10, PreviewSeekMode.Exact);

        engine.AssetPreviewSeeks.ShouldBe(
        [
            (0, PreviewSeekMode.Exact, 24),
            (10, PreviewSeekMode.Exact, 24),
        ]);
    }

    [Fact]
    public async Task Dispose_while_in_Source_mode_closes_the_open_asset_preview()
    {
        var (preview, engine, temp) = await MakeAsync();
        using var t = temp;
        await preview.OpenSourcePreviewAsync(MakeAsset());

        preview.Dispose();

        engine.CloseAssetPreviewCallCount.ShouldBe(1);
    }
}
