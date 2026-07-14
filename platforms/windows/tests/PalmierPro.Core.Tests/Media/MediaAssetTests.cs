using PalmierPro.Core.Models;
using Shouldly;
using Xunit;

namespace PalmierPro.Core.Tests;

public class MediaAssetTests
{
    // MARK: - GenerationStatus serialization

    [Theory]
    [InlineData("preparing", GenerationStatusKind.Preparing)]
    [InlineData("generating", GenerationStatusKind.Generating)]
    [InlineData("downloading", GenerationStatusKind.Downloading)]
    [InlineData("rendering", GenerationStatusKind.Rendering)]
    public void FromSerializedParsesKnownValues(string raw, GenerationStatusKind expected)
    {
        GenerationStatus.FromSerialized(raw).Kind.ShouldBe(expected);
    }

    [Fact]
    public void FromSerializedParsesFailedWithMessage()
    {
        var status = GenerationStatus.FromSerialized("failed: quota exceeded");
        status.Kind.ShouldBe(GenerationStatusKind.Failed);
        status.FailureMessage.ShouldBe("quota exceeded");
    }

    [Fact]
    public void FromSerializedFallsBackToNoneForUnknownOrNull()
    {
        GenerationStatus.FromSerialized(null).ShouldBe(GenerationStatus.None);
        GenerationStatus.FromSerialized("bogus").ShouldBe(GenerationStatus.None);
    }

    [Fact]
    public void SerializedRoundTripsThroughFromSerialized()
    {
        var status = GenerationStatus.Failed("boom");
        GenerationStatus.FromSerialized(status.Serialized).ShouldBe(status);
    }

    [Fact]
    public void ManifestValueHidesTransientStatuses()
    {
        GenerationStatus.None.ManifestValue.ShouldBeNull();
        GenerationStatus.Preparing.ManifestValue.ShouldBeNull();
        GenerationStatus.Generating.ManifestValue.ShouldBe("generating");
        GenerationStatus.Failed("x").ManifestValue.ShouldBe("failed: x");
    }

    // MARK: - FreshRemoteUrl

    [Fact]
    public void FreshRemoteUrlNullWhenExpired()
    {
        var asset = new MediaAsset("https://cdn/x", ClipType.Video, "X")
        {
            CachedRemoteUrl = "https://cdn/x",
            CachedRemoteUrlExpiresAt = DateTimeOffset.UtcNow.AddMinutes(-1),
        };
        asset.FreshRemoteUrl.ShouldBeNull();
    }

    [Fact]
    public void FreshRemoteUrlReturnsUrlWhenNotExpired()
    {
        var asset = new MediaAsset("https://cdn/x", ClipType.Video, "X")
        {
            CachedRemoteUrl = "https://cdn/x",
            CachedRemoteUrlExpiresAt = DateTimeOffset.UtcNow.AddMinutes(5),
        };
        asset.FreshRemoteUrl.ShouldBe("https://cdn/x");
    }

    [Fact]
    public void FreshRemoteUrlNullWhenNeverSet()
    {
        new MediaAsset("https://cdn/x", ClipType.Video, "X").FreshRemoteUrl.ShouldBeNull();
    }

    // MARK: - Generation-state predicates

    [Fact]
    public void CanResumeGenerationRequiresNonEmptyBackendJobId()
    {
        var noInput = new MediaAsset("u", ClipType.Video, "X");
        noInput.CanResumeGeneration.ShouldBeFalse();

        var emptyJobId = new MediaAsset("u", ClipType.Video, "X") { GenerationInput = new GenerationInput { Prompt = "p", Model = "m", AspectRatio = "16:9", BackendJobId = "" } };
        emptyJobId.CanResumeGeneration.ShouldBeFalse();

        var withJobId = new MediaAsset("u", ClipType.Video, "X") { GenerationInput = new GenerationInput { Prompt = "p", Model = "m", AspectRatio = "16:9", BackendJobId = "job-1" } };
        withJobId.CanResumeGeneration.ShouldBeTrue();
    }

