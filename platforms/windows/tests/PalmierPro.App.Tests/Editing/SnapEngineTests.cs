using PalmierPro.App.Editing;
using PalmierPro.App.Tests.ViewModels.Editor;
using Shouldly;
using Xunit;
using static PalmierPro.App.Editing.SnapEngine;

namespace PalmierPro.App.Tests.Editing;

/// Mirrors Tests/PalmierProTests/Timeline/SnapEngineTests.swift.
public class SnapEngineTests
{
    // baseThreshold=8 pixels, pixelsPerFrame=4 -> 2-frame base threshold.
    private const double BasePx = 8;
    private const double PxPerFrame = 4;

    [Fact]
    public void CollectTargetsEmptyTracksProducesNoTargets() =>
        CollectTargets([], includePlayhead: false).ShouldBeEmpty();

    [Fact]
    public void CollectTargetsIncludesPlayheadOnlyWhenRequested()
    {
        var withPlayhead = CollectTargets([], playheadFrame: 75, includePlayhead: true);
        withPlayhead.Count.ShouldBe(1);
        withPlayhead[0].Frame.ShouldBe(75);
        withPlayhead[0].Kind.ShouldBe(SnapTargetKind.Playhead);

        CollectTargets([], playheadFrame: 75, includePlayhead: false).ShouldBeEmpty();
    }

    [Fact]
    public void CollectTargetsProducesStartAndEndForEachClip()
    {
        var track = EditorFixtures.VideoTrack(clips: [
            EditorFixtures.Clip(id: "a", start: 0, duration: 50),
            EditorFixtures.Clip(id: "b", start: 100, duration: 80),
        ]);
        var targets = CollectTargets([track]);
        targets.Select(t => t.Frame).OrderBy(f => f).ShouldBe([0, 50, 100, 180]);
        targets.All(t => t.Kind == SnapTargetKind.ClipEdge).ShouldBeTrue();
    }

    [Fact]
    public void CollectTargetsSkipsExcludedClipIds()
    {
        var track = EditorFixtures.VideoTrack(clips: [
            EditorFixtures.Clip(id: "drag", start: 0, duration: 50),
            EditorFixtures.Clip(id: "static", start: 100, duration: 80),
        ]);
        var targets = CollectTargets([track], excludeClipIds: new HashSet<string> { "drag" });
        targets.Select(t => t.Frame).OrderBy(f => f).ShouldBe([100, 180]);
    }

    [Fact]
    public void FindSnapReturnsNilWhenNoTargets()
    {
        var state = new SnapState();
        var result = FindSnap(100, [], ref state, BasePx, PxPerFrame);
        result.ShouldBeNull();
        state.CurrentlySnappedTo.ShouldBeNull();
    }

    [Fact]
    public void FindSnapReturnsNilWhenBeyondThreshold()
    {
        SnapTarget[] targets = [new(50, SnapTargetKind.ClipEdge)];
        var state = new SnapState();
        // pos=55, dist=5, frame threshold=2 -> no snap.
        var result = FindSnap(55, targets, ref state, BasePx, PxPerFrame);
        result.ShouldBeNull();
        state.CurrentlySnappedTo.ShouldBeNull();
    }

    [Fact]
    public void FindSnapSnapsWithinThreshold()
    {
        SnapTarget[] targets = [new(50, SnapTargetKind.ClipEdge)];
        var state = new SnapState();
        // pos=49, dist=1, within frame threshold of 2 -> snaps to 50.
        var result = FindSnap(49, targets, ref state, BasePx, PxPerFrame);
        result!.Value.Frame.ShouldBe(50);
        result.Value.ProbeOffset.ShouldBe(0);
        result.Value.X.ShouldBe(200); // 50 * 4
        state.CurrentlySnappedTo.ShouldBe(50);
    }

    [Fact]
    public void FindSnapPicksClosestOfMultipleTargets()
    {
        SnapTarget[] targets = [new(49, SnapTargetKind.ClipEdge), new(51, SnapTargetKind.ClipEdge)];
        var state = new SnapState();
        // pos=50, dist to 49 = 1, dist to 51 = 1 -- first wins on equal distance (strict <).
        var result = FindSnap(50, targets, ref state, BasePx, PxPerFrame);
        result!.Value.Frame.ShouldBe(49);
    }

