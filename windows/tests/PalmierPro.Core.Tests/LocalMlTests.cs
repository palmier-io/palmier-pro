using PalmierPro.Core.Analysis;
using PalmierPro.Core.Models;
using PalmierPro.Core.Transcription;
using Xunit;

namespace PalmierPro.Core.Tests;

public class LocalMlTests
{
    [Fact]
    public void LocalSttUsesInjectedTranscriberWithoutSyntheticLabels()
    {
        var prev = LocalStt.Transcriber;
        try
        {
            LocalStt.Transcriber = new FakeTranscriber();
            var doc = LocalStt.TranscribeFile("missing.wav", "media1", fps: 30);
            Assert.Equal("whisper", doc.Source);
            Assert.Equal("hello world", doc.Text);
            Assert.DoesNotContain("[speech", doc.Text, StringComparison.Ordinal);
            Assert.All(doc.Words, w => Assert.DoesNotContain("[speech", w.Text, StringComparison.Ordinal));
        }
        finally
        {
            LocalStt.Transcriber = prev;
        }
    }

    [Fact]
    public void VadServiceFakeEngineFeedsSilenceRemovalPlanner()
    {
        var prev = VadService.Engine;
        try
        {
            // 10 quiet cells (~0.32s) between speech runs — above MinimumPause 0.25s.
            VadService.Engine = new FixedMaskVad([
                true, true,
                false, false, false, false, false, false, false, false, false, false,
                true, true,
            ]);
            var quiet = VadService.QuietNonSpeechMask([]);
            Assert.Equal(14, quiet.Length);
            Assert.True(quiet[2] && quiet[11]);

            var settings = SilenceRemovalSettings.Create(0.25, 0.1)!;
            var removable = SilenceRemovalPlanner.RemovableMask(quiet, settings, cellDuration: 0.032);
            Assert.Contains(true, removable);
        }
        finally
        {
            VadService.Engine = prev;
        }
    }

    [Fact]
    public void DeadAirAnalyzerUsesInjectedVadEngine()
    {
        var prev = VadService.Engine;
        try
        {
            // Quiet run of 10 cells (~0.32s) between speech — above MinimumPause 0.25s.
            VadService.Engine = new FixedMaskVad([
                true, true, true,
                false, false, false, false, false, false, false, false, false, false,
                true, true, true,
            ]);

            var clip = new Clip
            {
                MediaRef = "a",
                StartFrame = 0,
                DurationFrames = 480,
                TrimStartFrame = 0,
                Speed = 1,
            };
            var mono = new float[(int)(SilenceRemovalPlanner.DefaultCellDuration * 16000 * 14)];
            var settings = SilenceRemovalSettings.Create(0.25, 0.05)!;
            var ranges = DeadAirAnalyzer.RemovableTimelineRanges(
                clip, fps: 30, mono, settings);
            Assert.NotEmpty(ranges);
        }
        finally
        {
            VadService.Engine = prev;
        }
    }

    private sealed class FakeTranscriber : ISpeechTranscriber
    {
        public bool IsAvailable => true;

        public TranscriptDocument? Transcribe(string path, string mediaRef, int fps, string? language)
            => new TranscriptDocument
            {
                MediaRef = mediaRef,
                Source = "whisper",
                Language = language,
                Text = "hello world",
                Words =
                [
                    new TranscriptWord { Text = "hello", StartFrame = 0, EndFrame = 15, Index = 0 },
                    new TranscriptWord { Text = "world", StartFrame = 15, EndFrame = 30, Index = 1 },
                ],
                Segments =
                [
                    new TranscriptSegment { Text = "hello world", StartFrame = 0, EndFrame = 30 },
                ],
            };
    }

    private sealed class FixedMaskVad(bool[] mask) : IVadEngine
    {
        public bool[] SpeechMask(ReadOnlySpan<float> mono16k) => mask;
    }
}
