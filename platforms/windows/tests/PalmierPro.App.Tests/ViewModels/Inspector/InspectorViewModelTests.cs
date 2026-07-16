using PalmierPro.App.Tests.ViewModels.Editor;
using PalmierPro.App.ViewModels.Editor;
using PalmierPro.App.ViewModels.Inspector;
using PalmierPro.Core.Models;
using Shouldly;
using Xunit;

namespace PalmierPro.App.Tests.ViewModels.Inspector;

/// Mirrors Inspector/InspectorView.swift's selection-driven tab logic (`availableTabs`/
/// `resolvePreferredTab`), trimmed to the four Windows-owned tabs (Video, Keyframes, Effects,
/// Text) — see InspectorViewModel's class doc for why Multicam/AI/Audio aren't offered.
public class InspectorViewModelTests
{
    [Fact]
    public void NoTimelineStartsInNoneStateWithNoTabs()
    {
        var vm = new InspectorViewModel();

        vm.SelectionState.ShouldBe(InspectorSelectionState.None);
        vm.AvailableTabs.ShouldBeEmpty();
        vm.ActiveTab.ShouldBeNull();
    }

    [Fact]
    public async Task NoSelectionIsNoneState()
    {
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [EditorFixtures.Clip(id: "a", start: 0, duration: 20)]),
        ]);
        using var _ = temp;
        var vm = new InspectorViewModel();

        vm.SetTimeline(e);

        vm.SelectionState.ShouldBe(InspectorSelectionState.None);
        vm.AvailableTabs.ShouldBeEmpty();
        vm.ActiveTab.ShouldBeNull();
    }

    [Fact]
    public async Task SingleVideoClipOffersVideoKeyframesEffectsAndColorWithVideoActive()
    {
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [EditorFixtures.Clip(id: "a", start: 0, duration: 20)]),
        ]);
        using var _ = temp;
        var vm = new InspectorViewModel();
        vm.SetTimeline(e);

        e.SelectedClipIds = ["a"];

        vm.SelectionState.ShouldBe(InspectorSelectionState.Single);
        vm.SelectedClips.Select(c => c.Id).ShouldBe(["a"]);
        vm.AvailableTabs.ShouldBe([InspectorTab.Video, InspectorTab.Keyframes, InspectorTab.Effects, InspectorTab.Color]);
        vm.ActiveTab.ShouldBe(InspectorTab.Video);
    }

    [Fact]
    public async Task MultiClipSelectionDropsKeyframesTab()
    {
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [
                EditorFixtures.Clip(id: "a", start: 0, duration: 20),
                EditorFixtures.Clip(id: "b", start: 20, duration: 20),
            ]),
        ]);
        using var _ = temp;
        var vm = new InspectorViewModel();
        vm.SetTimeline(e);

        e.SelectedClipIds = ["a", "b"];

        vm.SelectionState.ShouldBe(InspectorSelectionState.Multi);
        vm.AvailableTabs.ShouldBe([InspectorTab.Video, InspectorTab.Effects, InspectorTab.Color]);
    }

    [Fact]
    public async Task TextOnlySelectionOffersOnlyTextTab()
    {
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [EditorFixtures.Clip(id: "t", mediaType: ClipType.Text, start: 0, duration: 20)]),
        ]);
        using var _ = temp;
        var vm = new InspectorViewModel();
        vm.SetTimeline(e);

        e.SelectedClipIds = ["t"];

        vm.AvailableTabs.ShouldBe([InspectorTab.Text]);
        vm.ActiveTab.ShouldBe(InspectorTab.Text);
    }

    [Fact]
    public async Task AudioOnlySelectionOffersNoTabs()
    {
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.AudioTrack(clips: [EditorFixtures.Clip(id: "a", mediaType: ClipType.Audio, start: 0, duration: 20)]),
        ]);
        using var _ = temp;
        var vm = new InspectorViewModel();
        vm.SetTimeline(e);

        e.SelectedClipIds = ["a"];

        vm.SelectionState.ShouldBe(InspectorSelectionState.Single);
        vm.AvailableTabs.ShouldBeEmpty();
        vm.ActiveTab.ShouldBeNull();
    }

    [Fact]
    public async Task SelectTabIsNoOpForATabNotCurrentlyOffered()
    {
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [
                EditorFixtures.Clip(id: "a", start: 0, duration: 20),
                EditorFixtures.Clip(id: "b", start: 20, duration: 20),
            ]),
        ]);
        using var _ = temp;
        var vm = new InspectorViewModel();
        vm.SetTimeline(e);
        e.SelectedClipIds = ["a", "b"]; // Multi — Keyframes isn't offered.

        vm.SelectTab(InspectorTab.Keyframes);

        vm.ActiveTab.ShouldBe(InspectorTab.Video);
    }

    [Fact]
    public async Task PreferredTabSurvivesASelectionChangeThatStillOffersIt()
    {
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [
                EditorFixtures.Clip(id: "a", start: 0, duration: 20),
                EditorFixtures.Clip(id: "b", start: 20, duration: 20),
            ]),
        ]);
        using var _ = temp;
        var vm = new InspectorViewModel();
        vm.SetTimeline(e);
        e.SelectedClipIds = ["a"];
        vm.SelectTab(InspectorTab.Effects);

        e.SelectedClipIds = ["b"]; // Still single, non-text — Effects remains offered.

        vm.ActiveTab.ShouldBe(InspectorTab.Effects);
    }

    [Fact]
    public async Task PreferredTabFallsBackWhenNoLongerOffered()
    {
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [EditorFixtures.Clip(id: "a", start: 0, duration: 20)]),
        ]);
        using var _ = temp;
        var vm = new InspectorViewModel();
        vm.SetTimeline(e);
        e.SelectedClipIds = ["a"];
        vm.SelectTab(InspectorTab.Keyframes);

        e.SelectedClipIds = []; // None — deselecting drops every tab.

        vm.ActiveTab.ShouldBeNull();
        vm.AvailableTabs.ShouldBeEmpty();
    }

    [Fact]
    public async Task EmptyStateMetadataReflectsTheActiveTimeline()
    {
        var (e, temp) = await EditorFixtures.MakeAsync();
        using var _ = temp;
        e.Timeline.Name = "Main";
        e.Timeline.Width = 1920;
        e.Timeline.Height = 1080;
        e.Timeline.Fps = 30;
        var vm = new InspectorViewModel();

        vm.SetTimeline(e);

        vm.TimelineName.ShouldBe("Main");
        vm.TimelineWidth.ShouldBe(1920);
        vm.TimelineHeight.ShouldBe(1080);
        vm.TimelineFps.ShouldBe(30);
        vm.TimelineAspectRatioText.ShouldBe("16:9");
        vm.TimelineDurationText.ShouldBe("0:00");
    }

    [Fact]
    public void SetTimelineNullClearsSelectionState()
    {
        var vm = new InspectorViewModel();

        vm.SetTimeline(null);

        vm.SelectionState.ShouldBe(InspectorSelectionState.None);
        vm.TimelineName.ShouldBe("");
    }
}
