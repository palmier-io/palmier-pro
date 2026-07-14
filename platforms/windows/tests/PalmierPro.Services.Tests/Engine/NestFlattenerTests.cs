using PalmierPro.Core.Json;
using PalmierPro.Core.Models;
using PalmierPro.Services.Engine;
using Shouldly;
using Xunit;

namespace PalmierPro.Services.Tests.Engine;

/// Unit tests for the direct NestFlattener.swift port (one-level remap). Depth-limiting is NOT
/// this type's concern — `NestFlattener.Flatten` takes no depth parameter, matching Swift; the
/// recursion guard lives in `TimelineSnapshotBuilder` (see TimelineSnapshotBuilderTests).
public class NestFlattenerTests
{
    private static Clip Clip(string mediaRef, int start, int duration, string id = "", int trimStart = 0, double speed = 1.0,
        int fadeIn = 0, int fadeOut = 0, ClipType type = ClipType.Video) =>
        new(mediaRef, start, duration)
        {
            Id = id.Length == 0 ? SwiftId.New() : id,
            MediaType = type,
            SourceClipType = type,
            TrimStartFrame = trimStart,
            Speed = speed,
            FadeInFrames = fadeIn,
            FadeOutFrames = fadeOut,
        };

    private static Track VideoTrack(string id, params Clip[] clips) => new(ClipType.Video, [.. clips]) { Id = id };
    private static Track AudioTrack(string id, params Clip[] clips) => new(ClipType.Audio, [.. clips]) { Id = id };

    private static Clip Carrier(int start, int duration, int trimStart = 0, double speed = 1.0) =>
        new("child", start, duration) { Id = "CARRIER", MediaType = ClipType.Sequence, SourceClipType = ClipType.Sequence, TrimStartFrame = trimStart, Speed = speed };

    [Fact]
    public void ClipFullyInsideWindowShiftsByCarrierPlacement()
    {
        // Carrier: startFrame=100, trimStart=0 -> shift = 100. Window = [0, 50).
        var carrier = Carrier(start: 100, duration: 50);
        var child = new Timeline { Width = 1920, Height = 1080, Tracks = [VideoTrack("T", Clip("m", start: 10, duration: 20, id: "C"))] };

        var flat = NestFlattener.Flatten(carrier, child, visual: true);

        flat.VideoTracks.Count.ShouldBe(1);
        var mapped = flat.VideoTracks[0].ShouldHaveSingleItem();
        mapped.StartFrame.ShouldBe(110); // 10 + shift(100)
        mapped.DurationFrames.ShouldBe(20); // fully inside window, untouched
        mapped.TrimStartFrame.ShouldBe(0); // no head cut
        mapped.Id.ShouldBe("CARRIER/C");
    }

    [Fact]
    public void HeadCutAdvancesTrimStartAndClearsFadeIn()
    {
        // Carrier trims its own start 5 frames in -> window = [5, 45). shift = startFrame(10) - trimStart(5) = 5.
        var carrier = Carrier(start: 10, duration: 40, trimStart: 5);
        var child = new Timeline { Tracks = [VideoTrack("T", Clip("m", start: 0, duration: 100, id: "C", fadeIn: 8))] };

        var flat = NestFlattener.Flatten(carrier, child, visual: true);
        var mapped = flat.VideoTracks[0][0];

        // headCut = start(5) - clip.StartFrame(0) = 5
        mapped.TrimStartFrame.ShouldBe(5);
        mapped.FadeInFrames.ShouldBe(0); // cleared — a fade mid-clip after a hard cut makes no sense
        mapped.StartFrame.ShouldBe(10); // 5 + shift(5)
        mapped.DurationFrames.ShouldBe(40); // window width
    }

    [Fact]
    public void HeadCutScalesTrimStartByClipSpeed()
    {
        var carrier = Carrier(start: 0, duration: 20, trimStart: 10);
        var child = new Timeline { Tracks = [VideoTrack("T", Clip("m", start: 0, duration: 100, id: "C", speed: 2.0))] };

        var flat = NestFlattener.Flatten(carrier, child, visual: true);
        var mapped = flat.VideoTracks[0][0];

        // headCut = 10 (start=max(0,10)=10 - clip.StartFrame(0)); trimStart += round(10 * 2.0) = 20.
        mapped.TrimStartFrame.ShouldBe(20);
    }

    [Fact]
    public void TailCutClearsFadeOutButNotFadeIn()
    {
        // Window = [0, 30). Child clip runs 0..100, so its tail is cut, not its head.
        var carrier = Carrier(start: 0, duration: 30);
        var child = new Timeline { Tracks = [VideoTrack("T", Clip("m", start: 0, duration: 100, id: "C", fadeIn: 5, fadeOut: 5))] };

        var flat = NestFlattener.Flatten(carrier, child, visual: true);
        var mapped = flat.VideoTracks[0][0];

        mapped.FadeInFrames.ShouldBe(5); // head untouched — no head cut
        mapped.FadeOutFrames.ShouldBe(0); // tail cut — cleared
        mapped.DurationFrames.ShouldBe(30);
    }

