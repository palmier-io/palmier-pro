using PalmierPro.Rendering;
using PalmierPro.Services.Media;
using Shouldly;
using Xunit;

namespace PalmierPro.Services.Tests.Media;

public sealed class MediaVisualCacheTests
{
    // ===== Pure math — no engine, no fixtures =====

    [Theory]
    [InlineData(0, new double[] { })]
    [InlineData(-1, new double[] { })]
    [InlineData(double.NaN, new double[] { })]
    [InlineData(double.PositiveInfinity, new double[] { })]
    [InlineData(2.0, new double[] { 0, 1 })]
    [InlineData(5.0, new double[] { 0, 1, 2, 3, 4 })]
    [InlineData(9.9, new double[] { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 })]
    [InlineData(15.0, new double[] { 0, 2, 4, 6, 8, 10, 12, 14 })]
    public void ComputeThumbnailTimes_MatchesMacIntervalRule(double duration, double[] expected)
    {
        // Mirrors MediaVisualCache.swift's `videoThumbnailTimes(duration:)`: 1s hops under 10s,
        // 2s hops at/above — verified independently of any decode.
        MediaVisualCache.ComputeThumbnailTimes(duration).ShouldBe(expected);
    }

    [Fact]
    public void WaveformContract_Normalize_MatchesHandComputedDbValues()
    {
        // normalized = clamp(20*log10(peak), -50, 0) / -50 — ported verbatim from
        // WaveformExtractor.swift's `normalized(peak:)`; MediaSource.ExtractPeakEnvelope applies
        // this before a sample ever reaches MediaVisualCache, so exercising it directly here is
        // the precise "normalization matches hand-computed values" check.
        WaveformContract.Normalize(1.0f).ShouldBe(0f, 1e-6f);   // 0 dB -> 0 (loudest)
        WaveformContract.Normalize(0.0f).ShouldBe(1f);          // silence -> 1 (silent)

        // 20*log10(0.01) = -40 dB -> clamp(-40, -50, 0) = -40 -> -40 / -50 = 0.8
        WaveformContract.Normalize(0.01f).ShouldBe(0.8f, 1e-4f);

        // 20*log10(0.1) = -20 dB -> -20 / -50 = 0.4
        WaveformContract.Normalize(0.1f).ShouldBe(0.4f, 1e-4f);

        // 20*log10(0.5) ~= -6.0206 dB -> -6.0206 / -50 ~= 0.120412
        WaveformContract.Normalize(0.5f).ShouldBe(0.120412f, 1e-4f);

        // A peak quieter than the -50 dB noise floor clamps to 1 (fully silent), not > 1.
        WaveformContract.Normalize(0.001f).ShouldBe(1f, 1e-4f);

        // Never negative and never above 1 for any peak in (0, 1].
        for (float p = 0.05f; p <= 1f; p += 0.05f)
        {
            float n = WaveformContract.Normalize(p);
            n.ShouldBeGreaterThanOrEqualTo(0f);
            n.ShouldBeLessThanOrEqualTo(1f);
        }
    }

    [Theory]
    [InlineData(640, 360, 120, 68)]   // 16:9-ish, close to but not exactly the 120x68 box — rounds to it
    [InlineData(360, 640, 38, 68)]    // 9:16 portrait — height-constrained, must NOT stretch to 120 wide (matches the finding's "~38x68" example)
    [InlineData(10000, 1, 120, 1)]    // extremely wide — height would round to 0px without the Math.Max(1, ...) floor
    [InlineData(64, 48, 64, 48)]      // smaller than the box in both dims — never upscaled
    public void FitThumbnailSize_AspectFitsWithinTheBoundingBox_NeverStretchingOrUpscaling(
        int sourceWidth, int sourceHeight, int expectedWidth, int expectedHeight)
    {
        (int width, int height) = MediaVisualCache.FitThumbnailSize(sourceWidth, sourceHeight);
        width.ShouldBe(expectedWidth);
        height.ShouldBe(expectedHeight);
        width.ShouldBeLessThanOrEqualTo(MediaVisualCache.ThumbnailWidth);
        height.ShouldBeLessThanOrEqualTo(MediaVisualCache.ThumbnailHeight);
    }

