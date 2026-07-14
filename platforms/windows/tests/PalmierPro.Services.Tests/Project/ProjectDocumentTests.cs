using PalmierPro.Core.Models;
using PalmierPro.Services.Project;
using Shouldly;
using Xunit;

namespace PalmierPro.Services.Tests;

public class ProjectDocumentTests
{
    [Fact]
    public async Task CreateNewAsync_WritesAnEmptyTimelinePackage()
    {
        using var tmp = new TempDirectory();
        var doc = await ProjectDocument.CreateNewAsync(tmp.Path, "My Project");

        doc.PackagePath.ShouldBe(Path.Combine(tmp.Path, "My Project.palmier"));
        Directory.Exists(doc.PackagePath).ShouldBeTrue();
        File.Exists(Path.Combine(doc.PackagePath, "project.json")).ShouldBeTrue();
        doc.ProjectFile.Timelines.Count.ShouldBe(1);
        doc.ProjectFile.Timelines[0].Tracks.ShouldBeEmpty();
        doc.IsDirty.ShouldBeFalse();
    }

    [Theory]
    [InlineData("a/b")]
    [InlineData(@"a\b")]
    [InlineData(".")]
    [InlineData("..")]
    public async Task CreateNewAsync_RejectsInvalidNames(string name)
    {
        using var tmp = new TempDirectory();
        await Should.ThrowAsync<ArgumentException>(() => ProjectDocument.CreateNewAsync(tmp.Path, name));
    }

    [Fact]
    public async Task CreateNewAsync_RollsBackOnNameCollision()
    {
        using var tmp = new TempDirectory();
        await ProjectDocument.CreateNewAsync(tmp.Path, "Taken");

        await Should.ThrowAsync<IOException>(() => ProjectDocument.CreateNewAsync(tmp.Path, "Taken"));
    }

    [Fact]
    public async Task CreateSaveReopen_PreservesProjectFileContents()
    {
        using var tmp = new TempDirectory();
        var doc = await ProjectDocument.CreateNewAsync(tmp.Path, "Round Trip");
        doc.ProjectFile.Timelines[0].Tracks.Add(TestFixtures.VideoTrack(TestFixtures.Clip(duration: 90)));
        doc.ProjectFile.Timelines[0].Name = "Main";
        await doc.SaveAsync();

        var reopened = await ProjectDocument.OpenAsync(doc.PackagePath);

        reopened.ProjectFile.Timelines.Count.ShouldBe(1);
        reopened.ProjectFile.Timelines[0].Name.ShouldBe("Main");
        reopened.ProjectFile.Timelines[0].Tracks.Count.ShouldBe(1);
        reopened.ProjectFile.Timelines[0].Tracks[0].Clips.Count.ShouldBe(1);
        reopened.ProjectFile.Timelines[0].Tracks[0].Clips[0].DurationFrames.ShouldBe(90);
        reopened.ProjectFile.ActiveTimelineId.ShouldBe(doc.ProjectFile.ActiveTimelineId);
        reopened.ProjectFile.OpenTimelineIds.ShouldBe(doc.ProjectFile.OpenTimelineIds);
    }

    [Fact]
    public async Task SecondSave_IsByteIdenticalWithNoIntervalChanges()
    {
        using var tmp = new TempDirectory();
        var doc = await ProjectDocument.CreateNewAsync(tmp.Path, "Stability");
        var timelinePath = Path.Combine(doc.PackagePath, "project.json");
        var manifestPath = Path.Combine(doc.PackagePath, "media.json");
        var logPath = Path.Combine(doc.PackagePath, "generation-log.json");
        var firstTimeline = await File.ReadAllBytesAsync(timelinePath);
        var firstManifest = await File.ReadAllBytesAsync(manifestPath);
        var firstLog = await File.ReadAllBytesAsync(logPath);

        await doc.SaveAsync();

        (await File.ReadAllBytesAsync(timelinePath)).ShouldBe(firstTimeline);
        (await File.ReadAllBytesAsync(manifestPath)).ShouldBe(firstManifest);
        (await File.ReadAllBytesAsync(logPath)).ShouldBe(firstLog);
    }

