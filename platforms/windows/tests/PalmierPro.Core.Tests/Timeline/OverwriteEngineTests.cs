using PalmierPro.Core.Timeline;
using Shouldly;
using Xunit;

namespace PalmierPro.Core.Tests;

/// Mirrors Tests/PalmierProTests/Timeline/OverwriteEngineTests.swift.
public class OverwriteEngineTests
{
    [Fact]
    public void EmptyRegionProducesNoActions()
    {
        var clip = Fixtures.Clip(start: 0, duration: 100);
        OverwriteEngine.ComputeOverwrite([clip], 50, 50).ShouldBeEmpty();
        OverwriteEngine.ComputeOverwrite([clip], 60, 50).ShouldBeEmpty();
    }

    [Fact]
    public void NoClipsProducesNoActions() =>
        OverwriteEngine.ComputeOverwrite([], 0, 100).ShouldBeEmpty();

    [Fact]
    public void ClipFullyOutsideRegionIsIgnored()
    {
        var before = Fixtures.Clip(id: "before", start: 0, duration: 40);   // [0, 40)
        var after = Fixtures.Clip(id: "after", start: 200, duration: 50);   // [200, 250)
        OverwriteEngine.ComputeOverwrite([before, after], 50, 150).ShouldBeEmpty();
    }

    [Fact]
    public void ClipFullyInsideRegionIsRemoved()
    {
        var clip = Fixtures.Clip(id: "c1", start: 60, duration: 40); // [60, 100)
        var actions = OverwriteEngine.ComputeOverwrite([clip], 50, 150);
        actions.Count.ShouldBe(1);
        var remove = actions[0].ShouldBeOfType<OverwriteAction.Remove>();
        remove.ClipId.ShouldBe("c1");
    }

    [Fact]
    public void ClipExactlyMatchingRegionIsRemoved()
    {
        var clip = Fixtures.Clip(id: "c1", start: 50, duration: 100); // [50, 150)
        var actions = OverwriteEngine.ComputeOverwrite([clip], 50, 150);
        actions.Count.ShouldBe(1);
        actions[0].ShouldBeOfType<OverwriteAction.Remove>();
    }

    [Fact]
    public void ClipEnvelopingRegionIsSplit()
    {
        // Clip [0, 200), region [50, 150). Expect split: leftDuration=50, rightStart=150, rightDuration=50.
        var clip = Fixtures.Clip(id: "c1", start: 0, duration: 200);
        var actions = OverwriteEngine.ComputeOverwrite([clip], 50, 150);
        actions.Count.ShouldBe(1);
        var split = actions[0].ShouldBeOfType<OverwriteAction.Split>();
        split.ClipId.ShouldBe("c1");
        split.LeftDuration.ShouldBe(50);
        split.RightStartFrame.ShouldBe(150);
        split.RightTrimStart.ShouldBe(150); // trimStart 0 + (150-0)*1.0
        split.RightDuration.ShouldBe(50);
    }

    [Fact]
    public void SplitRespectsSpeedAndTrimStart()
    {
        // speed=2.0, trimStart=10, clip [0, 200), region [50, 150)
        var clip = Fixtures.Clip(id: "c1", start: 0, duration: 200, trimStart: 10, speed: 2.0);
        var actions = OverwriteEngine.ComputeOverwrite([clip], 50, 150);
        var split = actions[0].ShouldBeOfType<OverwriteAction.Split>();
        split.LeftDuration.ShouldBe(50);
        split.RightStartFrame.ShouldBe(150);
        split.RightTrimStart.ShouldBe(310); // 10 + (150-0)*2.0
        split.RightDuration.ShouldBe(50);
    }

    [Fact]
    public void ClipOverlappingLeftEdgeIsTrimEnd()
    {
        // Clip [0, 100), region [50, 200). Expect trimEnd to newDuration=50.
        var clip = Fixtures.Clip(id: "c1", start: 0, duration: 100);
        var actions = OverwriteEngine.ComputeOverwrite([clip], 50, 200);
        actions.Count.ShouldBe(1);
        var trimEnd = actions[0].ShouldBeOfType<OverwriteAction.TrimEnd>();
        trimEnd.ClipId.ShouldBe("c1");
        trimEnd.NewDuration.ShouldBe(50);
    }

