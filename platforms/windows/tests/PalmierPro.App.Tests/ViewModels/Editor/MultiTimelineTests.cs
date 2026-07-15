using PalmierPro.App.ViewModels.Editor;
using PalmierPro.Core.Models;
using Shouldly;
using Xunit;

namespace PalmierPro.App.Tests.ViewModels.Editor;

/// Mirrors the subset of Tests/PalmierProTests/Timeline/MultiTimelineTests.swift that's in scope
/// for M3 (Stage C): proxy assignment, activate, CRUD, undo/redo, tab close. Folder management
/// (`createFolder`/`moveTimelinesToFolder`), `applyTimelineSettings` (fps/dimension rescale
/// across every timeline), and generating-clip finalize are not ported — see
/// `TimelineEditorViewModel`'s doc comment for the M3 scope boundary.
public class MultiTimelineTests
{
    [Fact]
    public async Task ProxyAssignmentAdoptsUnknownIdInActiveSlot()
    {
        var (e, temp) = await EditorFixtures.MakeAsync();
        using var _ = temp;

        var replacement = EditorFixtures.Timeline(tracks: [EditorFixtures.VideoTrack()]);
        e.Timeline = replacement;

        e.ActiveTimelineId.ShouldBe(replacement.Id);
        e.Timelines.Count.ShouldBe(1);
        e.OpenTimelineIds.ShouldBe([replacement.Id]);
    }

    [Fact]
    public async Task ProxyAssignmentRoutesByIdAndActivates()
    {
        var (e, temp) = await EditorFixtures.MakeAsync();
        using var _ = temp;

        var firstId = e.ActiveTimelineId;
        var secondId = e.CreateTimeline(activate: false);
        e.ActiveTimelineId.ShouldBe(firstId);

        var second = e.TimelineFor(secondId)!;
        second.Tracks = [EditorFixtures.VideoTrack()];
        e.Timeline = second;

        e.ActiveTimelineId.ShouldBe(secondId);
        e.TimelineFor(secondId)!.Tracks.Count.ShouldBe(1);
        e.TimelineFor(firstId)!.Tracks.ShouldBeEmpty();
    }

    [Fact]
    public async Task ActivateClearsTimelineScopedSelection()
    {
        var (e, temp) = await EditorFixtures.MakeAsync();
        using var _ = temp;

        e.Timeline.Tracks = [EditorFixtures.VideoTrack(clips: [EditorFixtures.Clip(start: 0, duration: 30)])];
        e.SelectedClipIds = [e.Timeline.Tracks[0].Clips[0].Id];
        var secondId = e.CreateTimeline(activate: false);
        e.ActivateTimeline(secondId);
        e.SelectedClipIds.ShouldBeEmpty();
    }

    [Fact]
    public async Task CreateInheritsSettingsAndAutoNames()
    {
        var (e, temp) = await EditorFixtures.MakeAsync();
        using var _ = temp;

        var id = e.CreateTimeline();
        var t = e.TimelineFor(id)!;
        t.Fps.ShouldBe(e.Timeline.Fps);
        t.Name.ShouldBe("Timeline 2");
        e.ActiveTimelineId.ShouldBe(id);
        e.OpenTimelineIds.ShouldContain(id);
    }