    [Fact]
    public void ClipEntirelyOutsideWindowIsExcluded()
    {
        var carrier = Carrier(start: 0, duration: 10); // window = [0, 10)
        var child = new Timeline { Tracks = [VideoTrack("T", Clip("m", start: 50, duration: 10, id: "C"))] };

        var flat = NestFlattener.Flatten(carrier, child, visual: true);

        flat.VideoTracks.ShouldBeEmpty(); // the only clip on the only track was dropped -> lane omitted entirely
    }

    [Fact]
    public void ClipsAreSortedByStartFrameBeforeRemap()
    {
        var carrier = Carrier(start: 0, duration: 100);
        var second = Clip("m", start: 50, duration: 10, id: "SECOND");
        var first = Clip("m", start: 0, duration: 10, id: "FIRST");
        var child = new Timeline { Tracks = [VideoTrack("T", second, first)] }; // authored out of order

        var flat = NestFlattener.Flatten(carrier, child, visual: true);

        flat.VideoTracks[0].Select(c => c.Id).ShouldBe(["CARRIER/FIRST", "CARRIER/SECOND"]);
    }

    [Fact]
    public void MutedChildAudioTrackIsExcludedEntirely()
    {
        var carrier = Carrier(start: 0, duration: 100);
        var muted = new Track(ClipType.Audio, [Clip("m", 0, 10, id: "A", type: ClipType.Audio)]) { Id = "MUTED", Muted = true };
        var unmuted = new Track(ClipType.Audio, [Clip("m", 0, 10, id: "B", type: ClipType.Audio)]) { Id = "UNMUTED" };
        var child = new Timeline { Tracks = [muted, unmuted] };

        var flat = NestFlattener.Flatten(carrier, child, visual: false);

        flat.AudioTracks.Count.ShouldBe(1);
        flat.AudioTracks[0][0].Id.ShouldBe("CARRIER/B");
    }

    [Fact]
    public void HiddenChildVideoTrackIsExcludedEntirely()
    {
        var carrier = Carrier(start: 0, duration: 100);
        var hidden = new Track(ClipType.Video, [Clip("m", 0, 10, id: "A")]) { Id = "HIDDEN", Hidden = true };
        var visible = new Track(ClipType.Video, [Clip("m", 0, 10, id: "B")]) { Id = "VISIBLE" };
        var child = new Timeline { Tracks = [hidden, visible] };

        var flat = NestFlattener.Flatten(carrier, child, visual: true);

        flat.VideoTracks.Count.ShouldBe(1);
        flat.VideoTracks[0][0].Id.ShouldBe("CARRIER/B");
    }

    [Fact]
    public void ChildTrackOrderIsPreservedAcrossMultipleVideoSubTracks()
    {
        var carrier = Carrier(start: 0, duration: 100);
        var top = new Track(ClipType.Video, [Clip("top", 0, 10, id: "TOP")]) { Id = "TOP-TRACK" };
        var bottom = new Track(ClipType.Video, [Clip("bottom", 0, 10, id: "BOTTOM")]) { Id = "BOTTOM-TRACK" };
        var child = new Timeline { Tracks = [top, bottom] }; // top authored first, index 0

        var flat = NestFlattener.Flatten(carrier, child, visual: true);

        flat.VideoTracks.Count.ShouldBe(2);
        flat.VideoTracks[0][0].Id.ShouldBe("CARRIER/TOP"); // index 0 = child's own topmost, unchanged order
        flat.VideoTracks[1][0].Id.ShouldBe("CARRIER/BOTTOM");
    }

    [Fact]
    public void DoesNotMutateTheOriginalChildClip()
    {
        var carrier = Carrier(start: 0, duration: 100, trimStart: 5);
        var original = Clip("m", start: 0, duration: 50, id: "C", fadeIn: 9);
        var child = new Timeline { Tracks = [VideoTrack("T", original)] };

        NestFlattener.Flatten(carrier, child, visual: true);

        // The source Clip instance handed to Flatten must be untouched — Flatten must deep-copy,
        // not mutate in place (Clip is a reference type in C#, unlike Swift's value-type struct).
        original.Id.ShouldBe("C");
        original.FadeInFrames.ShouldBe(9);
        original.TrimStartFrame.ShouldBe(0);
        original.StartFrame.ShouldBe(0);
    }

    [Fact]
    public void ChildWidthAndHeightAreCarriedThrough()
    {
        var carrier = Carrier(start: 0, duration: 10);
        var child = new Timeline { Width = 640, Height = 360, Tracks = [] };

        var flat = NestFlattener.Flatten(carrier, child, visual: true);

        flat.ChildWidth.ShouldBe(640);
        flat.ChildHeight.ShouldBe(360);
    }
}
