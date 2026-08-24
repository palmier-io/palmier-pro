using System.Text.Json;
using PalmierPro.Agent.Tools;
using PalmierPro.Core.Models;
using PalmierPro.Core.Transcription;
using Xunit;

namespace PalmierPro.Agent.Tests;

[Collection(LocalSttCollection.Name)]
public class InspectImageReceiptTests
{
    [Fact]
    public async Task InspectTimelineReturnsImageBlocks()
    {
        var host = new FakeAgentHost();
        host.Timeline.Tracks[0].Clips.Add(new Clip
        {
            MediaRef = "m",
            StartFrame = 0,
            DurationFrames = 90,
        });
        var executor = new ToolExecutor(host);
        var result = await executor.ExecuteAsync("inspect_timeline", """{"startFrame":0,"endFrame":60,"maxFrames":3}""");
        Assert.False(result.IsError, result.Content);
        Assert.NotEmpty(result.Images);
        Assert.All(result.Images, img =>
        {
            Assert.Equal("image/jpeg", img.MediaType);
            Assert.False(string.IsNullOrWhiteSpace(img.Base64));
        });
        Assert.Contains("totalFrames", result.Content);
    }

    [Fact]
    public async Task InspectMediaReturnsImageBlocksForVideo()
    {
        var host = new FakeAgentHost();
        host.Manifest.Entries.Add(new MediaManifestEntry
        {
            Id = "vid1",
            Name = "clip",
            Type = ClipType.Video,
            Source = new MediaSource.External("C:\\x.mp4"),
            Duration = 5,
            SourceWidth = 1920,
            SourceHeight = 1080,
        });
        var executor = new ToolExecutor(host);
        var result = await executor.ExecuteAsync("inspect_media",
            """{"mediaRef":"vid1","maxFrames":2}""");
        Assert.False(result.IsError, result.Content);
        Assert.NotEmpty(result.Images);
        using var doc = JsonDocument.Parse(result.Content);
        Assert.Equal(2, doc.RootElement.GetProperty("imageCount").GetInt32());
    }

    [Fact]
    public async Task InspectMediaReturnsTranscriptionWithWordTimestamps()
    {
        var prev = LocalStt.Transcriber;
        var host = new FakeAgentHost();
        var wav = Path.Combine(Path.GetTempPath(), $"palmier-inspect-{Guid.NewGuid():N}.wav");
        File.WriteAllBytes(wav, new byte[44]);
        host.Manifest.Entries.Add(new MediaManifestEntry
        {
            Id = "aud1",
            Name = "take.wav",
            Type = ClipType.Audio,
            Source = new MediaSource.External(wav),
            Duration = 2,
            HasAudio = true,
        });

        try
        {
            LocalStt.Transcriber = new InspectStubTranscriber();
            var executor = new ToolExecutor(host);
            var result = await executor.ExecuteAsync("inspect_media",
                """{"mediaRef":"aud1","wordTimestamps":true}""");
            Assert.False(result.IsError, result.Content);

            using var doc = JsonDocument.Parse(result.Content);
            var tx = doc.RootElement.GetProperty("transcription");
            Assert.Equal(JsonValueKind.Object, tx.ValueKind);
            Assert.Equal("sourceSeconds", tx.GetProperty("timing").GetString());
            Assert.Equal("hello world", tx.GetProperty("text").GetString());
            Assert.True(tx.GetProperty("segments").GetArrayLength() >= 1);
            Assert.True(tx.GetProperty("words").GetArrayLength() >= 2);
            Assert.NotNull(TranscriptCache.Shared.Get(host.PackagePath));
        }
        finally
        {
            LocalStt.Transcriber = prev;
            TranscriptCache.Shared.Clear(host.PackagePath);
            try { File.Delete(wav); } catch { }
        }
    }

    private sealed class InspectStubTranscriber : ISpeechTranscriber
    {
        public bool IsAvailable => true;

        public TranscriptDocument? Transcribe(string path, string mediaRef, int fps, string? language)
            => new TranscriptDocument
            {
                MediaRef = mediaRef,
                Source = "whisper",
                Language = language ?? "en",
                Text = "hello world",
                Words =
                [
                    new TranscriptWord
                    {
                        Text = "hello", StartFrame = 0, EndFrame = 15,
                        StartSeconds = 0, EndSeconds = 0.5, Index = 0,
                    },
                    new TranscriptWord
                    {
                        Text = "world", StartFrame = 15, EndFrame = 30,
                        StartSeconds = 0.5, EndSeconds = 1.0, Index = 1,
                    },
                ],
                Segments =
                [
                    new TranscriptSegment
                    {
                        Text = "hello world", StartFrame = 0, EndFrame = 30,
                        StartSeconds = 0, EndSeconds = 1.0,
                    },
                ],
            };
    }
}
