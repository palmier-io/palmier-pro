using System.Drawing;
using Shouldly;
using Xunit;

namespace PalmierPro.Rendering.Tests;

// E3: GPU (GpuCompositor, D3D11) is the default render path; Compositor::Compose (CPU) is kept
// compiled and reachable only behind PALMIERENGINE_FORCE_CPU_COMPOSITOR (see
// TimelineSession.cpp). This asserts the two paths agree on a PLAIN two-track composite (no
// effects/keyframes — the CPU path's scope, see Compositor.h) within tolerance, so the fallback
// stays honest rather than silently drifting from the GPU path it stands in for.
[Collection(MediaFixturesCollection.Name)]
public sealed class GpuCpuFallbackConsistencyTests(MediaFixtures fixtures)
{
    private static string LoadTimelineSnapshotJson(string fixtureName, string fixtureDir) =>
        File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", fixtureName))
            .Replace("{{FIXTURE_DIR}}", fixtureDir.Replace("\\", "\\\\"));

    private static string RenderToTempPng(TimelineSession timeline, long frame)
    {
        string path = Path.Combine(Path.GetTempPath(), $"palmier-fallback-{Guid.NewGuid():N}.png");
        timeline.RenderFrameToFile(frame, path);
        return path;
    }

    [Fact]
    [Trait("Category", "Media")]
    public void TwoTrackComposite_GpuAndCpuPaths_AgreeWithinTolerance()
    {
        string json = LoadTimelineSnapshotJson("two-track.snapshot.json", fixtures.FixturesDir);

        string gpuPath, cpuPath;
        Environment.SetEnvironmentVariable("PALMIERENGINE_FORCE_CPU_COMPOSITOR", null);
        using (var gpuSession = new EngineSession())
        using (TimelineSession gpuTimeline = TimelineSession.Open(gpuSession, System.Text.Encoding.UTF8.GetBytes(json)))
        {
            gpuPath = RenderToTempPng(gpuTimeline, frame: 15);
        }

        Environment.SetEnvironmentVariable("PALMIERENGINE_FORCE_CPU_COMPOSITOR", "1");
        try
        {
            using var cpuSession = new EngineSession();
            using TimelineSession cpuTimeline = TimelineSession.Open(cpuSession, System.Text.Encoding.UTF8.GetBytes(json));
            cpuPath = RenderToTempPng(cpuTimeline, frame: 15);
        }
        finally
        {
            Environment.SetEnvironmentVariable("PALMIERENGINE_FORCE_CPU_COMPOSITOR", null);
        }

        try
        {
            using var gpuBitmap = new Bitmap(gpuPath);
            using var cpuBitmap = new Bitmap(cpuPath);
            gpuBitmap.Width.ShouldBe(cpuBitmap.Width);
            gpuBitmap.Height.ShouldBe(cpuBitmap.Height);

            for (int y = 10; y < gpuBitmap.Height; y += 41)
            {
                for (int x = 10; x < gpuBitmap.Width; x += 47)
                {
                    Color g = gpuBitmap.GetPixel(x, y);
                    Color c = cpuBitmap.GetPixel(x, y);
                    Math.Abs(g.R - c.R).ShouldBeLessThanOrEqualTo(8, $"R at ({x},{y}): gpu={g} cpu={c}");
                    Math.Abs(g.G - c.G).ShouldBeLessThanOrEqualTo(8, $"G at ({x},{y}): gpu={g} cpu={c}");
                    Math.Abs(g.B - c.B).ShouldBeLessThanOrEqualTo(8, $"B at ({x},{y}): gpu={g} cpu={c}");
                }
            }
        }
        finally
        {
            File.Delete(gpuPath);
            File.Delete(cpuPath);
        }
    }
}