    [Fact]
    public void IsGeneratingCoversPreparingThroughRendering()
    {
        var asset = new MediaAsset("u", ClipType.Video, "X");
        foreach (var status in new[] { GenerationStatus.Preparing, GenerationStatus.Generating, GenerationStatus.Downloading, GenerationStatus.Rendering })
        {
            asset.GenerationStatus = status;
            asset.IsGenerating.ShouldBeTrue();
        }
        asset.GenerationStatus = GenerationStatus.None;
        asset.IsGenerating.ShouldBeFalse();
        asset.GenerationStatus = GenerationStatus.Failed("x");
        asset.IsGenerating.ShouldBeFalse();
    }

    [Fact]
    public void IsRecoveringGenerationFalseWithoutResumableJob()
    {
        var asset = new MediaAsset("u", ClipType.Video, "X") { GenerationStatus = GenerationStatus.Generating };
        asset.IsRecoveringGeneration.ShouldBeFalse(); // no GenerationInput -> can't resume
    }

    [Fact]
    public void IsRecoveringGenerationTrueWhileActivelyGenerating()
    {
        var asset = new MediaAsset("u", ClipType.Video, "X")
        {
            GenerationInput = new GenerationInput { Prompt = "p", Model = "m", AspectRatio = "16:9", BackendJobId = "job-1" },
            GenerationStatus = GenerationStatus.Downloading,
        };
        asset.IsRecoveringGeneration.ShouldBeTrue();
    }

    [Fact]
    public void IsRecoveringGenerationTrueWhenFailedWithResultUrls()
    {
        var asset = new MediaAsset("u", ClipType.Video, "X")
        {
            GenerationInput = new GenerationInput { Prompt = "p", Model = "m", AspectRatio = "16:9", BackendJobId = "job-1", ResultUrls = ["https://x/y.mp4"] },
            GenerationStatus = GenerationStatus.Failed("network error"),
        };
        asset.IsRecoveringGeneration.ShouldBeTrue();
    }

    [Fact]
    public void IsRecoveringGenerationFalseWhenFailedWithoutResultUrls()
    {
        var asset = new MediaAsset("u", ClipType.Video, "X")
        {
            GenerationInput = new GenerationInput { Prompt = "p", Model = "m", AspectRatio = "16:9", BackendJobId = "job-1" },
            GenerationStatus = GenerationStatus.Failed("network error"),
        };
        asset.IsRecoveringGeneration.ShouldBeFalse();
    }

    // MARK: - ToManifestEntry / FromManifestEntry

    [Fact]
    public void ToManifestEntryUsesProjectRelativeSourceWhenUnderProjectPath()
    {
        var projectPath = Path.Combine(Path.GetTempPath(), "proj");
        var asset = new MediaAsset(Path.Combine(projectPath, "media", "clip.mp4"), ClipType.Video, "Clip");

        var entry = asset.ToManifestEntry(projectPath);

        entry.Source.Kind.ShouldBe(MediaSourceKind.Project);
        entry.Source.Path.ShouldBe(Path.Combine("media", "clip.mp4"));
    }

    [Fact]
    public void ToManifestEntryClampsToEmptyRelativePathWhenUrlEqualsProjectPath()
    {
        // Edge case: Url == projectPath exactly (StartsWith is true, but there's no "/" + suffix
        // left to slice). Swift's dropFirst(count+1) clamps to "" instead of throwing.
        var projectPath = Path.Combine(Path.GetTempPath(), "proj");
        var asset = new MediaAsset(projectPath, ClipType.Video, "Clip");

        var entry = asset.ToManifestEntry(projectPath);

        entry.Source.Kind.ShouldBe(MediaSourceKind.Project);
        entry.Source.Path.ShouldBe("");
    }

    [Fact]
    public void ToManifestEntryUsesExternalSourceWhenOutsideProjectPath()
    {
        var asset = new MediaAsset("/elsewhere/clip.mp4", ClipType.Video, "Clip");
        var entry = asset.ToManifestEntry(Path.Combine(Path.GetTempPath(), "proj"));
        entry.Source.Kind.ShouldBe(MediaSourceKind.External);
        entry.Source.Path.ShouldBe("/elsewhere/clip.mp4");
    }

