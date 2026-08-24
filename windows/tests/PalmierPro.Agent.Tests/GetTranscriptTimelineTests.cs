using System.Text.Json;
using PalmierPro.Agent.Tools;
using PalmierPro.Core.Models;
using PalmierPro.Core.Transcription;
using Xunit;

namespace PalmierPro.Agent.Tests;

[Collection(LocalSttCollection.Name)]
public class GetTranscriptTimelineTests
{
    [Fact]
    public async Task GetTranscriptWalksTimelineWithStubLocalStt()
    {
        var prev = LocalStt.Transcriber;
        var host = new FakeAgentHost();
        var wav = Path.Combine(Path.GetTempPath(), $"palmier-tl-stt-{Guid.NewGuid():N}.wav");
        File.WriteAllBytes(wav, new byte[44]);
        try
        {
            LocalStt.Transcriber = new StubTranscriber();
            var mediaId = "tl-media-1";
            host.Manifest.Entries.Add(new MediaManifestEntry
            {
                Id = mediaId,
                Name = "talk.wav",
                Type = ClipType.Audio,
                Source = new MediaSource.External(wav),
                Duration = 3,
            });
            host.Timeline.Tracks[1].Clips.Add(new Clip
            {
                MediaRef = mediaId,
                MediaType = ClipType.Audio,
                StartFrame = 30,
                DurationFrames = 60,
                TrimStartFrame = 0,
            });

            var executor = new ToolExecutor(host);
            var result = await executor.ExecuteAsync("get_transcript", "{}");
            Assert.False(result.IsError, result.Content);

            using var doc = JsonDocument.Parse(result.Content);
            Assert.True(doc.RootElement.TryGetProperty("words", out var words)
                        || doc.RootElement.TryGetProperty("text", out _));
            if (doc.RootElement.TryGetProperty("words", out words) && words.GetArrayLength() > 0)
            {
                // Project-frame mapping: stub words start at source 0 → timeline start 30.
                var first = words[0];
                if (first.TryGetProperty("startFrame", out var sf))
                    Assert.True(sf.GetInt32() >= 30);
            }
        }
        finally
        {
            LocalStt.Transcriber = prev;
            try { File.Delete(wav); } catch { }
        }
    }
}
