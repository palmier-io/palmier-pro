using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using PalmierPro.Core.Models;
using PalmierPro.Services.Engine;
using Shouldly;
using Xunit;

namespace PalmierPro.Rendering.Tests;

// Dedicated fixture for the E4.5 lip-sync slice (plan's E4.5 done bar: "lip-sync within ±1
// frame over 5 minutes") — no other slice needs beep/flash content, so this stays its own small
// generator (same pinned-ffmpeg-in-third_party/, generate-once-and-cache shape as
// MediaFixtures.cs) rather than growing that shared file — see AGENTS.md's per-slice file-
// ownership rule.
//
// Video: solid black, 30 fps, 5 minutes, with a single all-white frame every 10 s (frame index
// a multiple of 300) via geq's per-frame `N` formula — an exact integer-frame condition, no
// float-time rounding anywhere near the marker.
// Audio: silence, 48 kHz, with a 10 ms sine beep starting at the same instant. Synthesized
// per-sample via aevalsrc's own `t` rather than gating a continuous tone with a filter's
// `enable=` expression — that route was tried first and rejected: `volume`'s enable is only
// evaluated once per ~1024-sample internal block, which smears/offsets a 10 ms window by up to
// a whole block. aevalsrc has no such block quantization, so the onset lands on the exact
// sample.
public sealed class AvSyncFixture
{
    public const int Fps = 30;
    public const int Width = 320;
    public const int Height = 180;
    public const int MixRate = 48000;
    public const int DurationSeconds = 300; // 5 min
    public const int MarkerIntervalSeconds = 10;
    public const double BeepDurationSeconds = 0.01; // 10 ms
    private const double BeepFrequencyHz = 1000;
    private const double BeepAmplitude = 0.5;

    public const int TotalFrames = DurationSeconds * Fps; // 9000
    public const int MarkerCount = DurationSeconds / MarkerIntervalSeconds; // 30
    private const int FlashPeriodFrames = MarkerIntervalSeconds * Fps; // 300

    public string FixturePath { get; }

    public AvSyncFixture()
    {
        string fixturesDir = Path.Combine(AppContext.BaseDirectory, "fixtures");
        Directory.CreateDirectory(fixturesDir);
        FixturePath = Path.Combine(fixturesDir, "avsync_flash_beep_5min.mp4");
        Ensure(FixturePath);
    }

    /// The timeline frame (30 fps) marker `markerIndex` (0-based) falls on.
    public static long MarkerFrame(int markerIndex) => (long)markerIndex * MarkerIntervalSeconds * Fps;

    private static void Ensure(string path)
    {
        if (File.Exists(path) && new FileInfo(path).Length > 0)
        {
            return;
        }
        static string Inv(double d) => d.ToString(CultureInfo.InvariantCulture);
        Run(
            "-y " +
            $"-f lavfi -i \"color=c=black:s={Width}x{Height}:r={Fps}:d={DurationSeconds}," +
            $"geq=lum='if(eq(mod(N\\,{FlashPeriodFrames})\\,0)\\,255\\,0)':cb=128:cr=128\" " +
            "-f lavfi -i \"aevalsrc=exprs='if(lt(mod(t\\," +
            $"{MarkerIntervalSeconds})\\,{Inv(BeepDurationSeconds)})\\,sin(2*PI*{Inv(BeepFrequencyHz)}*t)*{Inv(BeepAmplitude)}\\,0)'" +
            $":s={MixRate}:d={DurationSeconds}\" " +
            "-c:v libx264 -pix_fmt yuv420p -c:a aac -shortest " +
            $"\"{path}\"");
    }

    private static string ResolveFfmpegExe()
    {
        string? dir = AppContext.BaseDirectory;
        while (dir is not null)
        {
            string candidate = Path.Combine(dir, "third_party", "ffmpeg", "bin", "ffmpeg.exe");
            if (File.Exists(candidate))
            {
                return candidate;
            }
            dir = Path.GetDirectoryName(dir);
        }
        throw new FileNotFoundException(
            "Could not find third_party/ffmpeg/bin/ffmpeg.exe above the test output directory. " +
            "Run platforms/windows/scripts/ci-restore-ffmpeg.ps1 first.");
    }

    private static void Run(string arguments)
    {
        var psi = new ProcessStartInfo(ResolveFfmpegExe(), arguments)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        using Process process = Process.Start(psi) ?? throw new InvalidOperationException("failed to start ffmpeg.exe");
        string stderr = process.StandardError.ReadToEnd();
        process.WaitForExit();
        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException($"ffmpeg fixture generation failed (exit {process.ExitCode}):\n{stderr}");
        }
    }
}

[CollectionDefinition(Name)]
public sealed class AvSyncFixtureCollection : ICollectionFixture<AvSyncFixture>
{
    public const string Name = "AV sync fixture";
}