    [Fact]
    public void ToManifestEntryUsesExternalSourceWhenNoProjectPath()
    {
        var asset = new MediaAsset("/elsewhere/clip.mp4", ClipType.Video, "Clip");
        var entry = asset.ToManifestEntry(null);
        entry.Source.Kind.ShouldBe(MediaSourceKind.External);
    }

    [Fact]
    public void ToManifestEntryOmitsExpiredCachedRemoteUrl()
    {
        var asset = new MediaAsset("u", ClipType.Video, "X")
        {
            CachedRemoteUrl = "https://cdn/x",
            CachedRemoteUrlExpiresAt = DateTimeOffset.UtcNow.AddMinutes(-1),
        };
        var entry = asset.ToManifestEntry(null);
        entry.CachedRemoteURL.ShouldBeNull();
        entry.CachedRemoteURLExpiresAt.ShouldBeNull();
    }

    [Fact]
    public void ToManifestEntryKeepsFreshCachedRemoteUrl()
    {
        var expiry = DateTimeOffset.UtcNow.AddMinutes(5);
        var asset = new MediaAsset("u", ClipType.Video, "X") { CachedRemoteUrl = "https://cdn/x", CachedRemoteUrlExpiresAt = expiry };
        var entry = asset.ToManifestEntry(null);
        entry.CachedRemoteURL.ShouldBe("https://cdn/x");
        entry.CachedRemoteURLExpiresAt.ShouldBe(expiry);
    }

    [Fact]
    public void ToManifestEntryOmitsTransientGenerationStatus()
    {
        var asset = new MediaAsset("u", ClipType.Video, "X") { GenerationStatus = GenerationStatus.Preparing };
        asset.ToManifestEntry(null).GenerationStatus.ShouldBeNull();
    }

    [Fact]
    public void FromManifestEntryRestoresFields()
    {
        var entry = new MediaManifestEntry(
            id: "a1", name: "Clip", type: ClipType.Video, source: MediaSource.External("/x.mp4"), duration: 3.5,
            sourceWidth: 1920, sourceHeight: 1080, sourceFPS: 30, hasAudio: true, folderId: "f1",
            generationStatus: "generating");

        var asset = MediaAsset.FromManifestEntry(entry, "/resolved/x.mp4");

        asset.Id.ShouldBe("a1");
        asset.Url.ShouldBe("/resolved/x.mp4");
        asset.Duration.ShouldBe(3.5);
        asset.SourceWidth.ShouldBe(1920);
        asset.HasAudio.ShouldBeTrue();
        asset.FolderId.ShouldBe("f1");
        asset.GenerationStatus.Kind.ShouldBe(GenerationStatusKind.Generating);
    }

    [Fact]
    public void FromManifestEntryDowngradesUnresumablePreparingToNone()
    {
        // .preparing restored from disk without a resumable backend job must not get stuck
        // showing "in progress" forever.
        var entry = new MediaManifestEntry(
            id: "a1", name: "Clip", type: ClipType.Video, source: MediaSource.External("/x.mp4"), duration: 1,
            generationStatus: "preparing");

        var asset = MediaAsset.FromManifestEntry(entry, "/resolved/x.mp4");

        asset.GenerationStatus.ShouldBe(GenerationStatus.None);
    }

    // MARK: - LoadMetadataAsync branching (test-double probe)

    private sealed class FakeProbe : IMediaProbe
    {
        public ImageProbeResult? Image;
        public VideoProbeResult? Video;
        public double? AssetDuration;
        public bool? HasAudioTrack;
        public LottieProbeResult? Lottie;

        public Task<ImageProbeResult?> ProbeImageAsync(string path) => Task.FromResult(Image);
        public Task<VideoProbeResult?> ProbeVideoAsync(string path) => Task.FromResult(Video);
        public Task<double?> ProbeAssetDurationAsync(string path) => Task.FromResult(AssetDuration);
        public Task<bool?> HasAudioTrackAsync(string path) => Task.FromResult(HasAudioTrack);
        public Task<LottieProbeResult?> ProbeLottieAsync(string path) => Task.FromResult(Lottie);
    }

