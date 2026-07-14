using System.Text;
using PalmierPro.Core.Json;
using PalmierPro.Core.Models;
using PalmierPro.Services.Engine;
using PalmierPro.Services.Tests;
using Shouldly;
using Xunit;

namespace PalmierPro.Services.Tests.Engine;

/// See docs/timeline-snapshot-v1.md for the schema these assertions pin down.
public class TimelineSnapshotBuilderTests
{
    // ----- fixture builders -----

    private static Clip Clip(
        string mediaRef, int start, int duration, string id = "", ClipType type = ClipType.Video,
        int trimStart = 0, double speed = 1.0, double volume = 1.0, string? multicamGroupId = null) =>
        new(mediaRef, start, duration)
        {
            Id = id.Length == 0 ? SwiftId.New() : id,
            MediaType = type,
            SourceClipType = type,
            TrimStartFrame = trimStart,
            Speed = speed,
            Volume = volume,
            MulticamGroupId = multicamGroupId,
        };

    private static (ProjectFile Project, MediaManifest Manifest, TempDirectory Dir) SingleTrackProject(params Clip[] clips)
    {
        var dir = new TempDirectory();
        var track = new Track(ClipType.Video, [.. clips]) { Id = "TRACK-1" };
        var timeline = new Timeline { Id = "TL-1", Fps = 30, Width = 1920, Height = 1080, Tracks = [track] };
        var project = new ProjectFile([timeline], timeline.Id, [timeline.Id]);
        var entries = clips.Select(c => c.MediaRef).Distinct().Select(MakeEntry(dir));
        return (project, new MediaManifest { Entries = [.. entries] }, dir);
    }

    private static Func<string, MediaManifestEntry> MakeEntry(TempDirectory dir) => mediaRef =>
    {
        var path = Path.Combine(dir.Path, $"{mediaRef}.mp4");
        File.WriteAllBytes(path, []);
        return new MediaManifestEntry(mediaRef, mediaRef, ClipType.Video, MediaSource.External(path), duration: 10);
    };

    private static MediaResolver Resolver(MediaManifest manifest) => new(() => manifest, () => null);

    // ----- 1. nested sequence flattens to expected track/clip list -----

    [Fact]
    public void NestedSequenceFlattensToExpectedTrackAndClipList()
    {
        var dir = new TempDirectory();
        try
        {
            var childClip = Clip("child-media", start: 0, duration: 50, id: "CHILD-CLIP");
            var childTrack = new Track(ClipType.Video, [childClip]) { Id = "CHILD-TRACK" };
            var child = new Timeline { Id = "CHILD", Fps = 30, Width = 1920, Height = 1080, Tracks = [childTrack] };

            var seqClip = new Clip("CHILD", startFrame: 20, durationFrames: 30)
            {
                Id = "SEQ-CLIP", MediaType = ClipType.Sequence, SourceClipType = ClipType.Sequence,
            };
            var rootTrack = new Track(ClipType.Video, [seqClip]) { Id = "ROOT-TRACK" };
            var root = new Timeline { Id = "ROOT", Fps = 30, Width = 1920, Height = 1080, Tracks = [rootTrack] };

            var project = new ProjectFile([root, child], root.Id, [root.Id, child.Id]);
            var childMediaPath = Path.Combine(dir.Path, "child-media.mp4");
            File.WriteAllBytes(childMediaPath, []);
            var manifest = new MediaManifest
            {
                Entries = [new MediaManifestEntry("child-media", "child-media", ClipType.Video, MediaSource.External(childMediaPath), 10)],
            };

            var result = TimelineSnapshotBuilder.Build(project, "ROOT", Resolver(manifest));

            // The root track's ONLY clip is the sequence carrier -> no "ROOT-TRACK" own-clips lane
            // is emitted; exactly one synthetic track is spliced in for the child's one video track.
            var track = result.Snapshot.Tracks.ShouldHaveSingleItem();
            track.Id.ShouldBe("SEQ-CLIP#v0");
            var clip = track.Clips.ShouldHaveSingleItem();
            clip.Id.ShouldBe("SEQ-CLIP/CHILD-CLIP");
            clip.StartFrame.ShouldBe(20); // shift = seqClip.StartFrame(20) - seqClip.TrimStartFrame(0) = 20
            clip.DurationFrames.ShouldBe(30); // clamped to the carrier's window (30 frames), not the child clip's own 50
            clip.MediaPath.ShouldBe(childMediaPath);
            result.OfflineMediaRefs.ShouldBeEmpty();
        }
        finally
        {
            dir.Dispose();
        }
    }