// E4.5 lip-sync slice (docs/audio-playback-v1.md; plan's E4.5 done bar: "lip-sync within ±1
// frame over 5 minutes; audible frame-step and scrub"). Frame-step/scrub audibility is the
// preview-transport slice's concern and ScrubAudioGrainTests already covers the scrub-audio grab
// itself (docs §5) — not duplicated here.
//
// Cross-checks the two independent golden hooks against each other: PE_TimelineRenderFrameToFile
// (video decode/composite) and PE_TimelineRenderAudioRange (audio decode/mix) each read the same
// underlying beep+flash file through separate code paths, so if either one's frame<->sample math
// ever drifts, the flash frame index and the beep's sample offset stop agreeing — that
// disagreement is exactly what this test measures, at each of the 30 ten-second markers across
// the full 5 minutes (sampling markers, not every one of the timeline's 9000 frames, per the
// plan's runtime-sanity note).
[Collection(AvSyncFixtureCollection.Name)]
public sealed class AvSyncTests(AvSyncFixture fixture)
{
    private const int Fps = AvSyncFixture.Fps;
    private const int MixRate = AvSyncFixture.MixRate;
    private const int SamplesPerFrame = MixRate / Fps; // 1600 — exact, 30 divides 48 kHz evenly

    // Frame-domain search radius around each marker's expected flash frame — wide enough to
    // catch a real multi-frame regression, narrow enough that this stays a handful of
    // PE_TimelineRenderFrameToFile calls per marker instead of scanning the whole timeline.
    private const int VideoSearchRadiusFrames = 2;
    // Same idea on the audio side, expressed in whole timeline frames so it lines up with
    // PE_TimelineRenderAudioRange's frame-domain startFrame parameter.
    private const int AudioSearchRadiusFrames = 3;

    private const double ToleranceFrames = 1.0; // plan's done-bar: lip-sync within ±1 frame
    private const double AudioOnsetThreshold = 0.02; // background is true digital silence (0.0)

    private TimelineSession OpenFlashBeep(EngineSession session, bool includeVideoTrack)
    {
        var tracks = new List<Track>();
        var entries = new List<MediaManifestEntry>();

        if (includeVideoTrack)
        {
            var videoClip = new Clip("flashbeep-video", startFrame: 0, durationFrames: AvSyncFixture.TotalFrames)
            {
                Id = "CLIP-VIDEO",
                MediaType = ClipType.Video,
                SourceClipType = ClipType.Video,
            };
            tracks.Add(new Track(ClipType.Video, [videoClip]) { Id = "TRACK-VIDEO" });
            entries.Add(new MediaManifestEntry("flashbeep-video", "flashbeep-video", ClipType.Video,
                PalmierPro.Core.Models.MediaSource.External(fixture.FixturePath), duration: AvSyncFixture.TotalFrames));
        }

        var audioClip = new Clip("flashbeep-audio", startFrame: 0, durationFrames: AvSyncFixture.TotalFrames)
        {
            Id = "CLIP-AUDIO",
            MediaType = ClipType.Audio,
            SourceClipType = ClipType.Audio,
            Volume = 1.0,
        };
        tracks.Add(new Track(ClipType.Audio, [audioClip]) { Id = "TRACK-AUDIO" });
        entries.Add(new MediaManifestEntry("flashbeep-audio", "flashbeep-audio", ClipType.Audio,
            PalmierPro.Core.Models.MediaSource.External(fixture.FixturePath), duration: AvSyncFixture.TotalFrames));

        var timeline = new Timeline
        {
            Id = "TL-AVSYNC", Fps = Fps, Width = AvSyncFixture.Width, Height = AvSyncFixture.Height,
            Tracks = tracks,
        };
        var project = new ProjectFile([timeline], timeline.Id, [timeline.Id]);
        var manifest = new MediaManifest { Entries = entries };
        var resolver = new MediaResolver(() => manifest, () => null);

        var result = TimelineSnapshotBuilder.Build(project, "TL-AVSYNC", resolver);
        result.OfflineMediaRefs.ShouldBeEmpty();
        byte[] json = TimelineSnapshotSerializer.ToJsonBytes(result.Snapshot);
        return TimelineSession.Open(session, json);
    }

    // Sampled-grid average brightness — the fixture's flash frames are solid white, everything
    // else solid black, so a coarse grid is exact, not an approximation.
    private static bool FrameIsBright(string pngPath)
    {
        using var bitmap = new Bitmap(pngPath);
        long sum = 0;
        int count = 0;
        for (int y = 0; y < bitmap.Height; y += 11)
        {
            for (int x = 0; x < bitmap.Width; x += 11)
            {
                Color p = bitmap.GetPixel(x, y);
                sum += p.R + p.G + p.B;
                count += 3;
            }
        }
        return sum / (double)count > 128.0;
    }