    [Fact]
    public void FitThumbnailSize_DegenerateSourceSize_FallsBackToTheBoundingBox()
    {
        MediaVisualCache.FitThumbnailSize(0, 480).ShouldBe((MediaVisualCache.ThumbnailWidth, MediaVisualCache.ThumbnailHeight));
        MediaVisualCache.FitThumbnailSize(640, -1).ShouldBe((MediaVisualCache.ThumbnailWidth, MediaVisualCache.ThumbnailHeight));
    }

    // ===== Engine-backed generation + disk cache =====

    [Collection(MediaFixturesCollection.Name)]
    public sealed class WithFixtures(MediaFixtures fixtures)
    {
        [Fact]
        [Trait("Category", "Media")]
        public async Task GenerateVideoThumbnails_ProducesAFilmstripSprite_AtTheRequestedTileSize()
        {
            using var tmp = new TempDirectory();
            using var session = new EngineSession();
            var cache = new MediaVisualCache(session, new DiskCache("thumbs", tmp.Path));

            IReadOnlyList<CachedThumbnail> thumbs = await GenerateAndAwaitThumbnailsAsync(cache, "asset-1", fixtures.VideoWithAudioPath);

            thumbs.Count.ShouldBe(2); // 2s fixture, 1s hops -> times [0, 1]
            thumbs.ShouldAllBe(t => t.Width == MediaVisualCache.ThumbnailWidth && t.Height == MediaVisualCache.ThumbnailHeight);
            thumbs.ShouldAllBe(t => t.Bgra.Length == t.StrideBytes * t.Height);
            thumbs.Select(t => t.TimeSeconds).ShouldBe([0.0, 1.0]);
        }

        [Fact]
        [Trait("Category", "Media")]
        public async Task GenerateVideoThumbnails_PortraitSource_AspectFitsInsteadOfStretchingToTheFixedTile()
        {
            using var tmp = new TempDirectory();
            using var session = new EngineSession();
            var cache = new MediaVisualCache(session, new DiskCache("thumbs-portrait", tmp.Path));

            IReadOnlyList<CachedThumbnail> thumbs = await GenerateAndAwaitThumbnailsAsync(cache, "asset-portrait", fixtures.PortraitVideoPath);

            (int expectedWidth, int expectedHeight) = MediaVisualCache.FitThumbnailSize(
                MediaFixtures.PortraitVideoWidth, MediaFixtures.PortraitVideoHeight);
            expectedWidth.ShouldBeLessThan(MediaVisualCache.ThumbnailWidth); // narrower than the bounding box — height-constrained
            expectedHeight.ShouldBe(MediaVisualCache.ThumbnailHeight);
            thumbs.ShouldAllBe(t => t.Width == expectedWidth && t.Height == expectedHeight);
            thumbs.ShouldAllBe(t => t.Bgra.Length == t.StrideBytes * t.Height);
        }

        [Fact]
        [Trait("Category", "Media")]
        public async Task GenerateWaveform_ProducesNormalizedSamples_ForTheFixture()
        {
            using var tmp = new TempDirectory();
            using var session = new EngineSession();
            var cache = new MediaVisualCache(session, new DiskCache("waves", tmp.Path));

            float[] samples = await GenerateAndAwaitWaveformAsync(cache, "asset-1", fixtures.VideoWithAudioPath);

            samples.Length.ShouldBeGreaterThan(0);
            samples.ShouldAllBe(s => s >= 0f && s <= 1f);
        }

        [Fact]
        [Trait("Category", "Media")]
        public async Task GenerateVideoThumbnails_SecondRequest_ServesFromDiskCache_WithoutReExtracting()
        {
            using var tmp = new TempDirectory();
            using var session = new EngineSession();
            int opens = 0;
            MediaSource CountingOpen(string path)
            {
                opens++;
                return session.OpenMedia(path);
            }
            var cache = new MediaVisualCache(CountingOpen, new DiskCache("thumbs", tmp.Path));

            IReadOnlyList<CachedThumbnail> first = await GenerateAndAwaitThumbnailsAsync(cache, "asset-1", fixtures.VideoWithAudioPath);
            opens.ShouldBe(1);
            string[] cacheFiles = Directory.GetFiles(Path.Combine(tmp.Path, "thumbs"));
            cacheFiles.ShouldContain(f => f.EndsWith(".thumbs.jpg"));
            cacheFiles.ShouldContain(f => f.EndsWith(".thumbs.json"));

            // Clear the in-memory layer so the second request can only be satisfied by disk.
            cache.Invalidate("asset-1");

            IReadOnlyList<CachedThumbnail> second = await GenerateAndAwaitThumbnailsAsync(cache, "asset-1", fixtures.VideoWithAudioPath);

            opens.ShouldBe(1); // no second native OpenMedia call — served from disk
            second.Select(t => t.TimeSeconds).ShouldBe(first.Select(t => t.TimeSeconds));
            second.ShouldAllBe(t => t.Width == MediaVisualCache.ThumbnailWidth && t.Height == MediaVisualCache.ThumbnailHeight);
        }

