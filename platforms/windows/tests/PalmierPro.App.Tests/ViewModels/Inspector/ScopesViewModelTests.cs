using PalmierPro.App.Tests.ViewModels.Editor;
using PalmierPro.App.ViewModels.Inspector;
using PalmierPro.Rendering;
using PalmierPro.Services.Engine;
using Shouldly;
using Xunit;

namespace PalmierPro.App.Tests.ViewModels.Inspector;

/// Ports docs/color-scopes-v1.md §4's trigger set/guards for the shared Curves+Hue-Curves scope
/// data source: refresh on Activate (first appearance), on a structural edit, on a playhead move,
/// and when playback settles — never while playing, and coalesced (histInFlight/histDirty, ported
/// from CurveEditorView.swift/HueCurveEditorView.swift) rather than one call per trigger.
public class ScopesViewModelTests
{
    private static ColorScopesResult MakeResult(long frame) => new(frame, [0.1f], [0.2f], [0.3f], [0.4f], [0.5f]);

    [Fact]
    public async Task ActivateTriggersOneRefreshAtCurrentFrame()
    {
        var (timeline, temp) = await EditorFixtures.MakeAsync();
        using var _ = temp;
        var engine = new FakeScopesVideoEngine();
        var vm = new ScopesViewModel(engine, timeline);

        vm.Activate();
        await engine.Complete(MakeResult(0));

        engine.RequestedFrames.ShouldBe([0]);
        vm.Result.ShouldNotBeNull();
        vm.Result!.Frame.ShouldBe(0);
    }

    [Fact]
    public async Task NeverRefreshesWhilePlaying()
    {
        var (timeline, temp) = await EditorFixtures.MakeAsync();
        using var _ = temp;
        var engine = new FakeScopesVideoEngine { Playing = true };
        var vm = new ScopesViewModel(engine, timeline);

        vm.Activate();
        timeline.CurrentFrame = 7;
        engine.RaisePlayheadChanged(timeline.ActiveTimelineId, 7);

        engine.RequestedFrames.ShouldBeEmpty();
        await Task.CompletedTask;
    }

    [Fact]
    public async Task TriggersWhileAFetchIsInFlightCoalesceIntoOneTrailingRefresh()
    {
        var (timeline, temp) = await EditorFixtures.MakeAsync();
        using var _ = temp;
        var engine = new FakeScopesVideoEngine();
        var vm = new ScopesViewModel(engine, timeline);

        vm.Activate(); // in flight for frame 0

        timeline.CurrentFrame = 5;
        engine.RaisePlayheadChanged(timeline.ActiveTimelineId, 5); // coalesced — no new call yet
        timeline.CurrentFrame = 9;
        engine.RaisePlayheadChanged(timeline.ActiveTimelineId, 9); // still coalesced

        engine.RequestedFrames.ShouldBe([0]);

        await engine.Complete(MakeResult(0));
        // The trailing refresh fires for whatever CurrentFrame is by the time the in-flight call
        // completes — the last of the two coalesced triggers, not one call per trigger.
        await engine.Complete(MakeResult(9));

        engine.RequestedFrames.ShouldBe([0, 9]);
        vm.Result!.Frame.ShouldBe(9);
    }

    [Fact]
    public async Task DeactivateStopsFurtherRefreshes()
    {
        var (timeline, temp) = await EditorFixtures.MakeAsync();
        using var _ = temp;
        var engine = new FakeScopesVideoEngine();
        var vm = new ScopesViewModel(engine, timeline);

        vm.Activate();
        await engine.Complete(MakeResult(0));
        vm.Deactivate();

        timeline.CurrentFrame = 3;
        engine.RaisePlayheadChanged(timeline.ActiveTimelineId, 3);

        engine.RequestedFrames.ShouldBe([0]);
    }

    [Fact]
    public async Task ActivationIsReferenceCounted()
    {
        var (timeline, temp) = await EditorFixtures.MakeAsync();
        using var _ = temp;
        var engine = new FakeScopesVideoEngine();
        var vm = new ScopesViewModel(engine, timeline);

        vm.Activate(); // histogram view mounts
        await engine.Complete(MakeResult(0));
        vm.Activate(); // hue view also mounts — shares the same fetch pipeline, no extra call
        vm.Deactivate(); // histogram view unmounts — hue view keeps it alive

        timeline.CurrentFrame = 3;
        engine.RaisePlayheadChanged(timeline.ActiveTimelineId, 3);
        await engine.Complete(MakeResult(3));
        engine.RequestedFrames.ShouldBe([0, 3]);

        vm.Deactivate(); // hue view unmounts — now fully inactive
        timeline.CurrentFrame = 4;
        engine.RaisePlayheadChanged(timeline.ActiveTimelineId, 4);
        engine.RequestedFrames.ShouldBe([0, 3]);
    }

    [Fact]
    public async Task PlayheadChangeForADifferentTimelineIsIgnored()
    {
        var (timeline, temp) = await EditorFixtures.MakeAsync();
        using var _ = temp;
        var engine = new FakeScopesVideoEngine();
        var vm = new ScopesViewModel(engine, timeline);
        vm.Activate();
        await engine.Complete(MakeResult(0));

        engine.RaisePlayheadChanged("some-other-timeline-id", 42);

        engine.RequestedFrames.ShouldBe([0]);
    }

    [Fact]
    public async Task IsPlayingChangedToFalseTriggersASettleRefresh()
    {
        var (timeline, temp) = await EditorFixtures.MakeAsync();
        using var _ = temp;
        var engine = new FakeScopesVideoEngine();
        var vm = new ScopesViewModel(engine, timeline);
        vm.Activate();
        await engine.Complete(MakeResult(0));

        engine.RaiseIsPlayingChanged(true); // no fetch on a transition to *playing*
        engine.RequestedFrames.ShouldBe([0]);

        engine.RaiseIsPlayingChanged(false);
        await engine.Complete(MakeResult(0));

        engine.RequestedFrames.ShouldBe([0, 0]);
    }
}
