using PalmierPro.App.Editing;
using PalmierPro.Core.Models;
using Shouldly;
using Xunit;

namespace PalmierPro.App.Tests.Editing;

public class TimelineDropPlannerTests
{
    [Fact]
    public void ExistingCompatibleVideoTrackIsUsedDirectly()
    {
        var plan = TimelineDropPlanner.ResolvePlacement(
            [ClipType.Video, ClipType.Audio], new TrackDropTarget.ExistingTrack(0), ClipType.Video);
        plan.NeedsNewTrack.ShouldBeFalse();
        plan.ExistingIndex.ShouldBe(0);
    }

    [Fact]
    public void ExistingAudioTrackAcceptsAudioDrop()
    {
        var plan = TimelineDropPlanner.ResolvePlacement(
            [ClipType.Video, ClipType.Audio], new TrackDropTarget.ExistingTrack(1), ClipType.Audio);
        plan.NeedsNewTrack.ShouldBeFalse();
        plan.ExistingIndex.ShouldBe(1);
    }

    [Fact]
    public void VideoDropOntoAudioTrackNeedsNewTrack()
    {
        var plan = TimelineDropPlanner.ResolvePlacement(
            [ClipType.Audio], new TrackDropTarget.ExistingTrack(0), ClipType.Video);
        plan.NeedsNewTrack.ShouldBeTrue();
        plan.PreferredType.ShouldBe(ClipType.Video);
        plan.InsertIndex.ShouldBe(0);
    }

    [Fact]
    public void AudioDropOntoVideoTrackNeedsNewTrack()
    {
        var plan = TimelineDropPlanner.ResolvePlacement(
            [ClipType.Video], new TrackDropTarget.ExistingTrack(0), ClipType.Audio);
        plan.NeedsNewTrack.ShouldBeTrue();
        plan.PreferredType.ShouldBe(ClipType.Audio);
    }

    [Fact]
    public void ImageTrackIsVisualCompatibleWithVideoDrop()
    {
        var plan = TimelineDropPlanner.ResolvePlacement(
            [ClipType.Image], new TrackDropTarget.ExistingTrack(0), ClipType.Video);
        plan.NeedsNewTrack.ShouldBeFalse();
    }

    [Fact]
    public void NewTrackAtTargetAlwaysInsertsAtThatIndex()
    {
        var plan = TimelineDropPlanner.ResolvePlacement([ClipType.Video, ClipType.Audio], new TrackDropTarget.NewTrackAt(1), ClipType.Video);
        plan.NeedsNewTrack.ShouldBeTrue();
        plan.InsertIndex.ShouldBe(1);
    }

    [Fact]
    public void ExistingTrackIndexOutOfRangeFallsBackToNewTrack()
    {
        var plan = TimelineDropPlanner.ResolvePlacement([], new TrackDropTarget.ExistingTrack(5), ClipType.Video);
        plan.NeedsNewTrack.ShouldBeTrue();
    }
}
