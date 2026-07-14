using Shouldly;
using Xunit;

namespace PalmierPro.Rendering.Tests;

[Collection(MediaFixturesCollection.Name)]
public sealed class ThumbnailsTests(MediaFixtures fixtures)
{
    [Fact]
    [Trait("Category", "Media")]
    public async Task ExtractThumbnailsAsync_FiresCallbackOnceForEachRequestedTime()
    {
        using var session = new EngineSession();
        using MediaSource media = session.OpenMedia(fixtures.VideoWithAudioPath);

        double[] times = [0.0, 0.5, 1.0, 1.5];
        var results = new List<ThumbnailResult>();

        await foreach (ThumbnailResult thumb in media.ExtractThumbnailsAsync(times, 64, 36))
        {
            results.Add(thumb);
        }

        results.Count.ShouldBe(times.Length);
        results.Select(t => t.Index).Order().ShouldBe(Enumerable.Range(0, times.Length));
        foreach (ThumbnailResult thumb in results)
        {
            thumb.Width.ShouldBe(64);
            thumb.Height.ShouldBe(36);
            thumb.Bgra.Length.ShouldBe(thumb.StrideBytes * thumb.Height);
        }
    }

    [Fact]
    [Trait("Category", "Media")]
    public async Task ExtractThumbnailsAsync_HonorsCancellation()
    {
        using var session = new EngineSession();
        using MediaSource media = session.OpenMedia(fixtures.VideoWithAudioPath);

        double[] times = [.. Enumerable.Range(0, 60).Select(i => i * 0.03)];
        using var cts = new CancellationTokenSource();
        cts.Cancel(); // cancelled up front so the native cancel flag is observed before any decode starts

        var results = new List<ThumbnailResult>();
        await Should.ThrowAsync<OperationCanceledException>(async () =>
        {
            await foreach (ThumbnailResult thumb in media.ExtractThumbnailsAsync(times, 32, 18, cts.Token))
            {
                results.Add(thumb);
            }
        });

        results.Count.ShouldBeLessThan(times.Length);
    }
}
