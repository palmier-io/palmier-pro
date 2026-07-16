using PalmierPro.Core.Json;
using PalmierPro.Core.Models;
using PalmierPro.Services.Engine;
using PalmierPro.Services.Media;
using PalmierPro.Services.Tests;
using Shouldly;
using Xunit;

namespace PalmierPro.Services.Tests.Engine;

/// docs/lottie-bake-v1.md §10 — pure-C# coverage of `TimelineSnapshotBuilder`'s Lottie branch
/// against a fake <see cref="ILottieBakeService"/> (no native call, no real bake). The real
/// end-to-end round trip (real bake -> real cache hit -> real native render, alpha respected) lives
/// in PalmierPro.Rendering.Tests/LottieCompositingEndToEndTests.cs, which needs the native engine.
public sealed class TimelineSnapshotBuilderLottieTests
{
    private static Clip LottieClip(string mediaRef = "lottie-1", int start = 0, int duration = 30) =>
        new(mediaRef, start, duration) { Id = SwiftId.New(), MediaType = ClipType.Lottie, SourceClipType = ClipType.Lottie };

    private static (ProjectFile Project, MediaResolver Resolver, TempDirectory Dir) SingleLottieTrackProject(Clip lottieClip)
    {
        var dir = new TempDirectory();
        var track = new Track(ClipType.Video, [lottieClip]) { Id = "TRACK-1" };
        var timeline = new Timeline { Id = "TL-1", Fps = 30, Width = 1920, Height = 1080, Tracks = [track] };
        var project = new ProjectFile([timeline], timeline.Id, [timeline.Id]);
        string sourcePath = Path.Combine(dir.Path, $"{lottieClip.MediaRef}.json");
        File.WriteAllText(sourcePath, "{}");
        var manifest = new MediaManifest
        {
            Entries = [new MediaManifestEntry(lottieClip.MediaRef, lottieClip.MediaRef, ClipType.Lottie, MediaSource.External(sourcePath), duration: 1)],
        };
        return (project, new MediaResolver(() => manifest, () => null), dir);
    }

    [Fact]
    public void NoLottieBakeServiceSupplied_ClipIsSkippedAndReportedAsPendingNeverOffline()
    {
        var clip = LottieClip();
        var (project, resolver, dir) = SingleLottieTrackProject(clip);
        try
        {
            var result = TimelineSnapshotBuilder.Build(project, "TL-1", resolver); // no 4th arg -> null service

            result.Snapshot.Tracks.ShouldBeEmpty();
            result.PendingLottieBakes.ShouldBe([clip.MediaRef]);
            result.OfflineMediaRefs.ShouldBeEmpty("a pending bake is a known, tracked gap, never a missing-file error — doc §10");
        }
        finally
        {
            dir.Dispose();
        }
    }

    [Fact]
    public void CacheMiss_KicksOffABakeAndReportsPending()
    {
        var clip = LottieClip();
        var (project, resolver, dir) = SingleLottieTrackProject(clip);
        try
        {
            var fake = new FakeLottieBakeService();

            var result = TimelineSnapshotBuilder.Build(project, "TL-1", resolver, fake);

            result.Snapshot.Tracks.ShouldBeEmpty();
            result.PendingLottieBakes.ShouldBe([clip.MediaRef]);
            result.OfflineMediaRefs.ShouldBeEmpty();
            fake.BakeRequests.ShouldHaveSingleItem().MediaRef.ShouldBe(clip.MediaRef);
        }
        finally
        {
            dir.Dispose();
        }
    }

    [Fact]
    public void CacheHit_EmitsAnOrdinaryVideoSnapshotClip_PointingAtTheCachedPath()
    {
        var clip = LottieClip();
        var (project, resolver, dir) = SingleLottieTrackProject(clip);
        try
        {
            var fake = new FakeLottieBakeService { CachedPath = @"C:\cache\lottie\abc123_1920x1080_v1.mov" };

            var result = TimelineSnapshotBuilder.Build(project, "TL-1", resolver, fake);

            result.PendingLottieBakes.ShouldBeEmpty();
            SnapshotClip snapshotClip = result.Snapshot.Tracks.ShouldHaveSingleItem().Clips.ShouldHaveSingleItem();
            snapshotClip.Type.ShouldBe(ClipType.Video, "downstream of a cache hit, nothing Lottie-specific is left — doc §10");
            snapshotClip.MediaPath.ShouldBe(fake.CachedPath);
            snapshotClip.Id.ShouldBe(clip.Id);
            fake.BakeRequests.ShouldBeEmpty("TryGetCachedPath never triggers a bake");
        }
        finally
        {
            dir.Dispose();
        }
    }

