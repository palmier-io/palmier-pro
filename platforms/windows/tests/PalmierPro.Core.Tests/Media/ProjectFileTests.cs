using System.Text;
using System.Text.Json;
using PalmierPro.Core.Models;
using Shouldly;
using Xunit;

namespace PalmierPro.Core.Tests;

/// Mirrors Tests/PalmierProTests/Timeline/MultiTimelineTests.swift's `ProjectFilePersistenceTests`.
public class ProjectFileTests
{
    private static byte[] Utf8(string s) => Encoding.UTF8.GetBytes(s);

    [Fact]
    public void LegacyBareTimelineDecodesAndWraps()
    {
        var legacy = Fixtures.Timeline(fps: 24, tracks: [Fixtures.VideoTrack(clips: [Fixtures.Clip(start: 0, duration: 10)])]);
        var data = Utf8(JsonSerializer.Serialize(legacy));

        var file = ProjectFile.Decode(data);

        file.Timelines.Count.ShouldBe(1);
        file.Timelines[0].Fps.ShouldBe(24);
        file.ActiveTimelineId.ShouldBe(file.Timelines[0].Id);
        file.OpenTimelineIds.ShouldBe([file.Timelines[0].Id]);
    }

    [Fact]
    public void LegacyTimelineWithoutIdGetsOne()
    {
        const string json = """{"fps": 30, "width": 1920, "height": 1080, "settingsConfigured": true, "tracks": []}""";
        var file = ProjectFile.Decode(Utf8(json));
        file.Timelines[0].Id.ShouldNotBeNullOrEmpty();
        file.Timelines[0].Name.ShouldBe("Timeline 1");
        file.Timelines[0].SettingsConfigured.ShouldBeTrue();
    }

    [Fact]
    public void EmptyTimelinesArrayFallsBackToLegacyDecodeAndThenThrows()
    {
        // A structurally valid ProjectFile with `timelines: []` is treated the same as a decode
        // failure (Swift's explicit dataCorrupted guard) — it also isn't a valid bare Timeline,
        // so decode must throw rather than silently returning an empty project.
        const string json = """{"timelines": []}""";
        Should.Throw<JsonException>(() => ProjectFile.Decode(Utf8(json)));
    }

    [Fact]
    public void GarbageThrows()
    {
        Should.Throw<JsonException>(() => ProjectFile.Decode(Utf8("{ not json")));
    }

    [Fact]
    public void ProjectFileRoundTripsViewStateTabsAndMulticamGroups()
    {
        var a = Fixtures.Timeline();
        a.Name = "Main";
        a.Tracks = [Fixtures.VideoTrack()];
        a.Tracks[0].DisplayHeight = 88;
        var b = Fixtures.Timeline();
        b.Name = "Vertical";
        var vs = new TimelineViewState { PlayheadFrame = 42, ZoomScale = 7, ScrollOffsetX = 300 };
        var multicam = new MulticamSource { Id = "mc1", Name = "Interview", MasterMemberId = "m1" };

        var file = new ProjectFile(
            [a, b], activeTimelineId: b.Id, openTimelineIds: [a.Id, b.Id],
            viewStates: new Dictionary<string, TimelineViewState> { [a.Id] = vs },
            multicamGroups: [multicam]);

        var data = Utf8(JsonSerializer.Serialize(file));
        var decoded = ProjectFile.Decode(data);

        decoded.Timelines.Select(t => t.Name).ShouldBe(["Main", "Vertical"]);
        decoded.ActiveTimelineId.ShouldBe(b.Id);
        decoded.OpenTimelineIds.ShouldBe([a.Id, b.Id]);
        decoded.ViewStates![a.Id].PlayheadFrame.ShouldBe(42);
        decoded.ViewStates[a.Id].ZoomScale.ShouldBe(7);
        decoded.ViewStates[a.Id].ScrollOffsetX.ShouldBe(300);
        decoded.Timelines[0].Tracks[0].DisplayHeight.ShouldBe(88);
        decoded.MulticamGroups![0].Id.ShouldBe("mc1");
    }

    [Fact]
    public void TimelineFolderIdPersists()
    {
        var t = Fixtures.Timeline();
        t.FolderId = "f1";
        var file = new ProjectFile([t], t.Id, [t.Id]);

        var decoded = ProjectFile.Decode(Utf8(JsonSerializer.Serialize(file)));

        decoded.Timelines[0].FolderId.ShouldBe("f1");
    }

    [Fact]
    public void OptionalFieldsOmittedOnWriteWhenNull()
    {
        var file = new ProjectFile([Fixtures.Timeline()]);
        var json = JsonSerializer.Serialize(file);
        json.ShouldNotContain("activeTimelineId");
        json.ShouldNotContain("openTimelineIds");
        json.ShouldNotContain("viewStates");
        json.ShouldNotContain("speakers");
        json.ShouldNotContain("multicamGroups");
    }

    [Fact]
    public void SpeakersRoundTrip()
    {
        var t = Fixtures.Timeline();
        var file = new ProjectFile(
            [t], speakers: [new SpeakerRegistryEntry { Id = 0, Name = "Alex", Color = [1, 0, 0], Centroid = [0.1f, 0.2f] }]);

        var decoded = ProjectFile.Decode(Utf8(JsonSerializer.Serialize(file)));

        decoded.Speakers![0].Name.ShouldBe("Alex");
        decoded.Speakers[0].Centroid.ShouldBe([0.1f, 0.2f]);
    }
}
