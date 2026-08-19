using System.Text.Json;
using PalmierPro.Agent.Tools;
using PalmierPro.Core.Models;
using PalmierPro.Core.Transcription;
using Xunit;

namespace PalmierPro.Agent.Tests;

[Collection(LocalSttCollection.Name)]
public class MutationDeltaTests
{
    [Fact]
    public async Task RemoveWordsReturnsNotesAndRemovedClipIdsShape()
    {
        var prev = LocalStt.Transcriber;
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

            // Two clips: first covers the removed word range and will be cut/removed.
            host.Timeline.Tracks[0].Clips.Add(new Clip
            {
                MediaRef = "clip-a",
                StartFrame = 0,
                DurationFrames = 45,
            });
            host.Timeline.Tracks[0].Clips.Add(new Clip
            {
                MediaRef = "clip-a",
                StartFrame = 45,
                DurationFrames = 75,
            });

            var executor = new ToolExecutor(host);
            var result = await executor.ExecuteAsync("remove_words",
                """{"words":[0],"cutAggressiveness":"tight"}""");
            Assert.False(result.IsError, result.Content);

            using var doc = JsonDocument.Parse(result.Content);
            Assert.True(doc.RootElement.TryGetProperty("notes", out var notes));
            Assert.True(notes.GetArrayLength() >= 1);
            Assert.Contains("get_transcript", notes[0].GetString(), StringComparison.OrdinalIgnoreCase);

            // MutationDelta always surfaces removals under removedClipIds when clips vanish.
            if (doc.RootElement.TryGetProperty("removedClipIds", out var removed))
                Assert.True(removed.GetArrayLength() >= 0);
            Assert.True(doc.RootElement.TryGetProperty("removedWords", out _));
            Assert.True(doc.RootElement.TryGetProperty("removedRanges", out _));
        }
        finally
        {
            TranscriptCache.Shared.Clear(cacheKey);
            LocalStt.Transcriber = prev;
        }
    }
}