    [Fact]
    public void MissingSourceFile_GoesToOfflineMediaRefs_NotPending()
    {
        var dir = new TempDirectory();
        try
        {
            var clip = LottieClip(mediaRef: "missing-lottie");
            var track = new Track(ClipType.Video, [clip]) { Id = "TRACK-1" };
            var timeline = new Timeline { Id = "TL-1", Fps = 30, Width = 1920, Height = 1080, Tracks = [track] };
            var project = new ProjectFile([timeline], timeline.Id, [timeline.Id]);
            // No manifest entry at all -> MediaResolver.ResolveUrl returns null.
            var resolver = new MediaResolver(() => new MediaManifest(), () => null);
            var fake = new FakeLottieBakeService();

            var result = TimelineSnapshotBuilder.Build(project, "TL-1", resolver, fake);

            result.OfflineMediaRefs.ShouldBe(["missing-lottie"]);
            result.PendingLottieBakes.ShouldBeEmpty();
            fake.BakeRequests.ShouldBeEmpty();
        }
        finally
        {
            dir.Dispose();
        }
    }

    [Fact]
    public void TargetSize_UsesManifestSourceSizeWhenPopulated_ElseTimelineOutputSize()
    {
        var dir = new TempDirectory();
        try
        {
            var withSize = LottieClip(mediaRef: "sized-lottie", start: 0, duration: 30);
            var withoutSize = LottieClip(mediaRef: "unsized-lottie", start: 30, duration: 30);
            var track = new Track(ClipType.Video, [withSize, withoutSize]) { Id = "TRACK-1" };
            var timeline = new Timeline { Id = "TL-1", Fps = 30, Width = 1920, Height = 1080, Tracks = [track] };
            var project = new ProjectFile([timeline], timeline.Id, [timeline.Id]);
            string sizedPath = Path.Combine(dir.Path, "sized-lottie.json");
            string unsizedPath = Path.Combine(dir.Path, "unsized-lottie.json");
            File.WriteAllText(sizedPath, "{}");
            File.WriteAllText(unsizedPath, "{}");
            var manifest = new MediaManifest
            {
                Entries =
                [
                    new MediaManifestEntry("sized-lottie", "sized-lottie", ClipType.Lottie, MediaSource.External(sizedPath), duration: 1, sourceWidth: 200, sourceHeight: 150),
                    new MediaManifestEntry("unsized-lottie", "unsized-lottie", ClipType.Lottie, MediaSource.External(unsizedPath), duration: 1),
                ],
            };
            var resolver = new MediaResolver(() => manifest, () => null);
            var fake = new FakeLottieBakeService();

            TimelineSnapshotBuilder.Build(project, "TL-1", resolver, fake);

            fake.BakeRequests.Count.ShouldBe(2);
            fake.BakeRequests.Single(r => r.MediaRef == "sized-lottie").ShouldSatisfyAllConditions(
                r => r.Width.ShouldBe(200), r => r.Height.ShouldBe(150));
            fake.BakeRequests.Single(r => r.MediaRef == "unsized-lottie").ShouldSatisfyAllConditions(
                r => r.Width.ShouldBe(1920), r => r.Height.ShouldBe(1080));
        }
        finally
        {
            dir.Dispose();
        }
    }

    /// Deterministic, in-memory fake — no disk, no native call, records every request BakeAsync saw.
    private sealed class FakeLottieBakeService : ILottieBakeService
    {
        public string? CachedPath { get; set; }
        public List<LottieBakeRequest> BakeRequests { get; } = [];

        public event EventHandler<LottieBakeStatusChangedEventArgs>? StatusChanged;

        public string? TryGetCachedPath(LottieBakeRequest request) => CachedPath;

        public void BakeAsync(LottieBakeRequest request, CancellationToken ct = default)
        {
            BakeRequests.Add(request);
            StatusChanged?.Invoke(this, new LottieBakeStatusChangedEventArgs(request.MediaRef, request.Width, request.Height, LottieBakeStatus.InProgress, null, null));
        }

        public LottieBakeStatus StatusFor(string mediaRef, int width, int height) =>
            BakeRequests.Any(r => r.MediaRef == mediaRef) ? LottieBakeStatus.InProgress : LottieBakeStatus.NotStarted;
    }
}
