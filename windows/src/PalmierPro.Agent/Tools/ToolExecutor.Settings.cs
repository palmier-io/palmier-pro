using System.Text.Json;
using PalmierPro.Core.Models;

namespace PalmierPro.Agent.Tools;

public sealed partial class ToolExecutor
{
    private static ToolResult SetProjectSettings(IAgentEditorHost host, JsonElement args)
    {
        var timeline = host.ActiveTimeline;
        if (timeline is null) return ToolResult.Error("No active timeline.");

        var changed = new Dictionary<string, object?>();
        var notes = new List<string>();

        if (ToolArgs.Int(args, "fps") is { } fps && fps > 0 && fps != timeline.Fps)
        {
            RescaleTimelineFps(timeline, fps);
            changed["fps"] = timeline.Fps;
            notes.Add("Clip frame positions and durations were rescaled to the new fps.");
        }
        else if (ToolArgs.Int(args, "fps") is { } sameFps && sameFps > 0)
        {
            timeline.Fps = sameFps;
            changed["fps"] = sameFps;
        }

        if (ToolArgs.String(args, "aspectRatio") is { } ratioRaw
            && TryParseAspectRatio(ratioRaw, out var aw, out var ah))
        {
            var baseH = ToolArgs.Int(args, "height") ?? timeline.Height;
            if (baseH < 2) baseH = 1080;
            var width = Even((int)Math.Round(baseH * (aw / (double)ah)));
            var height = Even(baseH);
            if (ToolArgs.Int(args, "width") is { } explicitW && explicitW >= 2)
            {
                width = Even(explicitW);
                height = Even((int)Math.Round(width * (ah / (double)aw)));
            }
            timeline.Width = width;
            timeline.Height = height;
            changed["aspectRatio"] = $"{aw}:{ah}";
            changed["width"] = width;
            changed["height"] = height;
        }
        else
        {
            if (ToolArgs.Int(args, "width") is { } width && width >= 2)
            {
                timeline.Width = Even(width);
                changed["width"] = timeline.Width;
            }
            if (ToolArgs.Int(args, "height") is { } height && height >= 2)
            {
                timeline.Height = Even(height);
                changed["height"] = timeline.Height;
            }
        }

        if (ToolArgs.String(args, "quality") is { } quality)
        {
            changed["quality"] = quality.Trim();
            notes.Add(
                "quality is a delivery hint for export (use export_project codec=h265 + quality=mezzanine for high-bitrate HEVC). " +
                "It does not change timeline media.");
        }

        if (changed.Count == 0)
            return ToolResult.Error("Provide fps, width, height, aspectRatio, and/or quality.");

        timeline.SettingsConfigured = true;
        host.NotifyTimelineChanged();
        return ToolResult.OkJson(new
        {
            settings = changed,
            notes = notes.Count == 0 ? null : notes,
            note = "Active timeline settings updated.",
        });
    }

    private static void RescaleTimelineFps(Timeline timeline, int newFps)
    {
        var old = Math.Max(1, timeline.Fps);
        if (old == newFps)
        {
            timeline.Fps = newFps;
            return;
        }
        var scale = newFps / (double)old;
        int Scale(int frames) => Math.Max(0, (int)Math.Round(frames * scale, MidpointRounding.AwayFromZero));

        foreach (var track in timeline.Tracks)
        {
            foreach (var clip in track.Clips)
            {
                clip.StartFrame = Scale(clip.StartFrame);
                clip.DurationFrames = Math.Max(1, Scale(clip.DurationFrames));
                clip.TrimStartFrame = Scale(clip.TrimStartFrame);
                clip.TrimEndFrame = Scale(clip.TrimEndFrame);
                clip.FadeInFrames = Scale(clip.FadeInFrames);
                clip.FadeOutFrames = Scale(clip.FadeOutFrames);
                clip.RescaleKeyframes(scale);
            }
        }
        timeline.Fps = newFps;
    }

    private static bool TryParseAspectRatio(string raw, out int w, out int h)
    {
        w = h = 0;
        var s = raw.Trim().ToLowerInvariant().Replace('×', 'x').Replace(':', 'x');
        return s switch
        {
            "16x9" or "16/9" => Assign(16, 9, out w, out h),
            "9x16" or "9/16" => Assign(9, 16, out w, out h),
            "1x1" or "1/1" or "square" => Assign(1, 1, out w, out h),
            "4x3" or "4/3" => Assign(4, 3, out w, out h),
            "3x4" or "3/4" => Assign(3, 4, out w, out h),
            "21x9" or "21/9" => Assign(21, 9, out w, out h),
            _ => TryParseNumericRatio(s, out w, out h),
        };

        static bool Assign(int aw, int ah, out int ow, out int oh)
        {
            ow = aw;
            oh = ah;
            return true;
        }
    }

    private static bool TryParseNumericRatio(string s, out int w, out int h)
    {
        w = h = 0;
        var parts = s.Split(['x', '/'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (parts.Length != 2) return false;
        if (!double.TryParse(parts[0], out var aw) || !double.TryParse(parts[1], out var ah)) return false;
        if (aw <= 0 || ah <= 0) return false;
        w = Math.Max(1, (int)Math.Round(aw));
        h = Math.Max(1, (int)Math.Round(ah));
        return true;
    }

    private static int Even(int v) => Math.Max(2, v / 2 * 2);
}
