using PalmierPro.Core.Models;
using Shouldly;
using Xunit;

namespace PalmierPro.App.Tests.ViewModels.Editor;

/// Mirrors Tests/PalmierProTests/Timeline/LinkingTests.swift, ported to
/// `TimelineEditorViewModel.Linking`: `LinkIndex`, `ExpandToLinkGroup`, `LinkedPartnerIds`,
/// `LinkGroupOffsets`, `LinkClips`, `UnlinkClips`. No Windows menu wires Link/Unlink to a command
/// yet, but the mutations themselves are ported — see this file's doc comment for the
/// multicam-cluster half of `LinkGroupOffsets` that is deliberately not ported.
public class LinkingTests
{
    private static Clip ClipWithGroup(string id, string? group, int start = 0, int duration = 30, ClipType mediaType = ClipType.Video)
    {
        var c = EditorFixtures.Clip(id: id, mediaType: mediaType, start: start, duration: duration);
        c.LinkGroupId = group;
        return c;
    }

    // MARK: - LinkIndex

    [Fact]
    public async Task LinkIndexMapsGroupIdsToMemberClipIds()
    {
        var v = ClipWithGroup("v", "g1");
        var a = ClipWithGroup("a", "g1", mediaType: ClipType.Audio);
        var solo = ClipWithGroup("solo", null);
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [v, solo]),
            EditorFixtures.AudioTrack(clips: [a]),
        ]);
        using var _ = temp;

        var idx = e.LinkIndex;
        idx["g1"].OrderBy(x => x).ShouldBe(["a", "v"]);
        idx.Values.Any(members => members.Contains("solo")).ShouldBeFalse();
    }

    [Fact]
    public async Task LinkIndexIsEmptyForUngroupedTimeline()
    {
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [EditorFixtures.Clip(id: "c1", start: 0, duration: 30)]),
        ]);
        using var _ = temp;

        e.LinkIndex.ShouldBeEmpty();
    }

    // MARK: - ExpandToLinkGroup

    [Fact]
    public async Task ExpandReturnsInputUnchangedWhenNoneAreLinked()
    {
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [EditorFixtures.Clip(id: "a", start: 0, duration: 30)]),
        ]);
        using var _ = temp;

        e.ExpandToLinkGroup(["a"]).ShouldBe(["a"]);
    }

    [Fact]
    public async Task ExpandPullsInAllPartnersOfATouchedGroup()
    {
        var v = ClipWithGroup("v", "g1");
        var a = ClipWithGroup("a", "g1", mediaType: ClipType.Audio);
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [v]),
            EditorFixtures.AudioTrack(clips: [a]),
        ]);
        using var _ = temp;

        // Asking for just "v" should return both halves of the group.
        e.ExpandToLinkGroup(["v"]).ShouldBe(["v", "a"], ignoreOrder: true);
    }

    [Fact]
    public async Task ExpandHandlesMultipleGroupsIndependently()
    {
        var v1 = ClipWithGroup("v1", "g1");
        var a1 = ClipWithGroup("a1", "g1", mediaType: ClipType.Audio);
        var v2 = ClipWithGroup("v2", "g2", start: 100);
        var a2 = ClipWithGroup("a2", "g2", start: 100, mediaType: ClipType.Audio);
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [v1, v2]),
            EditorFixtures.AudioTrack(clips: [a1, a2]),
        ]);
        using var _ = temp;

        var result = e.ExpandToLinkGroup(["v1", "v2"]);
        result.ShouldBe(["v1", "a1", "v2", "a2"], ignoreOrder: true);
    }

    // MARK: - LinkedPartnerIds

    [Fact]
    public async Task LinkedPartnersExcludeSelf()
    {
        var v = ClipWithGroup("v", "g1");
        var a = ClipWithGroup("a", "g1", mediaType: ClipType.Audio);
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [v]),
            EditorFixtures.AudioTrack(clips: [a]),
        ]);
        using var _ = temp;

        e.LinkedPartnerIds("v").ShouldBe(["a"]);
        e.LinkedPartnerIds("a").ShouldBe(["v"]);
    }

    [Fact]
    public async Task LinkedPartnersIsEmptyForUngroupedClip()
    {
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [EditorFixtures.Clip(id: "solo", start: 0, duration: 30)]),
        ]);
        using var _ = temp;

        e.LinkedPartnerIds("solo").ShouldBeEmpty();
    }

    [Fact]
    public async Task LinkedPartnersIsEmptyForUnknownClip()
    {
        var (e, temp) = await EditorFixtures.MakeAsync();
        using var _ = temp;

        e.LinkedPartnerIds("ghost").ShouldBeEmpty();
    }

    // MARK: - LinkGroupOffsets

    [Fact]
    public async Task LinkGroupOffsetsReturnsEmptyWhenPartnersInSync()
    {
        // Both clips start at frame 100, both with TrimStartFrame=0 -> in sync.
        var v = ClipWithGroup("v", "g1", start: 100);
        var a = ClipWithGroup("a", "g1", start: 100, mediaType: ClipType.Audio);
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [v]),
            EditorFixtures.AudioTrack(clips: [a]),
        ]);
        using var _ = temp;

        e.LinkGroupOffsets().ShouldBeEmpty();
    }

    [Fact]
    public async Task LinkGroupOffsetsReportsDeltaForOutOfSyncPartner()
    {
        // v at frame 100, a at frame 110 -- a is 10 frames ahead of the shared zero.
        var v = ClipWithGroup("v", "g1", start: 100);
        var a = ClipWithGroup("a", "g1", start: 110, mediaType: ClipType.Audio);
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [v]),
            EditorFixtures.AudioTrack(clips: [a]),
        ]);
        using var _ = temp;

        var offsets = e.LinkGroupOffsets();
        offsets.ContainsKey("v").ShouldBeFalse(); // v is the earliest, no offset
        offsets["a"].ShouldBe(10);
    }

    [Fact]
    public async Task LinkGroupOffsetsIgnoresSingletonGroups()
    {
        // A group with only one member can't be out of sync with anything.
        var solo = ClipWithGroup("solo", "g1");
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [solo])]);
        using var _ = temp;

        e.LinkGroupOffsets().ShouldBeEmpty();
    }

    // MARK: - LinkClips / UnlinkClips

    [Fact]
    public async Task LinkClipsStampsSharedGroupOnTwoOrMoreSelectedClips()
    {
        var c1 = EditorFixtures.Clip(id: "c1", start: 0, duration: 30);
        var c2 = EditorFixtures.Clip(id: "c2", mediaType: ClipType.Audio, start: 0, duration: 30);
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [c1]),
            EditorFixtures.AudioTrack(clips: [c2]),
        ]);
        using var _ = temp;

        e.LinkClips(new HashSet<string> { "c1", "c2" });
        var groups = e.Timeline.Tracks.SelectMany(t => t.Clips).Select(c => c.LinkGroupId).Where(g => g is not null).ToList();
        groups.Count.ShouldBe(2);
        groups.Distinct().Count().ShouldBe(1); // both clips should share a single group id
    }

    [Fact]
    public async Task LinkClipsRequiresAtLeastTwoClips()
    {
        // Linking just one clip is meaningless and should be a no-op.
        var c1 = EditorFixtures.Clip(id: "c1", start: 0, duration: 30);
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [c1])]);
        using var _ = temp;

        e.LinkClips(new HashSet<string> { "c1" });
        e.Timeline.Tracks[0].Clips[0].LinkGroupId.ShouldBeNull();
    }

    [Fact]
    public async Task UnlinkClipsClearsGroupOnAllPartners()
    {
        var v = ClipWithGroup("v", "g1");
        var a = ClipWithGroup("a", "g1", mediaType: ClipType.Audio);
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [v]),
            EditorFixtures.AudioTrack(clips: [a]),
        ]);
        using var _ = temp;

        // Pass just one of the pair; unlink should expand to the partner.
        e.UnlinkClips(new HashSet<string> { "v" });
        e.Timeline.Tracks[0].Clips[0].LinkGroupId.ShouldBeNull();
        e.Timeline.Tracks[1].Clips[0].LinkGroupId.ShouldBeNull();
    }
}