    // ----- 2. multicam clip resolves to (whatever) its own mediaRef already points at -----

    [Fact]
    public void MulticamClipResolvesLikeAnyOtherClip()
    {
        // Angle switching on the Mac rewrites Clip.MediaRef destructively at switch time (see
        // MulticamEngine.rewrite) — by the time a clip reaches the builder, MulticamGroupId is
        // just along for the ride. There is no separate "active angle" indirection to resolve.
        var clip = Clip("angle-b-media", start: 0, duration: 30, multicamGroupId: "GROUP-1");
        var (project, manifest, dir) = SingleTrackProject(clip);
        try
        {
            var result = TimelineSnapshotBuilder.Build(project, "TL-1", Resolver(manifest));

            var emitted = result.Snapshot.Tracks.ShouldHaveSingleItem().Clips.ShouldHaveSingleItem();
            emitted.MediaPath.ShouldBe(Path.Combine(dir.Path, "angle-b-media.mp4"));
            result.OfflineMediaRefs.ShouldBeEmpty();
        }
        finally
        {
            dir.Dispose();
        }
    }

    // ----- 3. missing media collected + clip skipped -----

    [Fact]
    public void MissingMediaIsCollectedAndClipIsSkipped()
    {
        var present = Clip("present", start: 0, duration: 30, id: "PRESENT");
        var missing = Clip("missing", start: 30, duration: 30, id: "MISSING");
        var (project, manifestBase, dir) = SingleTrackProject(present); // manifest only has "present"
        try
        {
            var track = project.Timelines[0].Tracks[0];
            track.Clips.Add(missing);

            var result = TimelineSnapshotBuilder.Build(project, "TL-1", Resolver(manifestBase));

            var clips = result.Snapshot.Tracks.ShouldHaveSingleItem().Clips;
            clips.ShouldHaveSingleItem().Id.ShouldBe("PRESENT");
            result.OfflineMediaRefs.ShouldBe(["missing"]);
        }
        finally
        {
            dir.Dispose();
        }
    }

    [Fact]
    public void OfflineVideoClipDoesNotShadowAnOverlappingValidClip()
    {
        // Regression for the video/audio previousEndFrame asymmetry (docs/timeline-snapshot-v1.md
        // §3): CompositionBuilder.insertVideoLane only advances previousEndFrame for a sequence
        // carrier or a successfully-inserted clip, so an offline clip must not "consume" its span
        // and shadow a later overlapping clip. EmitVideoLane must mirror that exactly.
        var offline = Clip("missing", start: 0, duration: 100, id: "OFFLINE");
        var valid = Clip("present", start: 50, duration: 100, id: "VALID"); // overlaps [0,100)
        var (project, manifestBase, dir) = SingleTrackProject(valid); // manifest only has "present"
        try
        {
            var track = project.Timelines[0].Tracks[0];
            track.Clips.Insert(0, offline);

            var result = TimelineSnapshotBuilder.Build(project, "TL-1", Resolver(manifestBase));

            var clips = result.Snapshot.Tracks.ShouldHaveSingleItem().Clips;
            clips.ShouldHaveSingleItem().Id.ShouldBe("VALID");
            result.OfflineMediaRefs.ShouldBe(["missing"]);
        }
        finally
        {
            dir.Dispose();
        }
    }