    [Fact]
    public void FindSnapStaysStickyWithinHoldThreshold()
    {
        SnapTarget[] targets = [new(50, SnapTargetKind.ClipEdge)];
        var state = new SnapState();

        FindSnap(49, targets, ref state, BasePx, PxPerFrame);
        state.CurrentlySnappedTo.ShouldBe(50);

        // Hold threshold = 2 * 1.5 = 3 frames; pos=53 is exactly at the boundary, still stuck.
        var stuck = FindSnap(53, targets, ref state, BasePx, PxPerFrame);
        stuck!.Value.Frame.ShouldBe(50);
        state.CurrentlySnappedTo.ShouldBe(50);
    }

    [Fact]
    public void FindSnapReleasesStickyBeyondHoldThreshold()
    {
        SnapTarget[] targets = [new(50, SnapTargetKind.ClipEdge)];
        var state = new SnapState();

        FindSnap(49, targets, ref state, BasePx, PxPerFrame);

        // pos=54, dist=4 > hold threshold (3) -> unsnaps; new search dist=4 > base threshold (2) -> null.
        var result = FindSnap(54, targets, ref state, BasePx, PxPerFrame);
        result.ShouldBeNull();
        state.CurrentlySnappedTo.ShouldBeNull();
    }

    [Fact]
    public void FindSnapReleasesWhenStickyTargetDisappears()
    {
        var state = new SnapState();

        SnapTarget[] initial = [new(50, SnapTargetKind.ClipEdge)];
        FindSnap(49, initial, ref state, BasePx, PxPerFrame);
        state.CurrentlySnappedTo.ShouldBe(50);

        // Sticky target frame 50 is no longer in the target list -- sticky branch must release.
        SnapTarget[] updated = [new(200, SnapTargetKind.ClipEdge)];
        var result = FindSnap(50, updated, ref state, BasePx, PxPerFrame);
        result.ShouldBeNull();
        state.CurrentlySnappedTo.ShouldBeNull();
    }

    [Fact]
    public void PlayheadHasWiderThreshold()
    {
        SnapTarget[] targets = [new(100, SnapTargetKind.Playhead)];
        var state = new SnapState();
        // pos=103, dist=3. Clip-edge would need <=2, but playhead threshold is 2 * 1.5 = 3 -> snaps.
        var result = FindSnap(103, targets, ref state, BasePx, PxPerFrame);
        result!.Value.Frame.ShouldBe(100);
    }

    [Fact]
    public void PlayheadStillFailsOutsideItsWiderThreshold()
    {
        SnapTarget[] targets = [new(100, SnapTargetKind.Playhead)];
        var state = new SnapState();
        // pos=104, dist=4 > 3 -> no snap.
        var result = FindSnap(104, targets, ref state, BasePx, PxPerFrame);
        result.ShouldBeNull();
    }

    [Fact]
    public void MultipleProbesPicksClosestProbeTargetPair()
    {
        // pos=70 with probeOffsets [0, 30]: probe0=70 (dist to 50 = 20), probe30=100 (dist to 100 = 0).
        SnapTarget[] targets = [new(50, SnapTargetKind.ClipEdge), new(100, SnapTargetKind.ClipEdge)];
        var state = new SnapState();
        var result = FindSnap(70, targets, ref state, BasePx, PxPerFrame, probeOffsets: [0, 30]);
        result!.Value.Frame.ShouldBe(100);
        result.Value.ProbeOffset.ShouldBe(30);
        state.CurrentProbeOffset.ShouldBe(30);
    }
}

public class SnapEngineAdversarialTests
{
    private const double BasePx = 8;
    private const double PxPerFrame = 4;

    [Fact]
    public void DoesNotLeaveStateBehindWhenNoTargetMatches()
    {
        var state = new SnapState();
        SnapTarget[] targets = [new(1000, SnapTargetKind.ClipEdge)];
        var r = FindSnap(50, targets, ref state, BasePx, PxPerFrame);
        r.ShouldBeNull();
        state.CurrentlySnappedTo.ShouldBeNull();
        state.CurrentProbeOffset.ShouldBe(0);
    }

    [Fact]
    public void ZeroPixelsPerFrameDoesNotCrash()
    {
        // pixelsPerFrame=0 -> frame threshold is infinite. Don't crash.
        var state = new SnapState();
        SnapTarget[] targets = [new(50, SnapTargetKind.ClipEdge)];
        FindSnap(1_000_000, targets, ref state, BasePx, 0); // must not throw/crash
    }

    [Fact]
    public void EmptyProbeOffsetsProducesNoSnap()
    {
        var state = new SnapState();
        SnapTarget[] targets = [new(50, SnapTargetKind.ClipEdge)];
        var r = FindSnap(50, targets, ref state, BasePx, PxPerFrame, probeOffsets: []);
        r.ShouldBeNull();
    }
}