    [Fact]
    public void ClipOverlappingRightEdgeIsTrimStart()
    {
        // Clip [50, 150), region [0, 100). Expect trimStart at frame 100, newDuration=50.
        var clip = Fixtures.Clip(id: "c1", start: 50, duration: 100);
        var actions = OverwriteEngine.ComputeOverwrite([clip], 0, 100);
        actions.Count.ShouldBe(1);
        var trimStart = actions[0].ShouldBeOfType<OverwriteAction.TrimStart>();
        trimStart.ClipId.ShouldBe("c1");
        trimStart.NewStartFrame.ShouldBe(100);
        trimStart.NewTrimStart.ShouldBe(50); // trimStart 0 + (100-50)*1.0
        trimStart.NewDuration.ShouldBe(50);
    }

    [Fact]
    public void TrimStartRespectsSpeedAndTrimStart()
    {
        // speed=2.0, trimStart=10, clip [50, 150), region [0, 100)
        var clip = Fixtures.Clip(id: "c1", start: 50, duration: 100, trimStart: 10, speed: 2.0);
        var actions = OverwriteEngine.ComputeOverwrite([clip], 0, 100);
        var trimStart = actions[0].ShouldBeOfType<OverwriteAction.TrimStart>();
        trimStart.NewStartFrame.ShouldBe(100);
        trimStart.NewTrimStart.ShouldBe(110); // 10 + (100-50)*2.0
        trimStart.NewDuration.ShouldBe(50);
    }

    [Fact]
    public void AdjacentEdgesDoNotTrigger()
    {
        // Clip ends exactly at regionStart, or starts exactly at regionEnd -> no action.
        var left = Fixtures.Clip(id: "left", start: 0, duration: 50);   // [0, 50)
        var right = Fixtures.Clip(id: "right", start: 150, duration: 50); // [150, 200)
        OverwriteEngine.ComputeOverwrite([left, right], 50, 150).ShouldBeEmpty();
    }

    [Fact]
    public void MultipleClipsProduceOneActionEach()
    {
        // Region [50, 150) against three clips covering each non-skip branch.
        var inside = Fixtures.Clip(id: "inside", start: 60, duration: 30);        // [60, 90)  -> remove
        var leftOverlap = Fixtures.Clip(id: "left", start: 0, duration: 60);      // [0, 60)   -> trimEnd
        var rightOverlap = Fixtures.Clip(id: "right", start: 100, duration: 200); // [100, 300) -> trimStart
        var actions = OverwriteEngine.ComputeOverwrite([inside, leftOverlap, rightOverlap], 50, 150);
        actions.Count.ShouldBe(3);
    }
}

// MARK: - Adversarial

public class OverwriteEngineAdversarialTests
{
    /// Apply an action sequence to a clip list (mimics what TimelineEditorViewModel would do)
    /// and return the resulting clips sorted by StartFrame.
    private static List<Models.Clip> Apply(IReadOnlyList<OverwriteAction> actions, IReadOnlyList<Models.Clip> clips)
    {
        var result = clips.ToList();
        foreach (var action in actions)
        {
            switch (action)
            {
                case OverwriteAction.Remove(var id):
                    result.RemoveAll(c => c.Id == id);
                    break;
                case OverwriteAction.TrimEnd(var id, var newDuration):
                {
                    var i = result.FindIndex(c => c.Id == id);
                    if (i >= 0) result[i].DurationFrames = newDuration;
                    break;
                }
                case OverwriteAction.TrimStart(var id, var newStartFrame, var newTrimStart, var newDuration):
                {
                    var i = result.FindIndex(c => c.Id == id);
                    if (i >= 0)
                    {
                        result[i].StartFrame = newStartFrame;
                        result[i].TrimStartFrame = newTrimStart;
                        result[i].DurationFrames = newDuration;
                    }
                    break;
                }
                case OverwriteAction.Split(var id, var leftDuration, var rightId, var rightStartFrame, var rightTrimStart, var rightDuration):
                {
                    var i = result.FindIndex(c => c.Id == id);
                    if (i >= 0)
                    {
                        var right = Fixtures.Clip(
                            id: rightId, start: rightStartFrame, duration: rightDuration,
                            trimStart: rightTrimStart, speed: result[i].Speed);
                        result[i].DurationFrames = leftDuration;
                        result.Add(right);
                    }
                    break;
                }
            }
        }
        return [.. result.OrderBy(c => c.StartFrame)];
    }