    [Fact]
    public async Task MultiTimelineAndMulticamGroups_SurviveFullPackageRoundTrip()
    {
        using var tmp = new TempDirectory();
        var doc = await ProjectDocument.CreateNewAsync(tmp.Path, "Multicam");

        var timelineB = TestFixtures.Timeline(TestFixtures.VideoTrack(TestFixtures.Clip(mediaRef: "cam-a", duration: 60)));
        doc.ProjectFile.Timelines.Add(timelineB);
        doc.ProjectFile.OpenTimelineIds = [doc.ProjectFile.Timelines[0].Id, timelineB.Id];
        doc.ProjectFile.ActiveTimelineId = timelineB.Id;
        doc.ProjectFile.MulticamGroups =
        [
            new MulticamSource
            {
                Id = "group-1",
                Name = "Interview",
                MasterMemberId = "a",
                Members =
                [
                    new MulticamMember
                    {
                        Id = "a", MediaRef = "cam-a", Kind = MulticamMemberKind.Angle, AngleLabel = "Cam A",
                        Sync = new MulticamSyncMap { Locked = true },
                    },
                    new MulticamMember
                    {
                        Id = "b", MediaRef = "cam-b", Kind = MulticamMemberKind.Angle, AngleLabel = "Cam B",
                        Sync = new MulticamSyncMap { OffsetSeconds = 1.5, Confidence = 0.8 },
                    },
                ],
            },
        ];

        await doc.SaveAsync();
        var reopened = await ProjectDocument.OpenAsync(doc.PackagePath);

        reopened.ProjectFile.Timelines.Count.ShouldBe(2);
        reopened.ProjectFile.ActiveTimelineId.ShouldBe(timelineB.Id);
        reopened.ProjectFile.OpenTimelineIds.ShouldBe(doc.ProjectFile.OpenTimelineIds);
        reopened.ProjectFile.MulticamGroups.ShouldNotBeNull();
        reopened.ProjectFile.MulticamGroups!.Count.ShouldBe(1);
        var group = reopened.ProjectFile.MulticamGroups![0];
        group.Members.Count.ShouldBe(2);
        group.Master!.Id.ShouldBe("a");
        group.Members[1].Sync.OffsetSeconds.ShouldBe(1.5);
        group.Members[1].Sync.Confidence.ShouldBe(0.8);
    }

    [Fact]
    public async Task UndoServiceChanged_MarksDocumentDirty_AndSaveClearsIt()
    {
        using var tmp = new TempDirectory();
        var doc = await ProjectDocument.CreateNewAsync(tmp.Path, "Dirty");
        doc.IsDirty.ShouldBeFalse();

        doc.UndoService.RegisterUndo("Edit", () => { });
        doc.IsDirty.ShouldBeTrue();

        await doc.SaveAsync();
        doc.IsDirty.ShouldBeFalse();
    }

    [Fact]
    public async Task UndoBackToSavedState_ClearsDirtyWithoutSaving()
    {
        using var tmp = new TempDirectory();
        var doc = await ProjectDocument.CreateNewAsync(tmp.Path, "Undo Clean");
        doc.IsDirty.ShouldBeFalse();

        doc.UndoService.RegisterUndo("Edit", () => { });
        doc.IsDirty.ShouldBeTrue();

        doc.UndoService.Undo();

        doc.IsDirty.ShouldBeFalse();
    }

    [Fact]
    public async Task Reopen_ThenSave_IsByteIdentical()
    {
        using var tmp = new TempDirectory();
        var doc = await ProjectDocument.CreateNewAsync(tmp.Path, "Reopen Stability");
        var timelinePath = Path.Combine(doc.PackagePath, "project.json");
        var manifestPath = Path.Combine(doc.PackagePath, "media.json");
        var logPath = Path.Combine(doc.PackagePath, "generation-log.json");
        var firstTimeline = await File.ReadAllBytesAsync(timelinePath);
        var firstManifest = await File.ReadAllBytesAsync(manifestPath);
        var firstLog = await File.ReadAllBytesAsync(logPath);

        var reopened = await ProjectDocument.OpenAsync(doc.PackagePath);
        await reopened.SaveAsync();

        (await File.ReadAllBytesAsync(timelinePath)).ShouldBe(firstTimeline);
        (await File.ReadAllBytesAsync(manifestPath)).ShouldBe(firstManifest);
        (await File.ReadAllBytesAsync(logPath)).ShouldBe(firstLog);
    }