    [Fact]
    public async Task LoadMetadataImageSetsFixedDurationAndDimensions()
    {
        var asset = new MediaAsset("img.png", ClipType.Image, "Img");
        var probe = new FakeProbe { Image = new ImageProbeResult { Width = 100, Height = 200 } };

        var ok = await asset.LoadMetadataAsync(probe);

        ok.ShouldBeTrue();
        asset.Duration.ShouldBe(Defaults.ImageDurationSeconds);
        asset.SourceWidth.ShouldBe(100);
        asset.SourceHeight.ShouldBe(200);
    }

    [Fact]
    public async Task LoadMetadataImageFailsWhenDimensionsUnavailable()
    {
        var asset = new MediaAsset("img.png", ClipType.Image, "Img");
        var probe = new FakeProbe { Image = null };

        (await asset.LoadMetadataAsync(probe)).ShouldBeFalse();
    }

    [Fact]
    public async Task LoadMetadataLottieAppliesMetadataOnSuccess()
    {
        var asset = new MediaAsset("a.lottie", ClipType.Lottie, "Anim");
        var probe = new FakeProbe { Lottie = new LottieProbeResult { Duration = 2.5, Width = 512, Height = 512, FrameRate = 60 } };

        (await asset.LoadMetadataAsync(probe)).ShouldBeTrue();
        asset.Duration.ShouldBe(2.5);
        asset.SourceFPS.ShouldBe(60);
    }

    [Fact]
    public async Task LoadMetadataLottieFailsWhenInspectFails()
    {
        var asset = new MediaAsset("a.lottie", ClipType.Lottie, "Anim");
        (await asset.LoadMetadataAsync(new FakeProbe { Lottie = null })).ShouldBeFalse();
    }

    [Fact]
    public async Task LoadMetadataVideoPrefersVideoTrackDurationOverAssetDuration()
    {
        var asset = new MediaAsset("v.mp4", ClipType.Video, "V");
        var probe = new FakeProbe
        {
            Video = new VideoProbeResult { HasVideoTrack = true, Width = 1920, Height = 1080, FrameRate = 24, VideoTrackDurationSeconds = 10 },
            AssetDuration = 999,
            HasAudioTrack = true,
        };

        var ok = await asset.LoadMetadataAsync(probe);

        ok.ShouldBeTrue();
        asset.Duration.ShouldBe(10); // track duration wins, not the 999 asset-level fallback
        asset.SourceFPS.ShouldBe(24);
        asset.HasAudio.ShouldBeTrue();
    }

    [Fact]
    public async Task LoadMetadataVideoFallsBackToAssetDurationWhenNoVideoTrackDuration()
    {
        var asset = new MediaAsset("v.mp4", ClipType.Video, "V");
        var probe = new FakeProbe
        {
            Video = new VideoProbeResult { HasVideoTrack = false },
            AssetDuration = 42,
            HasAudioTrack = false,
        };

        var ok = await asset.LoadMetadataAsync(probe);

        ok.ShouldBeFalse(); // no video track -> loadMetadata reports failure
        asset.Duration.ShouldBe(42);
    }

    [Fact]
    public async Task LoadMetadataAudioSetsDurationAndReturnsAudioTrackPresence()
    {
        var asset = new MediaAsset("a.wav", ClipType.Audio, "A");
        var probe = new FakeProbe { AssetDuration = 12.5, HasAudioTrack = true };

        var ok = await asset.LoadMetadataAsync(probe);

        ok.ShouldBeTrue();
        asset.Duration.ShouldBe(12.5);
    }

    [Fact]
    public async Task LoadMetadataAudioReturnsFalseWhenNoAudioTrack()
    {
        var asset = new MediaAsset("a.wav", ClipType.Audio, "A");
        var probe = new FakeProbe { AssetDuration = 12.5, HasAudioTrack = false };

        (await asset.LoadMetadataAsync(probe)).ShouldBeFalse();
    }

    [Fact]
    public async Task LoadMetadataTextClipsTriviallySucceedWithoutProbing()
    {
        var asset = new MediaAsset("caption-1", ClipType.Text, "Caption");
        (await asset.LoadMetadataAsync(new FakeProbe())).ShouldBeTrue();
    }
}
