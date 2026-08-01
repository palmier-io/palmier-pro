using PalmierPro.Core.Export;
using PalmierPro.Core.Models;
using Xunit;

namespace PalmierPro.Core.Tests;

public class ExportTests
{
    [Theory]
    [InlineData(ExportResolution.R1080p, 1920, 1080, 1920, 1080)]
    [InlineData(ExportResolution.R720p, 1920, 1080, 1280, 720)]
    [InlineData(ExportResolution.MatchTimeline, 1921, 1081, 1920, 1080)]
    [InlineData(ExportResolution.R4k, 1920, 1080, 3840, 2160)]
    public void RenderSizeScalesAndEvens(
        ExportResolution resolution, int cw, int ch, int ew, int eh)
    {
        var (w, h) = ExportResolutionMath.RenderSize(resolution, cw, ch);
        Assert.Equal(ew, w);
        Assert.Equal(eh, h);
        Assert.Equal(0, w % 2);
        Assert.Equal(0, h % 2);
    }

    [Fact]
    public async Task QueueRunsJobsSeriallyAndReportsCompletion()
    {
        var started = new List<string>();
        var gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var queue = new ExportQueue(async (job, ct, progress) =>
        {
            started.Add(job.Id);
            if (started.Count == 1) await gate.Task.WaitAsync(ct);
            progress.Report(1);
            return new ExportRunReport { OutputBytes = 1 };
        });

        var dir = Path.Combine(Path.GetTempPath(), "palmier-export-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            var a = queue.Enqueue(new ExportRequest
            {
                ProjectId = "p", Filename = "a.mp4", OutputPath = Path.Combine(dir, "a.mp4"),
                Format = ExportFormat.H264, Overwrite = true,
            });
            var b = queue.Enqueue(new ExportRequest
            {
                ProjectId = "p", Filename = "b.mp4", OutputPath = Path.Combine(dir, "b.mp4"),
                Format = ExportFormat.H264, Overwrite = true,
            });

            await WaitUntil(() => started.Count == 1);
            Assert.Equal(a.Id, started[0]);
            Assert.Empty(started.Where(id => id == b.Id));

            gate.SetResult();
            await WaitUntil(() =>
                queue.Jobs.All(j => j.Status is ExportJobStatus.Completed));
            Assert.Equal(2, started.Count);
            Assert.All(queue.Jobs, j => Assert.Equal(ExportJobStatus.Completed, j.Status));
        }
        finally
        {
            try { Directory.Delete(dir, true); } catch { }
        }
    }

    [Fact]
    public async Task CancelQueuedJobNeverStarts()
    {
        var started = 0;
        var hold = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var queue = new ExportQueue(async (job, ct, progress) =>
        {
            Interlocked.Increment(ref started);
            await hold.Task.WaitAsync(ct);
            return new ExportRunReport();
        });

        var dir = Path.Combine(Path.GetTempPath(), "palmier-export-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            var first = queue.Enqueue(new ExportRequest
            {
                ProjectId = "p", Filename = "a.mp4", OutputPath = Path.Combine(dir, "a.mp4"),
                Format = ExportFormat.H264, Overwrite = true,
            });
            var second = queue.Enqueue(new ExportRequest
            {
                ProjectId = "p", Filename = "b.mp4", OutputPath = Path.Combine(dir, "b.mp4"),
                Format = ExportFormat.H264, Overwrite = true,
            });
            await WaitUntil(() => started == 1);
            Assert.True(queue.Cancel(second.Id));
            Assert.Equal(ExportJobStatus.Canceled, second.Status);

            hold.SetResult();
            await WaitUntil(() => first.Status == ExportJobStatus.Completed);
            Assert.Equal(1, started);
        }
        finally
        {
            try { Directory.Delete(dir, true); } catch { }
        }
    }

    [Fact]
    public void XmlExportWritesXmemlRoot()
    {
        var timeline = new Timeline
        {
            Fps = 30,
            Width = 1920,
            Height = 1080,
            Tracks =
            [
                new Track
                {
                    Type = ClipType.Video,
                    Clips =
                    [
                        new Clip
                        {
                            MediaRef = "clipA",
                            MediaType = ClipType.Video,
                            SourceClipType = ClipType.Video,
                            StartFrame = 0,
                            DurationFrames = 30,
                        },
                    ],
                },
            ],
        };
        var path = Path.Combine(Path.GetTempPath(), $"xmeml-{Guid.NewGuid():N}.xml");
        try
        {
            XmlExporter.Write(timeline, path, "Test");
            var text = File.ReadAllText(path);
            Assert.Contains("<xmeml version=\"4\">", text);
            Assert.Contains("clipA", text);
        }
        finally
        {
            try { File.Delete(path); } catch { }
        }
    }

    [Fact]
    public void FcpxmlExportWritesVersionedRoot()
    {
        var timeline = new Timeline
        {
            Fps = 24,
            Width = 1280,
            Height = 720,
            Tracks =
            [
                new Track
                {
                    Type = ClipType.Video,
                    Clips =
                    [
                        new Clip
                        {
                            MediaRef = "a",
                            MediaType = ClipType.Video,
                            SourceClipType = ClipType.Video,
                            StartFrame = 10,
                            DurationFrames = 24,
                        },
                    ],
                },
            ],
        };
        var path = Path.Combine(Path.GetTempPath(), $"fcpxml-{Guid.NewGuid():N}.fcpxml");
        try
        {
            FcpxmlExporter.Write(timeline, path, "Test");
            var text = File.ReadAllText(path);
            Assert.Contains("fcpxml version=\"1.10\"", text);
            Assert.Contains("asset-clip", text);
        }
        finally
        {
            try { File.Delete(path); } catch { }
        }
    }

    [Fact]
    public void PlatformSupportRefusesProResAndAllowsHevcHdr()
    {
        Assert.False(ExportPlatformSupport.IsRunnable(ExportFormat.ProRes));
        Assert.Contains("ProRes", ExportPlatformSupport.RefusalMessage(ExportFormat.ProRes)!);
        Assert.True(ExportPlatformSupport.IsRunnable(ExportFormat.HevcHdr));
        Assert.Null(ExportPlatformSupport.RefusalMessage(ExportFormat.HevcHdr));
        Assert.True(ExportPlatformSupport.IsRunnable(ExportFormat.Palmier));
        Assert.Null(ExportPlatformSupport.RefusalMessage(ExportFormat.Palmier));
        Assert.Equal("mov", ExportFormat.HevcHdr.FileExtension());
        Assert.Equal("palmier", ExportFormat.Palmier.FileExtension());
        Assert.Contains("HEVC", ExportPlatformSupport.MezzanineGuidance);
    }

    private static async Task WaitUntil(Func<bool> predicate, int timeoutMs = 5000)
    {
        var start = Environment.TickCount64;
        while (!predicate())
        {
            if (Environment.TickCount64 - start > timeoutMs)
                throw new TimeoutException("Condition not met.");
            await Task.Delay(10);
        }
    }
}
