using PalmierPro.Core.Timeline;
using Shouldly;
using Xunit;

namespace PalmierPro.Core.Tests;

/// Mirrors Tests/PalmierProTests/Timeline/RippleEngineTests.swift.
public class RippleEngineTests
{
    [Fact]
    public void EmptyRemovedIdsProducesNoShifts()
    {
        var a = Fixtures.Clip(id: "a", start: 0, duration: 50);
        var b = Fixtures.Clip(id: "b", start: 100, duration: 50);
        RippleEngine.ComputeRippleShifts([a, b], new HashSet<string>()).ShouldBeEmpty();
    }

    [Fact]
    public void RemovingMiddleClipShiftsTrailingClipsLeft()
    {
        // Remove [50, 100). The clip at [200, 250) should shift left by 50 -> [150, 200).
        var removed = Fixtures.Clip(id: "r", start: 50, duration: 50);
        var trailing = Fixtures.Clip(id: "t", start: 200, duration: 50);
        var head = Fixtures.Clip(id: "h", start: 0, duration: 50);

        var shifts = RippleEngine.ComputeRippleShifts([head, removed, trailing], new HashSet<string> { "r" });
        shifts.ShouldBe([new ClipShift("t", 150)]);
    }

    [Fact]
    public void ClipsBeforeRemovedRangeDoNotShift()
    {
        var head = Fixtures.Clip(id: "h", start: 0, duration: 50);
        var removed = Fixtures.Clip(id: "r", start: 100, duration: 50);
        RippleEngine.ComputeRippleShifts([head, removed], new HashSet<string> { "r" }).ShouldBeEmpty();
    }

    [Fact]
    public void RemovingMultipleClipsShiftsByMergedTotal()
    {
        // Remove [0, 50) and [100, 150). Clip at [200, 250) shifts left by 100 -> [100, 200).
        var r1 = Fixtures.Clip(id: "r1", start: 0, duration: 50);
        var r2 = Fixtures.Clip(id: "r2", start: 100, duration: 50);
        var tail = Fixtures.Clip(id: "t", start: 200, duration: 50);
        var shifts = RippleEngine.ComputeRippleShifts([r1, r2, tail], new HashSet<string> { "r1", "r2" });
        shifts.ShouldBe([new ClipShift("t", 100)]);
    }

    [Fact]
    public void OverlappingRangesMergeBeforeShifting()
    {
        // Ranges [0, 100) and [50, 200) -> merged [0, 200). Clip at [300, 400) shifts by 200.
        var clip = Fixtures.Clip(id: "c", start: 300, duration: 100);
        var shifts = RippleEngine.ComputeRippleShiftsForRanges([clip], [new FrameRange(0, 100), new FrameRange(50, 200)]);
        shifts.ShouldBe([new ClipShift("c", 100)]);
    }

    [Fact]
    public void TouchingRangesMergeBeforeShifting()
    {
        // [0, 50) touching [50, 100) -> merged [0, 100). Clip at [200) shifts by 100.
        var clip = Fixtures.Clip(id: "c", start: 200, duration: 50);
        var shifts = RippleEngine.ComputeRippleShiftsForRanges([clip], [new FrameRange(0, 50), new FrameRange(50, 100)]);
        shifts.ShouldBe([new ClipShift("c", 100)]);
    }

    [Fact]
    public void RangeWhollyBeforeClipShiftsClip_RangeAfterDoesNot()
    {
        var a = Fixtures.Clip(id: "a", start: 100, duration: 50);
        var b = Fixtures.Clip(id: "b", start: 200, duration: 50);
        var shifts = RippleEngine.ComputeRippleShiftsForRanges([a, b], [new FrameRange(0, 50), new FrameRange(400, 500)]);
        shifts.ShouldBe([new ClipShift("a", 50), new ClipShift("b", 150)]);
    }

    [Fact]
    public void RangeMustEndAtOrBeforeClipStartToShift()
    {
        // Range [0, 100) -- clip at frame 100 has `range.End <= clip.StartFrame` -> shifts.
        // Range [0, 101) -- clip at frame 100 fails the predicate -> does NOT shift.
        var clip = Fixtures.Clip(id: "c", start: 100, duration: 50);

        var exactlyAtStart = RippleEngine.ComputeRippleShiftsForRanges([clip], [new FrameRange(0, 100)]);
        exactlyAtStart.ShouldBe([new ClipShift("c", 0)]);

        var overlapping = RippleEngine.ComputeRippleShiftsForRanges([clip], [new FrameRange(0, 101)]);
        overlapping.ShouldBeEmpty();
    }

    [Fact]
    public void PushMovesClipsAtOrAfterInsertFrame()
    {
        var a = Fixtures.Clip(id: "a", start: 0, duration: 50);   // before insert
        var b = Fixtures.Clip(id: "b", start: 100, duration: 50); // at insert
        var c = Fixtures.Clip(id: "c", start: 200, duration: 50); // after insert
        var shifts = RippleEngine.ComputeRipplePush([a, b, c], 100, 30);
        shifts.ShouldBe([new ClipShift("b", 130), new ClipShift("c", 230)]);
    }

    [Fact]
    public void PushSkipsExcludedIds()
    {
        var a = Fixtures.Clip(id: "a", start: 100, duration: 50);
        var b = Fixtures.Clip(id: "b", start: 200, duration: 50);
        var shifts = RippleEngine.ComputeRipplePush([a, b], 0, 25, new HashSet<string> { "a" });
        shifts.ShouldBe([new ClipShift("b", 225)]);
    }
}

public class RippleEngineAdversarialTests
{
    [Fact]
    public void ShiftsPreserveStartFrameOrder()
    {
        var clips = new[]
        {
            Fixtures.Clip(id: "a", start: 0, duration: 50),
            Fixtures.Clip(id: "b", start: 100, duration: 50),
            Fixtures.Clip(id: "c", start: 200, duration: 50),
            Fixtures.Clip(id: "d", start: 300, duration: 50),
        };
        var shifts = RippleEngine.ComputeRippleShifts(clips, new HashSet<string> { "b", "c" });
        var newStarts = clips
            .Where(c => c.Id is not ("b" or "c"))
            .Select(c => (c.Id, c.StartFrame))
            .ToList();
        for (var i = 0; i < newStarts.Count; i++)
        {
            var shift = shifts.FirstOrDefault(s => s.ClipId == newStarts[i].Id);
            if (shift.ClipId is not null)
            {
                newStarts[i] = (newStarts[i].Id, shift.NewStartFrame);
            }
        }
        var aIdx = newStarts.FindIndex(s => s.Id == "a");
        var dIdx = newStarts.FindIndex(s => s.Id == "d");
        aIdx.ShouldBeLessThan(dIdx);
        var starts = newStarts.Select(s => s.StartFrame).ToList();
        starts.ShouldBe([.. starts.OrderBy(x => x)]);
    }

    [Fact]
    public void PushDoesNotMakeClipsCollide()
    {
        var clips = new[]
        {
            Fixtures.Clip(id: "anchor", start: 0, duration: 50),
            Fixtures.Clip(id: "follower", start: 100, duration: 50),
        };
        var shifts = RippleEngine.ComputeRipplePush(clips, 100, 30);
        var followerNewStart = shifts.First(s => s.ClipId == "follower").NewStartFrame;
        followerNewStart.ShouldBe(130);
        (50 <= followerNewStart).ShouldBeTrue(); // anchor ends at 50, no overlap
    }
}
