using PalmierPro.Media.Audio;
using PalmierPro.Media.Caches;
using Xunit;

namespace PalmierPro.Media.Tests;

public class WaveformMathTests
{
    [Fact]
    public void SilenceNormalizesToOne()
    {
        Assert.Equal(1f, WaveformExtractor.Normalized(0f));
        Assert.Equal(1f, WaveformExtractor.Normalized(-0.5f));
    }

    [Fact]
    public void FullScaleNormalizesToZero()
    {
        Assert.Equal(0f, WaveformExtractor.Normalized(1f), 6);
    }

    [Fact]
    public void BelowNoiseFloorClampsToOne()
    {
        // -60 dB is quieter than the -50 dB floor.
        Assert.Equal(1f, WaveformExtractor.Normalized(0.001f), 6);
    }

    [Theory]
    [InlineData(0.1f, 0.4f)]   // -20 dB → 20/50
    [InlineData(0.01f, 0.8f)]  // -40 dB → 40/50
    public void MidLevelsMapLinearlyInDb(float peak, float expected)
    {
        Assert.Equal(expected, WaveformExtractor.Normalized(peak), 4);
    }
}

public class DiskCacheKeyTests
{
    [Fact]
    public void MissingFileYieldsNullKey()
    {
        Assert.Null(DiskCache.KeyFor(Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"))));
    }

    [Fact]
    public async Task KeyIsStableUntilFileChanges()
    {
        var path = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N") + ".bin");
        try
        {
            await File.WriteAllBytesAsync(path, [1, 2, 3]);
            var first = DiskCache.KeyFor(path);
            var second = DiskCache.KeyFor(path);
            Assert.NotNull(first);
            Assert.Equal(first, second);
            Assert.Equal(32, first!.Length);

            // Different size ⇒ different key regardless of mtime.
            await File.WriteAllBytesAsync(path, [1, 2, 3, 4]);
            Assert.NotEqual(first, DiskCache.KeyFor(path));
        }
        finally
        {
            File.Delete(path);
        }
    }
}