    [Fact]
    public void OfflineAudioClipDoesShadowAnOverlappingValidClip()
    {
        // Contrast with the video-lane behavior above: CompositionBuilder.insertAudioLane advances
        // previousEndFrame unconditionally (line 211 of CompositionBuilder.swift), so an offline
        // audio clip DOES consume its span and a later overlapping clip is dropped as "out of
        // order" — matching EmitAudioLane exactly. This pins the intentional asymmetry.
        var offline = Clip("missing", start: 0, duration: 100, id: "OFFLINE", type: ClipType.Audio);
        var valid = Clip("present", start: 50, duration: 100, id: "VALID", type: ClipType.Audio); // overlaps [0,100)
        var dir = new TempDirectory();
        try
        {
            var validPath = Path.Combine(dir.Path, "present.mp4");
            File.WriteAllBytes(validPath, []);
            var track = new Track(ClipType.Audio, [offline, valid]) { Id = "TRACK-1" };
            var timeline = new Timeline { Id = "TL-1", Fps = 30, Width = 1920, Height = 1080, Tracks = [track] };
            var project = new ProjectFile([timeline], timeline.Id, [timeline.Id]);
            var manifest = new MediaManifest
            {
                Entries = [new MediaManifestEntry("present", "present", ClipType.Audio, MediaSource.External(validPath), 10)],
            };

            var result = TimelineSnapshotBuilder.Build(project, "TL-1", Resolver(manifest));

            // The valid clip is shadowed: previousEndFrame was advanced to 100 by the offline clip
            // even though it was never resolved, so VALID's startFrame(50) < previousEndFrame(100).
            result.Snapshot.Tracks.ShouldBeEmpty();
            result.OfflineMediaRefs.ShouldBe(["missing"]);
        }
        finally
        {
            dir.Dispose();
        }
    }

    [Fact]
    public void MissingMediaFileOnDiskIsAlsoOffline()
    {
        // Manifest entry exists, but the file it points at does not — distinct failure mode from
        // "no manifest entry at all", both funnel into the same MediaResolver.ResolveUrl == null check.
        var dir = new TempDirectory();
        try
        {
            var clip = Clip("ghost", start: 0, duration: 30, id: "GHOST-CLIP");
            var track = new Track(ClipType.Video, [clip]) { Id = "T" };
            var timeline = new Timeline { Id = "TL-1", Fps = 30, Tracks = [track] };
            var project = new ProjectFile([timeline], timeline.Id, [timeline.Id]);
            var manifest = new MediaManifest
            {
                Entries = [new MediaManifestEntry("ghost", "ghost", ClipType.Video,
                    MediaSource.External(Path.Combine(dir.Path, "does-not-exist.mp4")), 10)],
            };

            var result = TimelineSnapshotBuilder.Build(project, "TL-1", Resolver(manifest));

            result.Snapshot.Tracks.ShouldBeEmpty();
            result.OfflineMediaRefs.ShouldBe(["ghost"]);
        }
        finally
        {
            dir.Dispose();
        }
    }

    // ----- 4. retimed clip carries speed + correct trims -----

    [Fact]
    public void RetimedClipCarriesSpeedAndTrims()
    {
        var clip = Clip("m", start: 0, duration: 20, id: "RETIMED", trimStart: 40, speed: 2.0);
        var (project, manifest, dir) = SingleTrackProject(clip);
        try
        {
            var result = TimelineSnapshotBuilder.Build(project, "TL-1", Resolver(manifest));

            var emitted = result.Snapshot.Tracks.ShouldHaveSingleItem().Clips.ShouldHaveSingleItem();
            emitted.Speed.ShouldBe(2.0);
            emitted.TrimStartFrame.ShouldBe(40);
            emitted.DurationFrames.ShouldBe(20); // timeline-frame duration, unaffected by speed (speed only changes source-frame consumption)
        }
        finally
        {
            dir.Dispose();
        }
    }

    // ----- Track ordering (§2) -----

