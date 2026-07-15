using PalmierPro.App.ViewModels.Editor;
using Shouldly;
using Xunit;

namespace PalmierPro.App.Tests.ViewModels.Editor;

/// Mirrors Tests/PalmierProTests/Timeline/TimelineForwardSelectionTests.swift.
public class SelectionTests
{
    [Fact]
    public async Task SelectForwardOnTrackIncludesAnchorAndLaterClipsOnlyOnAnchorTrack()
    {
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [
                EditorFixtures.Clip(id: "before", start: 0, duration: 20),
                EditorFixtures.Clip(id: "anchor", start: 30, duration: 20),
                EditorFixtures.Clip(id: "after", start: 70, duration: 20),
            ]),
            EditorFixtures.AudioTrack(clips: [
                EditorFixtures.Clip(id: "other", mediaType: Core.Models.ClipType.Audio, start: 40, duration: 20),
            ]),
        ]);
        using var _ = temp;

        e.SelectForward("anchor", TimelineEditorViewModel.SelectForwardScope.Track);

        e.SelectedClipIds.ShouldBe(["anchor", "after"], ignoreOrder: true);
    }

    [Fact]
    public async Task SelectForwardOnAllTracksUsesAnchorFrameAcrossTimeline()
    {
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [
                EditorFixtures.Clip(id: "before", start: 0, duration: 20),
                EditorFixtures.Clip(id: "anchor", start: 30, duration: 20),
            ]),
            EditorFixtures.AudioTrack(clips: [
                EditorFixtures.Clip(id: "sameFrame", mediaType: Core.Models.ClipType.Audio, start: 30, duration: 20),
                EditorFixtures.Clip(id: "after", mediaType: Core.Models.ClipType.Audio, start: 90, duration: 20),
            ]),
        ]);
        using var _ = temp;

        e.SelectForward("anchor", TimelineEditorViewModel.SelectForwardScope.AllTracks);

        e.SelectedClipIds.ShouldBe(["anchor", "sameFrame", "after"], ignoreOrder: true);
    }

    [Fact]
    public async Task SelectForwardExpandsLinkedPartners()
    {
        var anchor = EditorFixtures.Clip(id: "anchor", start: 30, duration: 20);
        anchor.LinkGroupId = "g1";
        var linkedAudio = EditorFixtures.Clip(id: "linkedAudio", mediaType: Core.Models.ClipType.Audio, start: 10, duration: 20);
        linkedAudio.LinkGroupId = "g1";
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [anchor]),
            EditorFixtures.AudioTrack(clips: [linkedAudio]),
        ]);
        using var _ = temp;

        e.SelectForward("anchor", TimelineEditorViewModel.SelectForwardScope.Track);

        e.SelectedClipIds.ShouldBe(["anchor", "linkedAudio"], ignoreOrder: true);
    }

    [Fact]
    public async Task CurrentSelectionUsesEarliestSelectedClipAsAnchor()
    {
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [
                EditorFixtures.Clip(id: "first", start: 20, duration: 20),
                EditorFixtures.Clip(id: "second", start: 60, duration: 20),
                EditorFixtures.Clip(id: "third", start: 100, duration: 20),
            ]),
        ]);
        using var _ = temp;

        e.SelectedClipIds = ["second", "third"];

        e.SelectForwardFromCurrentSelection(TimelineEditorViewModel.SelectForwardScope.Track);

        e.SelectedClipIds.ShouldBe(["second", "third"], ignoreOrder: true);
    }
}