    [Fact]
    public async Task MarkDirty_RaisesDirtyChangedOnlyOnTransition()
    {
        using var tmp = new TempDirectory();
        var doc = await ProjectDocument.CreateNewAsync(tmp.Path, "Explicit Dirty");
        var raises = 0;
        doc.DirtyChanged += (_, _) => raises++;

        doc.MarkDirty();
        doc.MarkDirty();

        doc.IsDirty.ShouldBeTrue();
        raises.ShouldBe(1);
    }

    [Fact]
    public async Task SaveAsAsync_CopiesMediaAndPreservesThumbnail_AndRaisesPathChanged()
    {
        using var tmp = new TempDirectory();
        var doc = await ProjectDocument.CreateNewAsync(tmp.Path, "Original");
        var oldPath = doc.PackagePath;

        Directory.CreateDirectory(Path.Combine(oldPath, "media"));
        await File.WriteAllBytesAsync(Path.Combine(oldPath, "media", "clip.mov"), [1, 2, 3]);
        await File.WriteAllBytesAsync(Path.Combine(oldPath, "thumbnail.jpg"), [9, 9, 9]);

        string? changedFrom = null;
        doc.PathChanged += (_, from) => changedFrom = from;

        var newPath = Path.Combine(tmp.Path, "Renamed.palmier");
        await doc.SaveAsAsync(newPath);

        doc.PackagePath.ShouldBe(newPath);
        changedFrom.ShouldBe(oldPath);
        File.Exists(Path.Combine(newPath, "media", "clip.mov")).ShouldBeTrue();
        File.Exists(Path.Combine(newPath, "thumbnail.jpg")).ShouldBeTrue();
    }

    [Fact]
    public async Task Save_WithUnreadableManifest_PreservesOriginalBytesUntouched()
    {
        using var tmp = new TempDirectory();
        var doc = await ProjectDocument.CreateNewAsync(tmp.Path, "Corrupt Manifest");
        var manifestPath = Path.Combine(doc.PackagePath, "media.json");
        var corrupt = "{ not valid json"u8.ToArray();
        await File.WriteAllBytesAsync(manifestPath, corrupt);

        var reopened = await ProjectDocument.OpenAsync(doc.PackagePath);
        reopened.ManifestLoadFailed.ShouldBeTrue();

        // Editing the timeline (not the manifest) and saving must not clobber the recoverable
        // corrupt manifest with a freshly-empty one.
        reopened.ProjectFile.Timelines[0].Name = "Edited";
        await reopened.SaveAsync();

        (await File.ReadAllBytesAsync(manifestPath)).ShouldBe(corrupt);
        reopened.ManifestLoadFailed.ShouldBeTrue();
    }

    [Fact]
    public async Task RequestCheckpointAutosaveAsync_CoalescesConcurrentCallsIntoOneSave()
    {
        using var tmp = new TempDirectory();
        var doc = await ProjectDocument.CreateNewAsync(tmp.Path, "Checkpoint");
        var saveCount = 0;
        doc.Saved += (_, _) => saveCount++;

        var first = doc.RequestCheckpointAutosaveAsync();
        var second = doc.RequestCheckpointAutosaveAsync();
        await Task.WhenAll(first, second);

        saveCount.ShouldBe(1);
    }

    [Fact]
    public async Task CloseAsync_FlushesPendingDirtyStateAndRaisesClosed()
    {
        using var tmp = new TempDirectory();
        var doc = await ProjectDocument.CreateNewAsync(tmp.Path, "Closing");
        doc.MarkDirty();
        var closed = false;
        doc.Closed += (_, _) => closed = true;

        await doc.CloseAsync();

        doc.IsDirty.ShouldBeFalse();
        closed.ShouldBeTrue();
    }

    [Fact]
    public async Task OpenAsync_MissingPackageDirectory_Throws()
    {
        using var tmp = new TempDirectory();
        await Should.ThrowAsync<DirectoryNotFoundException>(
            () => ProjectDocument.OpenAsync(Path.Combine(tmp.Path, "Nope.palmier")));
    }

    [Fact]
    public async Task OpenAsync_MissingTimelineFile_Throws()
    {
        using var tmp = new TempDirectory();
        var packagePath = Path.Combine(tmp.Path, "Empty.palmier");
        Directory.CreateDirectory(packagePath);

        await Should.ThrowAsync<ProjectPackageCorruptException>(() => ProjectDocument.OpenAsync(packagePath));
    }
}
