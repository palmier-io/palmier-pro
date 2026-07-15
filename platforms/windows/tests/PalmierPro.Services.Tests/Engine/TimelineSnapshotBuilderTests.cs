using System.Text;
using System.Text.Json;
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

    // ----- Lottie exclusion (§6) — text clips now enter `SnapshotTrack.TextClips` instead of being
    // excluded; see the "Text clips (§12)" section below. -----

    [Fact]
    public void LottieClipIsExcluded()
    {
        var video = Clip("v", 0, 10, id: "V", type: ClipType.Video);
        var lottie = Clip("l", 20, 10, id: "L", type: ClipType.Lottie);
        var (project, manifest, dir) = SingleTrackProject(video, lottie);
        try
        {
            var result = TimelineSnapshotBuilder.Build(project, "TL-1", Resolver(manifest));

            var clips = result.Snapshot.Tracks.ShouldHaveSingleItem().Clips;
            clips.ShouldHaveSingleItem().Id.ShouldBe("V");
            // Not a "media problem" — a known, tracked v1/v1.1 gap, not a missing/offline file.
            result.OfflineMediaRefs.ShouldBeEmpty();
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

    [Fact]
    public void EffectParamsSerializeInOrdinalKeyOrder_RegardlessOfInsertionOrder()
    {
        // §9's determinism guarantee for `effects[].params` rests entirely on WriteEffect's
        // explicit `.OrderBy(kv => kv.Key, StringComparer.Ordinal)` — Dictionary<K,V> enumeration
        // order isn't a stable .NET contract. The golden fixture's own params ("blacks", "whites")
        // happen to already be alphabetical in insertion order, so it can't catch a regression
        // here; insert deliberately out of order.
        var clip = Clip("m", 0, 30, id: "C");
        clip.Effects =
        [
            new Effect("test.effect")
            {
                Params =
                {
                    ["zeta"] = new EffectParam(1.0),
                    ["alpha"] = new EffectParam(2.0),
                    ["mid"] = new EffectParam(3.0),
                },
            },
        ];
        var (project, manifest, dir) = SingleTrackProject(clip);
        try
        {
            string json = Encoding.UTF8.GetString(TimelineSnapshotSerializer.ToJsonBytes(
                TimelineSnapshotBuilder.Build(project, "TL-1", Resolver(manifest)).Snapshot));

            int alpha = json.IndexOf("\"alpha\"", StringComparison.Ordinal);
            int mid = json.IndexOf("\"mid\"", StringComparison.Ordinal);
            int zeta = json.IndexOf("\"zeta\"", StringComparison.Ordinal);
            alpha.ShouldBeGreaterThan(-1);
            mid.ShouldBeGreaterThan(alpha);
            zeta.ShouldBeGreaterThan(mid);
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

    [Fact]
    public void GoldenFixture_EffectsAndKeyframes_MatchesLiveBuilderOutput()
    {
        // v1.1 emit path (docs/timeline-snapshot-v1.md §11): populated opacity/crop/transform
        // keyframe envelopes plus a per-clip effect with one static and one keyframed param. No
        // other test in this file exercises BuildKeyframes/BuildTransformKeyframes/ToSnapshotEffect
        // via the live builder — every other fixture/test above uses all-static clips with no effects.
        var dir = new TempDirectory();
        try
        {
            var clipAPath = Path.Combine(dir.Path, "clip-a.mp4");
            File.WriteAllBytes(clipAPath, []);

            var clip = new Clip("asset-video", 0, 60)
            {
                Id = "CLIP-1", MediaType = ClipType.Video, SourceClipType = ClipType.Video,
                OpacityTrack = new KeyframeTrack<double>([
                    new Keyframe<double>(0, 0.2, Interpolation.Hold),
                    new Keyframe<double>(30, 1.0, Interpolation.Linear),
                ]),
                // Constant (0,0) at both anchors -> TopLeftAt/TransformAt resolve to the same
                // default full-canvas transform at every sampled frame (see Clip.TopLeftAt/
                // TransformAt) while still emitting a real, populated 2-entry keyframe envelope.
                PositionTrack = new KeyframeTrack<AnimPair>([
                    new Keyframe<AnimPair>(0, new AnimPair(0, 0), Interpolation.Linear),
                    new Keyframe<AnimPair>(30, new AnimPair(0, 0), Interpolation.Smooth),
                ]),
                CropTrack = new KeyframeTrack<Crop>([
                    new Keyframe<Crop>(0, new Crop(), Interpolation.Linear),
                    new Keyframe<Crop>(30, new Crop { Left = 0.1, Top = 0.05, Right = 0.1, Bottom = 0.05 }, Interpolation.Hold),
                ]),
                Effects =
                [
                    new Effect("color.blacksWhites")
                    {
                        Params =
                        {
                            ["blacks"] = new EffectParam(value: 0.1),
                            ["whites"] = new EffectParam(track: new KeyframeTrack<double>([
                                new Keyframe<double>(0, -0.3, Interpolation.Hold),
                                new Keyframe<double>(60, 0.4, Interpolation.Linear),
                            ])),
                        },
                    },
                ],
            };
            var track = new Track(ClipType.Video, [clip]) { Id = "TRACK-VIDEO" };
            var timeline = new Timeline { Id = "TIMELINE-1", Fps = 30, Width = 1920, Height = 1080, Tracks = [track] };
            var project = new ProjectFile([timeline], timeline.Id, [timeline.Id]);
            var manifest = new MediaManifest
            {
                Entries = [new MediaManifestEntry("asset-video", "asset-video", ClipType.Video, MediaSource.External(clipAPath), 10)],
            };

            var result = TimelineSnapshotBuilder.Build(project, "TIMELINE-1", Resolver(manifest));
            var actual = Encoding.UTF8.GetString(TimelineSnapshotSerializer.ToJsonBytes(result.Snapshot));
            var expected = LoadGolden("effects-and-keyframes.snapshot.json", dir.Path);

            NormalizeLineEndings(actual).ShouldBe(NormalizeLineEndings(expected));
        }
        finally
        {
            dir.Dispose();
        }
    }

    // ----- Text clips (§12) -----

    private static readonly string SampleTextStyleJson = """
        {
          "fontName": "Avenir Next Bold",
          "fontSize": 72,
          "fontScale": 1.0,
          "isBold": true,
          "isItalic": false,
          "color": { "r": 1, "g": 1, "b": 1, "a": 1 },
          "alignment": "center",
          "shadow": { "enabled": true, "color": { "r": 0, "g": 0, "b": 0, "a": 0.6 }, "offsetX": 0, "offsetY": -2, "blur": 6 },
          "background": { "enabled": false, "color": { "r": 0, "g": 0, "b": 0, "a": 0.6 } },
          "border": { "enabled": true, "color": { "r": 0, "g": 0, "b": 0, "a": 1 } }
        }
        """;

    private static readonly string SampleTextAnimationJson = """
        {
          "preset": "wordReveal",
          "perWordFrames": 6,
          "highlight": { "r": 1, "g": 0.85, "b": 0, "a": 1 }
        }
        """;

    /// A representative `.text` clip: overridden style/animation (raw JSON, matching how
    /// `Clip.TextStyle`/`TextAnimation` are actually stored — see Timeline.cs), word timings, and a
    /// keyframed opacity envelope (the one property TextFrameRenderer DOES sample per-frame for text).
    private static Clip TextClip(string mediaRef, int start, int duration, string id) => new(mediaRef, start, duration)
    {
        Id = id,
        MediaType = ClipType.Text,
        SourceClipType = ClipType.Text,
        TextContent = "Hello world",
        Transform = new Transform { CenterX = 0.5, CenterY = 0.9, Width = 0.8, Height = 0.2 },
        TextStyle = JsonDocument.Parse(SampleTextStyleJson).RootElement.Clone(),
        TextAnimation = JsonDocument.Parse(SampleTextAnimationJson).RootElement.Clone(),
        WordTimings = [new WordTiming("Hello", 0, 20), new WordTiming("world", 20, 40)],
        OpacityTrack = new KeyframeTrack<double>([
            new Keyframe<double>(0, 0, Interpolation.Linear),
            new Keyframe<double>(10, 1, Interpolation.Linear),
        ]),
    };

    [Fact]
    public void TextClipEntersItsOwnTracksTextClipsListLottieStaysExcluded()
    {
        var video = Clip("v", 0, 10, id: "V", type: ClipType.Video);
        var text = TextClip("", 10, 10, id: "T");
        var lottie = Clip("l", 20, 10, id: "L", type: ClipType.Lottie);
        var (project, manifest, dir) = SingleTrackProject(video, text, lottie);
        try
        {
            var result = TimelineSnapshotBuilder.Build(project, "TL-1", Resolver(manifest));

            var track = result.Snapshot.Tracks.ShouldHaveSingleItem();
            track.Clips.ShouldHaveSingleItem().Id.ShouldBe("V"); // Lottie stays a silent v1/v1.1 gap
            var textClip = track.TextClips.ShouldHaveSingleItem();
            textClip.Id.ShouldBe("T");
            textClip.Content.ShouldBe("Hello world");
            textClip.Style.FontName.ShouldBe("Avenir Next Bold");
            textClip.Animation.Preset.ShouldBe(TextAnimationPreset.WordReveal);
            textClip.WordTimings.ShouldNotBeNull().Count.ShouldBe(2);
            result.OfflineMediaRefs.ShouldBeEmpty(); // neither exclusion is a "media problem"
        }
        finally
        {
            dir.Dispose();
        }
    }

    [Fact]
    public void TextClipInsideANestedSequenceEntersTextClipsListWithRemappedFrames()
    {
        // Regression: the Text/Lottie branch must be evaluated by EmitVideoLane itself, not only by
        // its top-level caller — a clip list arriving via NestFlattener.Flatten never passes through
        // a separate top-level filtering path at all.
        var dir = new TempDirectory();
        try
        {
            var video = Clip("child-media", 0, 10, id: "CHILD-VIDEO", type: ClipType.Video);
            var text = TextClip("", 0, 10, id: "CHILD-TEXT");
            var childTrack = new Track(ClipType.Video, [video, text]) { Id = "CHILD-TRACK" };
            var child = new Timeline { Id = "CHILD", Fps = 30, Tracks = [childTrack] };

            var seqClip = new Clip("CHILD", 5, 10) { Id = "SEQ", MediaType = ClipType.Sequence, SourceClipType = ClipType.Sequence };
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

            var track = result.Snapshot.Tracks.ShouldHaveSingleItem();
            track.Clips.ShouldHaveSingleItem().Id.ShouldBe("SEQ/CHILD-VIDEO");
            // Nest-prefixed id (§4's convention), same as a video/audio SnapshotClip; the carrier
            // starts at 5 with no trim, so the shift is +5 (matches RetimedClipCarriesSpeedAndTrims-
            // style remap math: shift = seqClip.StartFrame - seqClip.TrimStartFrame).
            var textClip = track.TextClips.ShouldHaveSingleItem();
            textClip.Id.ShouldBe("SEQ/CHILD-TEXT");
            textClip.StartFrame.ShouldBe(5);
            result.OfflineMediaRefs.ShouldBeEmpty();
        }
        finally
        {
            dir.Dispose();
        }
    }

    [Fact]
    public void TextClipDoesNotConsumeOrRespectPreviousEndFrame()
    {
        // A text clip is exempt from the video-lane overlap invariant in both directions: it never
        // advances previousEndFrame (so it can't shadow a later regular clip), and it's never itself
        // rejected as "out of order" for overlapping one (matches CompositionBuilder's `.text`
        // branch, which has no prevEndFrame interaction at all).
        var video = Clip("v", 0, 100, id: "V", type: ClipType.Video);
        var text = TextClip("", 10, 20, id: "T"); // fully inside the video clip's span
        var (project, manifest, dir) = SingleTrackProject(video, text);
        try
        {
            var result = TimelineSnapshotBuilder.Build(project, "TL-1", Resolver(manifest));

            var track = result.Snapshot.Tracks.ShouldHaveSingleItem();
            track.Clips.ShouldHaveSingleItem().Id.ShouldBe("V");
            track.TextClips.ShouldHaveSingleItem().Id.ShouldBe("T");
        }
        finally
        {
            dir.Dispose();
        }
    }

    [Fact]
    public void EmptyContentTextClipIsDropped()
    {
        // Matches CompositionBuilder's `guard !(clip.textContent ?? "").isEmpty else { continue }`.
        var empty = TextClip("", 0, 10, id: "EMPTY");
        empty.TextContent = "";
        var (project, manifest, dir) = SingleTrackProject(empty);
        try
        {
            var result = TimelineSnapshotBuilder.Build(project, "TL-1", Resolver(manifest));

            result.Snapshot.Tracks.ShouldBeEmpty();
        }
        finally
        {
            dir.Dispose();
        }
    }

    [Fact]
    public void GoldenFixture_TextClip_MatchesLiveBuilderOutput()
    {
        var dir = new TempDirectory();
        try
        {
            var clipAPath = Path.Combine(dir.Path, "clip-a.mp4");
            File.WriteAllBytes(clipAPath, []);

            var videoClip = new Clip("asset-video", 0, 90) { Id = "CLIP-VIDEO-1", MediaType = ClipType.Video, SourceClipType = ClipType.Video };
            var videoTrack = new Track(ClipType.Video, [videoClip]) { Id = "TRACK-VIDEO" };
            var textClip = TextClip("", 15, 60, id: "TEXT-CLIP-1");
            var textTrack = new Track(ClipType.Video, [textClip]) { Id = "TRACK-TEXT" };

            // TRACK-TEXT is index 0 (Swift-topmost) so the golden output demonstrates the common
            // case — a caption track painting over the video track beneath it (§2).
            var timeline = new Timeline { Id = "TIMELINE-1", Fps = 30, Width = 1920, Height = 1080, Tracks = [textTrack, videoTrack] };
            var project = new ProjectFile([timeline], timeline.Id, [timeline.Id]);
            var manifest = new MediaManifest
            {
                Entries = [new MediaManifestEntry("asset-video", "asset-video", ClipType.Video, MediaSource.External(clipAPath), 10)],
            };

            var result = TimelineSnapshotBuilder.Build(project, "TIMELINE-1", Resolver(manifest));
            var actual = Encoding.UTF8.GetString(TimelineSnapshotSerializer.ToJsonBytes(result.Snapshot));
            var expected = LoadGolden("text-clip.snapshot.json", dir.Path);

            NormalizeLineEndings(actual).ShouldBe(NormalizeLineEndings(expected));
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