    [Fact]
    public async Task DuplicateCopiesContentWithFreshIds()
    {
        var (e, temp) = await EditorFixtures.MakeAsync();
        using var _ = temp;

        var a = EditorFixtures.Clip(start: 0, duration: 30);
        var b = EditorFixtures.Clip(mediaType: ClipType.Audio, start: 0, duration: 30);
        b.LinkGroupId = "g1";
        var a2 = EditorFixtures.Clip(id: a.Id, start: 0, duration: 30);
        a2.LinkGroupId = "g1";
        e.Timeline.Tracks = [EditorFixtures.VideoTrack(clips: [a2]), EditorFixtures.AudioTrack(clips: [b])];
        e.Timeline.Name = "Main";
        var sourceId = e.ActiveTimelineId;

        var dupId = e.DuplicateTimeline(sourceId)!;
        var dup = e.TimelineFor(dupId)!;
        var source = e.TimelineFor(sourceId)!;

        dup.Name.ShouldBe("Main copy");
        dup.Tracks.Count.ShouldBe(2);
        dup.Tracks[0].Id.ShouldNotBe(source.Tracks[0].Id);
        dup.Tracks[0].Clips[0].Id.ShouldNotBe(source.Tracks[0].Clips[0].Id);
        var g = dup.Tracks[0].Clips[0].LinkGroupId;
        g.ShouldNotBeNull();
        g.ShouldNotBe("g1");
        dup.Tracks[1].Clips[0].LinkGroupId.ShouldBe(g);
    }

    [Fact]
    public async Task DeleteKeepsAtLeastOneAndReactivates()
    {
        var (e, temp) = await EditorFixtures.MakeAsync();
        using var _ = temp;

        var firstId = e.ActiveTimelineId;
        e.DeleteTimeline(firstId);
        e.Timelines.Count.ShouldBe(1); // last timeline is not deletable

        var secondId = e.CreateTimeline();
        e.ActiveTimelineId.ShouldBe(secondId);
        e.DeleteTimeline(secondId);
        e.ActiveTimelineId.ShouldBe(firstId);
        e.Timelines.Count.ShouldBe(1);
        e.OpenTimelineIds.ShouldNotContain(secondId);
    }

    [Fact]
    public async Task DeleteUndoRestoresTimelineAndTab()
    {
        var (e, temp) = await EditorFixtures.MakeAsync();
        using var _ = temp;

        var secondId = e.CreateTimeline();
        e.Timeline.Tracks = [EditorFixtures.VideoTrack()];

        e.DeleteTimeline(secondId);
        e.TimelineFor(secondId).ShouldBeNull();

        e.Document.UndoService.Undo();
        e.TimelineFor(secondId)!.Tracks.Count.ShouldBe(1);
        e.OpenTimelineIds.ShouldContain(secondId);

        e.Document.UndoService.Redo();
        e.TimelineFor(secondId).ShouldBeNull();
    }

    [Fact]
    public async Task RenameTrimsAndUndoes()
    {
        var (e, temp) = await EditorFixtures.MakeAsync();
        using var _ = temp;

        var id = e.ActiveTimelineId;
        var original = e.Timeline.Name;
        e.RenameTimeline(id, "  Selects  ");
        e.Timeline.Name.ShouldBe("Selects");
        e.Document.UndoService.Undo();
        e.Timeline.Name.ShouldBe(original);
    }

    [Fact]
    public async Task CloseTabNeverClosesLastAndReactivatesNeighbor()
    {
        var (e, temp) = await EditorFixtures.MakeAsync();
        using var _ = temp;

        var firstId = e.ActiveTimelineId;
        var secondId = e.CreateTimeline();
        e.CloseTimelineTab(secondId);
        e.OpenTimelineIds.ShouldBe([firstId]);
        e.ActiveTimelineId.ShouldBe(firstId);
        e.TimelineFor(secondId).ShouldNotBeNull(); // closing a tab never deletes
        e.CloseTimelineTab(firstId);
        e.OpenTimelineIds.ShouldBe([firstId]);
    }

    [Fact]
    public async Task TimelineUndoReactivatesOwningTimeline()
    {
        var (e, temp) = await EditorFixtures.MakeAsync();
        using var _ = temp;

        var aId = e.ActiveTimelineId;
        var bId = e.CreateTimeline(activate: false);

        string? undoneOnTimeline = null;
        e.RegisterTimelineUndo("Probe", () => undoneOnTimeline = e.ActiveTimelineId);
        e.ActivateTimeline(bId);
        e.Document.UndoService.Undo();

        undoneOnTimeline.ShouldBe(aId);
        e.ActiveTimelineId.ShouldBe(aId);
    }
}
