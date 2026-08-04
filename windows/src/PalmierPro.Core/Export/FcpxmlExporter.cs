using System.Xml.Linq;
using PalmierPro.Core.Models;
using PalmierPro.Core.Playback;

namespace PalmierPro.Core.Export;

/// <summary>Minimal FCPXML 1.10 export for Resolve/FCP placement interchange.</summary>
public static class FcpxmlExporter
{
    public static void Write(Timeline timeline, string destinationPath, string projectName)
    {
        var fps = Math.Max(1, timeline.Fps);
        var duration = TimelineFrameRouter.DurationFrames(timeline);
        var frameDuration = $"1/{fps}s";

        var resources = new XElement("resources",
            new XElement("format",
                new XAttribute("id", "r1"),
                new XAttribute("name", $"FFVideoFormat{timeline.Height}p{fps}"),
                new XAttribute("frameDuration", frameDuration),
                new XAttribute("width", timeline.Width),
                new XAttribute("height", timeline.Height)));

        var assetIds = new Dictionary<string, string>();
        var next = 2;
        foreach (var mediaRef in timeline.Tracks.SelectMany(t => t.Clips).Select(c => c.MediaRef).Distinct())
        {
            var id = $"r{next++}";
            assetIds[mediaRef] = id;
            resources.Add(new XElement("asset",
                new XAttribute("id", id),
                new XAttribute("name", mediaRef),
                new XAttribute("hasVideo", "1"),
                new XAttribute("hasAudio", "1"),
                new XAttribute("format", "r1")));
        }

        var spine = new XElement("spine");
        foreach (var clip in timeline.Tracks
            .Where(t => t.Type != ClipType.Audio)
            .SelectMany(t => t.Clips)
            .Where(c => c.MediaType != ClipType.Audio)
            .OrderBy(c => c.StartFrame))
        {
            if (!assetIds.TryGetValue(clip.MediaRef, out var assetId)) continue;
            spine.Add(new XElement("asset-clip",
                new XAttribute("ref", assetId),
                new XAttribute("name", clip.MediaRef),
                new XAttribute("offset", FramesToTime(clip.StartFrame, fps)),
                new XAttribute("duration", FramesToTime(clip.DurationFrames, fps)),
                new XAttribute("start", FramesToTime(clip.TrimStartFrame, fps))));
        }

        var doc = new XDocument(
            new XDeclaration("1.0", "UTF-8", null),
            new XElement("fcpxml", new XAttribute("version", "1.10"),
                resources,
                new XElement("library",
                    new XElement("event", new XAttribute("name", projectName),
                        new XElement("project", new XAttribute("name", projectName),
                            new XElement("sequence",
                                new XAttribute("format", "r1"),
                                new XAttribute("duration", FramesToTime(duration, fps)),
                                spine))))));

        Directory.CreateDirectory(Path.GetDirectoryName(destinationPath)!);
        var staging = destinationPath + $".{Guid.NewGuid():N}.partial";
        doc.Save(staging);
        File.Move(staging, destinationPath, overwrite: true);
    }

    private static string FramesToTime(int frames, int fps)
        => $"{frames}/{fps}s";
}