    /// First sample-frame index in `interleaved` (stereo, sample-frame units) whose magnitude
    /// clears the beep-vs-silence threshold, or null if the whole window is silent.
    private static int? FindOnsetSample(float[] interleaved, double threshold)
    {
        int sampleCount = interleaved.Length / 2;
        for (int i = 0; i < sampleCount; i++)
        {
            if (Math.Abs(interleaved[i * 2]) > threshold || Math.Abs(interleaved[i * 2 + 1]) > threshold)
            {
                return i;
            }
        }
        return null;
    }

    [Fact]
    [Trait("Category", "Media")]
    public void FlashFrameAndBeepSample_AgreeWithinOneFrame_AcrossAllMarkers()
    {
        using var session = new EngineSession();
        using TimelineSession timeline = OpenFlashBeep(session, includeVideoTrack: true);

        string pngPath = Path.Combine(Path.GetTempPath(), $"palmier-avsync-{Guid.NewGuid():N}.png");
        try
        {
            for (int marker = 0; marker < AvSyncFixture.MarkerCount; marker++)
            {
                long expectedFrame = AvSyncFixture.MarkerFrame(marker);

                // Video side: find the single bright (flash) frame near the marker.
                long videoLo = Math.Max(0, expectedFrame - VideoSearchRadiusFrames);
                long videoHi = expectedFrame + VideoSearchRadiusFrames;
                var brightFrames = new List<long>();
                for (long f = videoLo; f <= videoHi; f++)
                {
                    timeline.RenderFrameToFile(f, pngPath);
                    if (FrameIsBright(pngPath))
                    {
                        brightFrames.Add(f);
                    }
                }
                brightFrames.ShouldHaveSingleItem(
                    $"marker {marker}: expected exactly one flash frame within ±{VideoSearchRadiusFrames} of timeline frame {expectedFrame}");
                long flashFrame = brightFrames[0];

                // Audio side: find the beep's onset sample near the same marker.
                long audioLoFrame = Math.Max(0, expectedFrame - AudioSearchRadiusFrames);
                long audioHiFrameExclusive = expectedFrame + AudioSearchRadiusFrames + 1;
                int audioWindowSamples = (int)(audioHiFrameExclusive - audioLoFrame) * SamplesPerFrame;
                float[] audio = timeline.RenderAudioRange(audioLoFrame, audioWindowSamples);
                int? onset = FindOnsetSample(audio, AudioOnsetThreshold);
                onset.ShouldNotBeNull(
                    $"marker {marker}: expected an audible beep within ±{AudioSearchRadiusFrames} frames of timeline frame {expectedFrame}");
                double beepFrameEquivalent = audioLoFrame + onset!.Value / (double)SamplesPerFrame;

                // The two independent pipelines must agree within ±1 frame (plan's done bar).
                double diff = Math.Abs(flashFrame - beepFrameEquivalent);
                diff.ShouldBeLessThanOrEqualTo(ToleranceFrames,
                    $"marker {marker}: flash frame {flashFrame} vs beep-equivalent frame {beepFrameEquivalent:F3}");
            }
        }
        finally
        {
            File.Delete(pngPath);
        }
    }

    [Fact]
    [Trait("Category", "Media")]
    public void ClockFrame_IsMonotonicNonDecreasing_DuringSimulatedPlay()
    {
        using var session = new EngineSession();
        // Audio-only, same rationale as TimelinePlaybackTests: this is a clock-progression
        // property, not a video-decode test, and headless playback with an attached video track
        // is outside this slice — keeping this off that path avoids a spurious dependency on it.
        using TimelineSession timeline = OpenFlashBeep(session, includeVideoTrack: false);

        timeline.GetClockFrame().ShouldBe(0L);
        timeline.Play();
        try
        {
            var samples = new List<long> { timeline.GetClockFrame() };
            var rng = new Random(1234567); // fixed seed: reproducible poll cadence, not timing
            for (int i = 0; i < 15; i++)
            {
                Thread.Sleep(20 + rng.Next(60));
                samples.Add(timeline.GetClockFrame());
            }

            // The property: for every pair of samples taken in order, the clock never runs
            // backwards — true regardless of exactly how much wall time elapsed between polls.
            for (int i = 1; i < samples.Count; i++)
            {
                samples[i].ShouldBeGreaterThanOrEqualTo(samples[i - 1],
                    $"clock frame regressed between poll {i - 1} ({samples[i - 1]}) and poll {i} ({samples[i]})");
            }
            samples[^1].ShouldBeGreaterThan(samples[0], "playback never advanced the clock at all");
            // This test only samples a short slice of the 5-minute fixture and deliberately never
            // plays to completion (keeps runtime sane) — nowhere near the duration boundary.
            samples[^1].ShouldBeLessThan((long)AvSyncFixture.TotalFrames);
        }
        finally
        {
            timeline.Pause();
        }
    }
}