    [Fact]
    public void TopLevelTrackZeroPaintsLastInOutput()
    {
        var dir = new TempDirectory();
        try
        {
            var topClip = Clip("top-media", 0, 30, id: "TOP-CLIP");
            var bottomClip = Clip("bottom-media", 0, 30, id: "BOTTOM-CLIP");
            var topTrack = new Track(ClipType.Video, [topClip]) { Id = "TOP" }; // index 0 = Swift-topmost
            var bottomTrack = new Track(ClipType.Video, [bottomClip]) { Id = "BOTTOM" };
            var timeline = new Timeline { Id = "TL-1", Fps = 30, Tracks = [topTrack, bottomTrack] };
            var project = new ProjectFile([timeline], timeline.Id, [timeline.Id]);
            var manifest = new MediaManifest
            {
                Entries =
                [
                    MakeEntry(dir)("top-media"),
                    MakeEntry(dir)("bottom-media"),
                ],
            };

            var result = TimelineSnapshotBuilder.Build(project, "TL-1", Resolver(manifest));

            // Output convention: index 0 paints first/bottom, LAST index paints last/top (§2) —
            // the reverse of Timeline.Tracks' own index-0-is-top convention.
            result.Snapshot.Tracks.Select(t => t.Id).ShouldBe(["BOTTOM", "TOP"]);
        }
        finally
        {
            dir.Dispose();
        }
    }

    // ----- Text/Lottie exclusion (§6) -----

    [Fact]
    public void TextAndLottieClipsAreExcluded()
    {
        var video = Clip("v", 0, 10, id: "V", type: ClipType.Video);
        var text = Clip("t", 10, 10, id: "T", type: ClipType.Text);
        var lottie = Clip("l", 20, 10, id: "L", type: ClipType.Lottie);
        var (project, manifest, dir) = SingleTrackProject(video, text, lottie);
        try
        {
            var result = TimelineSnapshotBuilder.Build(project, "TL-1", Resolver(manifest));

            var clips = result.Snapshot.Tracks.ShouldHaveSingleItem().Clips;
            clips.ShouldHaveSingleItem().Id.ShouldBe("V");
            // Neither excluded clip is a "media problem" — they're a known, tracked v1 gap, not a
            // missing/offline file.
            result.OfflineMediaRefs.ShouldBeEmpty();
        }
        finally
        {
            dir.Dispose();
        }
    }

    [Fact]
    public void TextAndLottieClipsAreExcludedInsideANestedSequenceToo()
    {
        // Regression: the filter must be applied by EmitVideoLane/EmitAudioLane themselves, not
        // only by their top-level caller — a clip list arriving via NestFlattener.Flatten never
        // passes through the top-level filtering path at all.
        var dir = new TempDirectory();
        try
        {
            var video = Clip("child-media", 0, 10, id: "CHILD-VIDEO", type: ClipType.Video);
            var text = Clip("n/a", 0, 10, id: "CHILD-TEXT", type: ClipType.Text);
            var childTrack = new Track(ClipType.Video, [video, text]) { Id = "CHILD-TRACK" };
            var child = new Timeline { Id = "CHILD", Fps = 30, Tracks = [childTrack] };

            var seqClip = new Clip("CHILD", 0, 10) { Id = "SEQ", MediaType = ClipType.Sequence, SourceClipType = ClipType.Sequence };
            var rootTrack = new Track(ClipType.Video, [seqClip]) { Id = "ROOT-TRACK" };
            var root = new Timeline { Id = "ROOT", Fps = 30, Tracks = [rootTrack] };

            var project = new ProjectFile([root, child], root.Id, [root.Id, child.Id]);
            var childMediaPath = Path.Combine(dir.Path, "child-media.mp4");
            File.WriteAllBytes(childMediaPath, []);
            var manifest = new MediaManifest
            {
                Entries = [new MediaManifestEntry("child-media", "child-media", ClipType.Video, MediaSource.External(childMediaPath), 10)],
            };

            var result = TimelineSnapshotBuilder.Build(project, "ROOT", Resolver(manifest));

            var clips = result.Snapshot.Tracks.ShouldHaveSingleItem().Clips;
            clips.ShouldHaveSingleItem().Id.ShouldBe("SEQ/CHILD-VIDEO");
            result.OfflineMediaRefs.ShouldBeEmpty(); // the excluded text clip must not be misreported as offline media
        }
        finally
        {
            dir.Dispose();
        }
    }

    // ----- Deterministic serialization -----

