using PalmierPro.Core.Analysis;
using PalmierPro.Core.Search;
using Xunit;

namespace PalmierPro.Core.Tests;

public class AnalysisPlannerTests
{
    [Fact]
    public void RemovableMaskFiltersPausesShorterThanMinimum()
    {
        var settings = SilenceRemovalSettings.Create(0.5, 0)!;
        var mask = SilenceRemovalPlanner.RemovableMask(
            [false, true, true, true, true, false], settings, cellDuration: 0.1);
        Assert.DoesNotContain(true, mask);
    }

    [Fact]
    public void RemovableMaskPadsBothSpeechBoundaries()
    {
        var settings = SilenceRemovalSettings.Create(0.5, 0.2)!;
        var quiet = new[] { false }.Concat(Enumerable.Repeat(true, 10)).Concat([false]).ToArray();
        var mask = SilenceRemovalPlanner.RemovableMask(quiet, settings, cellDuration: 0.1);
        var expected = new[] { false, false, false }
            .Concat(Enumerable.Repeat(true, 6))
            .Concat([false, false, false])
            .ToArray();
        Assert.Equal(expected, mask);
    }

    [Fact]
    public void RemovableMaskDoesNotPadSourceEdges()
    {
        var settings = SilenceRemovalSettings.Create(0.3, 0.2)!;
        var quiet = Enumerable.Repeat(true, 5).Concat([false]).Concat(Enumerable.Repeat(true, 5)).ToArray();
        var mask = SilenceRemovalPlanner.RemovableMask(quiet, settings, cellDuration: 0.1);
        Assert.Equal(
            new[] { true, true, true, false, false, false, false, false, true, true, true },
            mask);
    }

    [Fact]
    public void RejectsInvalidSilenceSettings()
    {
        Assert.Null(SilenceRemovalSettings.Create(double.NaN, 0.15));
        Assert.Null(SilenceRemovalSettings.Create(0.1, 0.15));
        Assert.Null(SilenceRemovalSettings.Create(0.5, 0.75));
    }

    [Fact]
    public void WordCutPlannerMergesSelectedRuns()
    {
        var words = new WordCutPlanner.Word[]
        {
            new(0, 10, false),
            new(10, 20, true),
            new(20, 30, true),
            new(30, 40, false),
        };
        var ranges = WordCutPlanner.CutRanges(words, clipStart: 0, clipEnd: 40, keepGapFrames: 0);
        Assert.Single(ranges);
        Assert.Equal(10, ranges[0].Start);
        Assert.Equal(30, ranges[0].End);
    }

    [Fact]
    public void BeatPostprocessEstimatesBpmFromRegularGrid()
    {
        // 120 BPM → 0.5s interval
        var beats = Enumerable.Range(0, 8).Select(i => i * 0.5).ToList();
        var bpm = BeatPostprocess.EstimateBpm(beats);
        Assert.NotNull(bpm);
        Assert.InRange(bpm!.Value, 119, 121);
    }

    [Fact]
    public void OnsetDetectorFindsPeriodicClicks()
    {
        var sr = (int)BeatPostprocess.SampleRate;
        var samples = new float[sr * 2];
        // Impulse every 0.5s → 120 BPM
        for (var t = 0; t < 4; t++)
        {
            var idx = (int)(t * 0.5 * sr);
            if (idx < samples.Length) samples[idx] = 1f;
        }
        var analysis = OnsetBeatDetector.Detect(samples);
        Assert.True(analysis.Beats.Count >= 2);
        Assert.InRange(analysis.Bpm, 100, 140);
    }

    [Fact]
    public void EnergyVadMarksQuietCells()
    {
        var samples = new float[EnergyVad.SampleRate]; // 1s silence
        for (var i = EnergyVad.SampleRate / 4; i < EnergyVad.SampleRate / 2; i++)
            samples[i] = 0.5f;
        var speech = EnergyVad.SpeechMask(samples);
        Assert.Contains(true, speech);
        Assert.Contains(false, speech);
    }

    [Fact]
    public void EmbeddingStoreRoundTripAndSearch()
    {
        var store = new EmbeddingStore();
        store.Add("a", 0, EmbeddingMath.TextEmbed("cat video"));
        store.Add("b", 0, EmbeddingMath.TextEmbed("ocean waves"));
        var dir = Path.Combine(Path.GetTempPath(), "palmier-emb-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        var path = Path.Combine(dir, "t.emb");
        try
        {
            store.Save(path);
            var loaded = EmbeddingStore.Load(path);
            var hits = loaded.Search(EmbeddingMath.TextEmbed("cat"), limit: 2);
            Assert.Equal("a", hits[0].MediaRef);
        }
        finally
        {
            Directory.Delete(dir, true);
        }
    }

    [Fact]
    public void CosineIdenticalIsOne()
    {
        var v = EmbeddingMath.TextEmbed("hello world");
        Assert.InRange(EmbeddingMath.Cosine(v, v), 0.999, 1.001);
    }
}
