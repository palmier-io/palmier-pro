using PalmierPro.Core.Models;
using Shouldly;
using Xunit;

namespace PalmierPro.Core.Tests;

/// Behavior tests for Timeline.NestedTimelineIds / ReachableTimelines — no Mac-side test exists
/// for these (grepped, none found), so this is a from-scratch port of the documented semantics.
public class NestedTimelineTests
{
    private static Clip SequenceClip(string mediaRef, int start = 0, int duration = 10) =>
        Fixtures.Clip(mediaRef: mediaRef, mediaType: ClipType.Sequence, start: start, duration: duration);

    [Fact]
    public void NestedTimelineIdsCollectsSequenceClipsByMediaType()
    {
        var child = SequenceClip("child-1");
        var timeline = Fixtures.Timeline(tracks: [Fixtures.VideoTrack(clips: [child])]);
        timeline.NestedTimelineIds.ShouldBe(new HashSet<string> { "child-1" });
    }

    [Fact]
    public void NestedTimelineIdsAlsoMatchesSourceClipTypeSequence()
    {
        // mediaType can differ from sourceClipType for derived clips; either flag qualifies.
        var clip = Fixtures.Clip(mediaRef: "child-2", mediaType: ClipType.Video, start: 0, duration: 10);
        clip.SourceClipType = ClipType.Sequence;
        var timeline = Fixtures.Timeline(tracks: [Fixtures.VideoTrack(clips: [clip])]);
        timeline.NestedTimelineIds.ShouldBe(new HashSet<string> { "child-2" });
    }

    [Fact]
    public void NestedTimelineIdsIgnoresOrdinaryClips()
    {
        var timeline = Fixtures.Timeline(tracks: [Fixtures.VideoTrack(clips: [Fixtures.Clip(start: 0, duration: 10)])]);
        timeline.NestedTimelineIds.ShouldBeEmpty();
    }

    [Fact]
    public void ReachableTimelinesFindsDirectChild()
    {
        var child = new Models.Timeline { Id = "child" };
        var root = new Models.Timeline { Id = "root", Tracks = [Fixtures.VideoTrack(clips: [SequenceClip("child")])] };

        var resolved = root.ReachableTimelines(id => id == "child" ? child : null);

        resolved.Select(t => t.Id).ShouldBe(["child"]);
    }

    [Fact]
    public void ReachableTimelinesTraversesMultipleLevelsBreadthFirst()
    {
        var grandchild = new Models.Timeline { Id = "grandchild" };
        var child = new Models.Timeline { Id = "child", Tracks = [Fixtures.VideoTrack(clips: [SequenceClip("grandchild")])] };
        var root = new Models.Timeline { Id = "root", Tracks = [Fixtures.VideoTrack(clips: [SequenceClip("child")])] };

        Models.Timeline? Resolve(string id) => id switch
        {
            "child" => child,
            "grandchild" => grandchild,
            _ => null,
        };

        var resolved = root.ReachableTimelines(Resolve);

        resolved.Select(t => t.Id).ShouldBe(["child", "grandchild"]);
    }

    [Fact]
    public void ReachableTimelinesDedupesRepeatedReferences()
    {
        var child = new Models.Timeline { Id = "child" };
        var root = new Models.Timeline
        {
            Id = "root",
            Tracks =
            [
                Fixtures.VideoTrack(clips: [SequenceClip("child", start: 0), SequenceClip("child", start: 20)]),
            ],
        };

        var resolved = root.ReachableTimelines(id => id == "child" ? child : null);

        resolved.Count.ShouldBe(1);
    }

    [Fact]
    public void ReachableTimelinesExcludesSelfEvenIfSelfReferenced()
    {
        var root = new Models.Timeline { Id = "root" };
        root.Tracks = [Fixtures.VideoTrack(clips: [SequenceClip("root")])];

        var resolved = root.ReachableTimelines(id => id == "root" ? root : null);

        resolved.ShouldBeEmpty();
    }

    [Fact]
    public void ReachableTimelinesRespectsMaxDepth()
    {
        var grandchild = new Models.Timeline { Id = "grandchild" };
        var child = new Models.Timeline { Id = "child", Tracks = [Fixtures.VideoTrack(clips: [SequenceClip("grandchild")])] };
        var root = new Models.Timeline { Id = "root", Tracks = [Fixtures.VideoTrack(clips: [SequenceClip("child")])] };

        Models.Timeline? Resolve(string id) => id switch { "child" => child, "grandchild" => grandchild, _ => null };

        var resolved = root.ReachableTimelines(Resolve, maxDepth: 1);

        resolved.Select(t => t.Id).ShouldBe(["child"]);
    }

    [Fact]
    public void ReachableTimelinesRespectsIncludeFilter()
    {
        var hidden = new Models.Timeline { Id = "hidden" };
        var visible = new Models.Timeline { Id = "visible" };
        var root = new Models.Timeline
        {
            Id = "root",
            Tracks = [Fixtures.VideoTrack(clips: [SequenceClip("hidden"), SequenceClip("visible", start: 20)])],
        };

        Models.Timeline? Resolve(string id) => id switch { "hidden" => hidden, "visible" => visible, _ => null };

        var resolved = root.ReachableTimelines(Resolve, include: t => t.Id != "hidden");

        resolved.Select(t => t.Id).ShouldBe(["visible"]);
    }
}
