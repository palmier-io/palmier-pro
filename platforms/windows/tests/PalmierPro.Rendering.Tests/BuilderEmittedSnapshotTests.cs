using System.Drawing;
using PalmierPro.Core.Models;
using PalmierPro.Services.Engine;
using Shouldly;
using Xunit;

namespace PalmierPro.Rendering.Tests;

// Cross-project regression guard for the v1.1 emit path (docs/timeline-snapshot-v1.md §11).
// Every other native-facing test in this project (EffectKernelTests, TimelineCompositorTests, ...)
// feeds the native parser a checked-in, hand-authored JSON fixture under Fixtures/ — none of them
// exercise the real C# emitter (TimelineSnapshotBuilder + TimelineSnapshotSerializer, both in
// PalmierPro.Services.Tests' TimelineSnapshotBuilderTests) against the native parser at all. This
// closes that gap: build a snapshot the same way the app does (Clip -> TimelineSnapshotBuilder ->
// TimelineSnapshotSerializer), hand the resulting bytes straight to TimelineSession.Open with no
// fixture file in between, and confirm a keyframed effect param + populated opacity/crop/transform
// keyframe envelopes all survive the round trip and actually drive rendered pixels.
[Collection(MediaFixturesCollection.Name)]
public sealed class BuilderEmittedSnapshotTests(MediaFixtures fixtures)
{
    private static string RenderToTempPng(TimelineSession timeline, long frame)
    {
        string path = Path.Combine(Path.GetTempPath(), $"palmier-buildersnapshot-{Guid.NewGuid():N}.png");
        timeline.RenderFrameToFile(frame, path);
        return path;
    }

    [Fact]
    [Trait("Category", "Media")]
    public void BuilderEmittedSnapshot_WithEffectAndKeyframes_ParsesAndRendersDifferingFrames()
    {
        // color.blacksWhites (native/shaders/Levels.hlsl): out = saturate((rgb-bp)/max(0.05,wp-bp))
        // where bp=-blacks*0.4, wp=1-whites*0.4. blacks is static 0; "whites" is keyframed
        // -1 (frame 0) -> +1 (frame 45, linear) — a hand-computable, sizeable brightness swing on
        // the flat gray (0x808080, y=0.501961) fixture: frame 0 -> 0.501961/1.4=0.358544 (~91/255),
        // frame 45 -> 0.501961/0.6=0.836602 (~213/255). Opacity/crop/transform keyframes are also
        // populated (constant across both anchors — see TopLeftAt/TransformAt) purely to exercise
        // their wire shape through the builder -> serializer -> native parser chain without
        // perturbing this hand-computed pixel value.
        var clip = new Clip("gray", 0, 60)
        {
            Id = "CLIP-1", MediaType = ClipType.Video, SourceClipType = ClipType.Video,
            OpacityTrack = new KeyframeTrack<double>([
                new Keyframe<double>(0, 1.0, Interpolation.Linear),
                new Keyframe<double>(45, 1.0, Interpolation.Linear),
            ]),
            PositionTrack = new KeyframeTrack<AnimPair>([
                new Keyframe<AnimPair>(0, new AnimPair(0, 0), Interpolation.Linear),
                new Keyframe<AnimPair>(45, new AnimPair(0, 0), Interpolation.Linear),
            ]),
            CropTrack = new KeyframeTrack<Crop>([
                new Keyframe<Crop>(0, new Crop(), Interpolation.Linear),
                new Keyframe<Crop>(45, new Crop(), Interpolation.Linear),
            ]),
            Effects =
            [
                new Effect("color.blacksWhites")
                {
                    Params =
                    {
                        ["blacks"] = new EffectParam(value: 0.0),
                        ["whites"] = new EffectParam(track: new KeyframeTrack<double>([
                            new Keyframe<double>(0, -1.0, Interpolation.Linear),
                            new Keyframe<double>(45, 1.0, Interpolation.Linear),
                        ])),
                    },
                },
            ],
        };
        var track = new Track(ClipType.Video, [clip]) { Id = "TRACK-1" };
        var timeline = new Timeline
        {
            Id = "TL-1", Fps = MediaFixtures.VideoFps, Width = MediaFixtures.VideoWidth, Height = MediaFixtures.VideoHeight,
            Tracks = [track],
        };
        var project = new ProjectFile([timeline], timeline.Id, [timeline.Id]);
        var manifest = new MediaManifest
        {
            // Fully qualified: PalmierPro.Rendering.MediaSource (a different, IDisposable type)
            // is the nearer match from this file's enclosing PalmierPro.Rendering namespace.
            Entries = [new MediaManifestEntry("gray", "gray", ClipType.Video, PalmierPro.Core.Models.MediaSource.External(fixtures.GrayClipPath), duration: 60)],
        };
        var resolver = new MediaResolver(() => manifest, () => null);

        var result = TimelineSnapshotBuilder.Build(project, "TL-1", resolver);
        result.OfflineMediaRefs.ShouldBeEmpty();
        byte[] json = TimelineSnapshotSerializer.ToJsonBytes(result.Snapshot);

        using var session = new EngineSession();
        using TimelineSession nativeTimeline = TimelineSession.Open(session, json);

        string startPng = RenderToTempPng(nativeTimeline, frame: 0);
        string endPng = RenderToTempPng(nativeTimeline, frame: 45);
        try
        {
            using var startBmp = new Bitmap(startPng);
            using var endBmp = new Bitmap(endPng);
            Color start = startBmp.GetPixel(startBmp.Width / 2, startBmp.Height / 2);
            Color end = endBmp.GetPixel(endBmp.Width / 2, endBmp.Height / 2);

            Math.Abs(start.R - 91).ShouldBeLessThanOrEqualTo(6, $"frame 0 (whites=-1), got {start}");
            Math.Abs(end.R - 213).ShouldBeLessThanOrEqualTo(6, $"frame 45 (whites=+1), got {end}");
            ((int)end.R).ShouldBeGreaterThan(start.R + 50,
                $"builder-emitted keyframed effect param must visibly brighten the frame across time: start={start} end={end}");
        }
        finally
        {
            File.Delete(startPng);
            File.Delete(endPng);
        }
    }
}