        [Fact]
        [Trait("Category", "Media")]
        public async Task GenerateWaveform_SecondRequest_ServesFromDiskCache_WithoutReExtracting()
        {
            using var tmp = new TempDirectory();
            using var session = new EngineSession();
            int opens = 0;
            MediaSource CountingOpen(string path)
            {
                opens++;
                return session.OpenMedia(path);
            }
            var cache = new MediaVisualCache(CountingOpen, new DiskCache("waves", tmp.Path));

            float[] first = await GenerateAndAwaitWaveformAsync(cache, "asset-1", fixtures.VideoWithAudioPath);
            opens.ShouldBe(1);
            Directory.GetFiles(Path.Combine(tmp.Path, "waves")).ShouldContain(f => f.EndsWith(".waveform"));

            cache.Invalidate("asset-1");
            float[] second = await GenerateAndAwaitWaveformAsync(cache, "asset-1", fixtures.VideoWithAudioPath);

            opens.ShouldBe(1);
            second.ShouldBe(first);
        }

        [Fact]
        [Trait("Category", "Media")]
        public async Task GenerateVideoThumbnails_CalledAgainWhileInFlight_OnlyOpensMediaOnce()
        {
            using var tmp = new TempDirectory();
            using var session = new EngineSession();
            int opens = 0;
            MediaSource CountingOpen(string path)
            {
                Interlocked.Increment(ref opens);
                return session.OpenMedia(path);
            }
            var cache = new MediaVisualCache(CountingOpen, new DiskCache("dup", tmp.Path));

            // The in-flight guard is set synchronously inside GenerateVideoThumbnails itself, so a
            // second call issued right after the first (before either has a chance to complete)
            // deterministically no-ops rather than racing.
            Task<IReadOnlyList<CachedThumbnail>> firstCompletion = GenerateAndAwaitThumbnailsAsync(cache, "asset-1", fixtures.VideoWithAudioPath);
            cache.GenerateVideoThumbnails("asset-1", fixtures.VideoWithAudioPath);
            await firstCompletion;

            opens.ShouldBe(1);
        }

        private static async Task<IReadOnlyList<CachedThumbnail>> GenerateAndAwaitThumbnailsAsync(MediaVisualCache cache, string mediaRef, string path)
        {
            var tcs = new TaskCompletionSource<IReadOnlyList<CachedThumbnail>>();
            void Handler(object? _, ThumbnailsUpdatedEventArgs e)
            {
                if (e.MediaRef == mediaRef && e.IsComplete)
                {
                    tcs.TrySetResult(e.Thumbnails);
                }
            }
            cache.ThumbnailsUpdated += Handler;
            try
            {
                cache.GenerateVideoThumbnails(mediaRef, path);
                using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(30));
                using CancellationTokenRegistration registration = cts.Token.Register(() => tcs.TrySetCanceled());
                return await tcs.Task;
            }
            finally
            {
                cache.ThumbnailsUpdated -= Handler;
            }
        }

        private static async Task<float[]> GenerateAndAwaitWaveformAsync(MediaVisualCache cache, string mediaRef, string path)
        {
            var tcs = new TaskCompletionSource<float[]>();
            void Handler(object? _, WaveformReadyEventArgs e)
            {
                if (e.MediaRef == mediaRef)
                {
                    tcs.TrySetResult(e.Samples);
                }
            }
            cache.WaveformReady += Handler;
            try
            {
                cache.GenerateWaveform(mediaRef, path);
                using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(30));
                using CancellationTokenRegistration registration = cts.Token.Register(() => tcs.TrySetCanceled());
                return await tcs.Task;
            }
            finally
            {
                cache.WaveformReady -= Handler;
            }
        }
    }
}