    private static bool Overlaps(Models.Clip a, Models.Clip b) =>
        a.StartFrame < b.EndFrame && b.StartFrame < a.EndFrame;

    [Fact]
    public void ActionsClearTheRegionAcrossAllBranches()
    {
        // Apply actions and verify no clip occupies the region afterwards.
        const int regionStart = 50, regionEnd = 150;
        var scenarios = new (string Name, List<Models.Clip> Clips)[]
        {
            ("inside", [Fixtures.Clip(id: "x", start: 60, duration: 40)]),
            ("exactly matching", [Fixtures.Clip(id: "x", start: 50, duration: 100)]),
            ("overlaps left", [Fixtures.Clip(id: "x", start: 0, duration: 100)]),
            ("overlaps right", [Fixtures.Clip(id: "x", start: 100, duration: 100)]),
            ("envelops", [Fixtures.Clip(id: "x", start: 0, duration: 200)]),
            ("envelop + speed", [Fixtures.Clip(id: "x", start: 0, duration: 200, speed: 2.0)]),
            ("trimStart non-zero", [Fixtures.Clip(id: "x", start: 0, duration: 200, trimStart: 10)]),
        };
        foreach (var (name, clips) in scenarios)
        {
            var actions = OverwriteEngine.ComputeOverwrite(clips, regionStart, regionEnd);
            var after = Apply(actions, clips);
            var occupant = after.FirstOrDefault(c => c.StartFrame < regionEnd && c.EndFrame > regionStart);
            occupant.ShouldBeNull($"{name}: clip {occupant?.Id ?? "?"} still occupies region");
        }
    }

    [Fact]
    public void ActionsDoNotProduceOverlappingSurvivors()
    {
        List<Models.Clip>[] scenarios =
        [
            [Fixtures.Clip(id: "x", start: 0, duration: 200)], // split into two halves
            [
                Fixtures.Clip(id: "a", start: 0, duration: 60),
                Fixtures.Clip(id: "b", start: 100, duration: 200),
            ],
        ];
        foreach (var clips in scenarios)
        {
            var actions = OverwriteEngine.ComputeOverwrite(clips, 50, 150);
            var after = Apply(actions, clips);
            for (var i = 0; i < after.Count; i++)
            {
                for (var j = i + 1; j < after.Count; j++)
                {
                    Overlaps(after[i], after[j]).ShouldBeFalse();
                }
            }
        }
    }

    /// Half-open boundary convention: a clip starting exactly at regionEnd is untouched.
    /// Verified together with RippleEngine's matching convention.
    [Fact]
    public void AdjacentClipAtRegionEndIsNotTouched()
    {
        var after = Fixtures.Clip(id: "b", start: 100, duration: 50);
        OverwriteEngine.ComputeOverwrite([after], 50, 100).ShouldBeEmpty();
    }

    [Fact]
    public void ZeroDurationClipDoesNotCrash()
    {
        // cs == ce == startFrame. Engine treats it as a point inside the region -> .Remove.
        var zeroClip = Fixtures.Clip(id: "z", start: 100, duration: 0);
        _ = OverwriteEngine.ComputeOverwrite([zeroClip], 50, 150); // don't assert specific shape, just that we don't crash
    }
}