    [Fact]
    public void SameInputProducesByteIdenticalJsonAcrossMultipleBuilds()
    {
        var clip = Clip("m", 0, 30, id: "C", volume: 0.5);
        var (project, manifest, dir) = SingleTrackProject(clip);
        try
        {
            var first = TimelineSnapshotSerializer.ToJsonBytes(TimelineSnapshotBuilder.Build(project, "TL-1", Resolver(manifest)).Snapshot);
            var second = TimelineSnapshotSerializer.ToJsonBytes(TimelineSnapshotBuilder.Build(project, "TL-1", Resolver(manifest)).Snapshot);

            first.ShouldBe(second);
        }
        finally
        {
            dir.Dispose();
        }
    }

    // ----- Golden fixtures (docs/timeline-snapshot-v1.md §10) -----

    private static string FixturePath(string name) =>
        Path.Combine(AppContext.BaseDirectory, "Engine", "Fixtures", name);

    /// `fixtureDir` is substituted into a JSON *string value* — backslashes need the same escaping
    /// `Utf8JsonWriter` applies to `mediaPath` itself (`\` -> `\\`), or a Windows temp path like
    /// `C:\Users\...` corrupts the surrounding JSON escaping instead of just filling in the token.
    private static string LoadGolden(string name, string fixtureDir) =>
        File.ReadAllText(FixturePath(name)).Replace("{{FIXTURE_DIR}}", fixtureDir.Replace("\\", "\\\\"));

    private static string NormalizeLineEndings(string s) => s.Replace("\r\n", "\n");

    [Fact]
    public void GoldenFixture_SimpleTwoTrack_MatchesLiveBuilderOutput()
    {
        var dir = new TempDirectory();
        try
        {
            var clipAPath = Path.Combine(dir.Path, "clip-a.mp4");
            var audioAPath = Path.Combine(dir.Path, "audio-a.wav");
            File.WriteAllBytes(clipAPath, []);
            File.WriteAllBytes(audioAPath, []);

            var videoClip = new Clip("asset-video", 0, 90) { Id = "CLIP-VIDEO-1", MediaType = ClipType.Video, SourceClipType = ClipType.Video };
            var audioClip = new Clip("asset-audio", 0, 90)
            {
                Id = "CLIP-AUDIO-1", MediaType = ClipType.Audio, SourceClipType = ClipType.Audio,
                Volume = 0.8, FadeInFrames = 15, FadeOutFrames = 15,
                FadeInInterpolation = Interpolation.Smooth, FadeOutInterpolation = Interpolation.Linear,
            };
            var videoTrack = new Track(ClipType.Video, [videoClip]) { Id = "TRACK-VIDEO" };
            var audioTrack = new Track(ClipType.Audio, [audioClip]) { Id = "TRACK-AUDIO" };
            var timeline = new Timeline { Id = "TIMELINE-1", Fps = 30, Width = 1920, Height = 1080, Tracks = [videoTrack, audioTrack] };
            var project = new ProjectFile([timeline], timeline.Id, [timeline.Id]);
            var manifest = new MediaManifest
            {
                Entries =
                [
                    new MediaManifestEntry("asset-video", "asset-video", ClipType.Video, MediaSource.External(clipAPath), 10),
                    new MediaManifestEntry("asset-audio", "asset-audio", ClipType.Audio, MediaSource.External(audioAPath), 10),
                ],
            };

            var result = TimelineSnapshotBuilder.Build(project, "TIMELINE-1", Resolver(manifest));
            var actual = Encoding.UTF8.GetString(TimelineSnapshotSerializer.ToJsonBytes(result.Snapshot));
            var expected = LoadGolden("simple-two-track.snapshot.json", dir.Path);

            NormalizeLineEndings(actual).ShouldBe(NormalizeLineEndings(expected));
        }
        finally
        {
            dir.Dispose();
        }
    }

