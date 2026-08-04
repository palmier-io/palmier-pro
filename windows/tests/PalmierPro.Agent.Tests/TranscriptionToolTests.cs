using System.Text.Json;
using PalmierPro.Agent.Tools;
using PalmierPro.Core.Transcription;
using Xunit;

namespace PalmierPro.Agent.Tests;

[Collection(LocalSttCollection.Name)]
public class TranscriptionToolTests
{
    [Fact]
    public async Task RemoveWordsMatchesCachedTranscriptIndices()
    {
        var prevTranscriber = LocalStt.Transcriber;
        var host = new FakeAgentHost();
        var cacheKey = host.PackagePath;
        try
        {
            LocalStt.Transcriber = new StubTranscriber();
            TranscriptCache.Shared.Store(cacheKey, new TranscriptDocument
            {
                MediaRef = "clip-a",
                Source = "whisper",
                Text = "remove keep",
                Words =
                [
                    new TranscriptWord { Text = "remove", StartFrame = 0, EndFrame = 30, Index = 0 },
                    new TranscriptWord { Text = "keep", StartFrame = 60, EndFrame = 90, Index = 1 },
                ],
                Segments =
                [
                    new TranscriptSegment { Text = "remove keep", StartFrame = 0, EndFrame = 90 },
                ],
            });

            host.Timeline.Tracks[0].Clips.Add(new PalmierPro.Core.Models.Clip
            {
                MediaRef = "clip-a",
                StartFrame = 0,
                DurationFrames = 120,
            });

            var executor = new ToolExecutor(host);
            // tight: still pads half a keep-gap into the inter-word silence (WordCutPlanner).
            var result = await executor.ExecuteAsync("remove_words",
                """{"words":[0],"cutAggressiveness":"tight"}""");
            Assert.False(result.IsError, result.Content);

            using var doc = JsonDocument.Parse(result.Content);
            var ranges = doc.RootElement.GetProperty("removedRanges").EnumerateArray().ToList();
            Assert.NotEmpty(ranges);
            Assert.Equal(0, ranges[0].GetProperty("start").GetInt32());
            // Index 0 word is 0–30; next word starts at 60 — cut extends into the gap.
            Assert.True(ranges[0].GetProperty("end").GetInt32() >= 30);
            Assert.True(ranges[0].GetProperty("end").GetInt32() <= 60);
            Assert.Null(TranscriptCache.Shared.Get(cacheKey));
        }
        finally
        {
            TranscriptCache.Shared.Clear(cacheKey);
            LocalStt.Transcriber = prevTranscriber;
        }
    }

    [Fact]
    public async Task GetTranscriptReportsWhisperSourceNote()
    {
        var prevTranscriber = LocalStt.Transcriber;
        var host = new FakeAgentHost();
        var mediaId = "abc123";
        var wav = Path.Combine(Path.GetTempPath(), $"palmier-stt-{Guid.NewGuid():N}.wav");
        // Minimal valid-enough WAV header so File.Exists passes; StubTranscriber ignores bytes.
        File.WriteAllBytes(wav, new byte[44]);
        host.Manifest.Entries.Add(new PalmierPro.Core.Models.MediaManifestEntry
        {
            Id = mediaId,
            Name = "clip.wav",
            Type = PalmierPro.Core.Models.ClipType.Audio,
            Source = new PalmierPro.Core.Models.MediaSource.External(wav),
            Duration = 3,
        });

        try
        {
            LocalStt.Transcriber = new StubTranscriber();
            var executor = new ToolExecutor(host);
            var result = await executor.ExecuteAsync("get_transcript",
                $$"""{"mediaRef":"{{mediaId}}","preferLocal":true}""");
            Assert.False(result.IsError, result.Content);

            using var doc = JsonDocument.Parse(result.Content);
            Assert.Equal("whisper", doc.RootElement.GetProperty("transcriptionSource").GetString());
            Assert.Contains("Whisper", doc.RootElement.GetProperty("note").GetString());
        }
        finally
        {
            LocalStt.Transcriber = prevTranscriber;
            TranscriptCache.Shared.Clear(host.PackagePath);
            try { File.Delete(wav); } catch { }
        }
    }

}