    [Fact]
    public void GoldenFixture_NestedSequence_MatchesLiveBuilderOutput()
    {
        var dir = new TempDirectory();
        try
        {
            var clipAPath = Path.Combine(dir.Path, "clip-a.mp4");
            var clipBPath = Path.Combine(dir.Path, "clip-b.mp4");
            File.WriteAllBytes(clipAPath, []);
            File.WriteAllBytes(clipBPath, []);

            var childA = new Clip("asset-child-a", 0, 100) { Id = "CHILD-CLIP-A", MediaType = ClipType.Video, SourceClipType = ClipType.Video };
            var childB = new Clip("asset-child-b", 0, 100) { Id = "CHILD-CLIP-B", MediaType = ClipType.Video, SourceClipType = ClipType.Video };
            var childTop = new Track(ClipType.Video, [childA]) { Id = "CHILD-TRACK-TOP" };
            var childBottom = new Track(ClipType.Video, [childB]) { Id = "CHILD-TRACK-BOTTOM" };
            var child = new Timeline { Id = "CHILD", Fps = 30, Width = 1920, Height = 1080, Tracks = [childTop, childBottom] };

            var seqClip = new Clip("CHILD", 10, 40)
            {
                Id = "CLIP-SEQ", MediaType = ClipType.Sequence, SourceClipType = ClipType.Sequence, TrimStartFrame = 5,
            };
            var rootTrack = new Track(ClipType.Video, [seqClip]) { Id = "TRACK-ROOT-VIDEO" };
            var root = new Timeline { Id = "ROOT", Fps = 30, Width = 1920, Height = 1080, Tracks = [rootTrack] };

            var project = new ProjectFile([root, child], root.Id, [root.Id, child.Id]);
            var manifest = new MediaManifest
            {
                Entries =
                [
                    new MediaManifestEntry("asset-child-a", "asset-child-a", ClipType.Video, MediaSource.External(clipAPath), 10),
                    new MediaManifestEntry("asset-child-b", "asset-child-b", ClipType.Video, MediaSource.External(clipBPath), 10),
                ],
            };

            var result = TimelineSnapshotBuilder.Build(project, "ROOT", Resolver(manifest));
            var actual = Encoding.UTF8.GetString(TimelineSnapshotSerializer.ToJsonBytes(result.Snapshot));
            var expected = LoadGolden("nested-sequence.snapshot.json", dir.Path);

            NormalizeLineEndings(actual).ShouldBe(NormalizeLineEndings(expected));
        }
        finally
        {
            dir.Dispose();
        }
    }

    [Fact]
    public void GoldenFixture_MissingMedia_MatchesLiveBuilderOutput()
    {
        var dir = new TempDirectory();
        try
        {
            var clipAPath = Path.Combine(dir.Path, "clip-a.mp4");
            File.WriteAllBytes(clipAPath, []);

            var presentClip = new Clip("asset-present", 0, 60) { Id = "CLIP-PRESENT", MediaType = ClipType.Video, SourceClipType = ClipType.Video };
            var missingClip = new Clip("asset-missing", 60, 30) { Id = "CLIP-MISSING", MediaType = ClipType.Video, SourceClipType = ClipType.Video };
            var track = new Track(ClipType.Video, [presentClip, missingClip]) { Id = "TRACK-VIDEO" };
            var timeline = new Timeline { Id = "TIMELINE-1", Fps = 30, Width = 1920, Height = 1080, Tracks = [track] };
            var project = new ProjectFile([timeline], timeline.Id, [timeline.Id]);
            var manifest = new MediaManifest
            {
                Entries = [new MediaManifestEntry("asset-present", "asset-present", ClipType.Video, MediaSource.External(clipAPath), 10)],
            };

            var result = TimelineSnapshotBuilder.Build(project, "TIMELINE-1", Resolver(manifest));
            var actual = Encoding.UTF8.GetString(TimelineSnapshotSerializer.ToJsonBytes(result.Snapshot));
            var expected = LoadGolden("missing-media.snapshot.json", dir.Path);

            NormalizeLineEndings(actual).ShouldBe(NormalizeLineEndings(expected));
            result.OfflineMediaRefs.ShouldBe(["asset-missing"]);
        }
        finally
        {
            dir.Dispose();
        }
    }

    // ----- Misc -----

    [Fact]
    public void UnknownTimelineIdThrows()
    {
        var project = new ProjectFile([new Timeline { Id = "TL-1" }]);
        Should.Throw<ArgumentException>(() => TimelineSnapshotBuilder.Build(project, "NOPE", Resolver(new MediaManifest())));
    }
}
