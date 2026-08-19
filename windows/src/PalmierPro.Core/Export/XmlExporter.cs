using System.Globalization;
using System.Xml.Linq;
using PalmierPro.Core.Models;
using PalmierPro.Core.Playback;

namespace PalmierPro.Core.Export;

/// <summary>
/// Minimal XMEML 4 export for Premiere (clip placement, speed, volume). Omits text,
/// effects, and edge styling — matching Mac XMLExporter coverage intent.
/// </summary>
public static class XmlExporter
{
    public static void Write(Timeline timeline, string destinationPath, string projectName)
    {
        var fps = Math.Max(1, timeline.Fps);
        var duration = TimelineFrameRouter.DurationFrames(timeline);

        var sequence = new XElement("sequence",
            new XElement("name", projectName),
            new XElement("duration", duration),
            new XElement("rate",
                new XElement("timebase", fps),
                new XElement("ntsc", "FALSE")),
            new XElement("media",
                new XElement("video", BuildVideoTracks(timeline)),
                new XElement("audio", BuildAudioTracks(timeline))));

        var doc = new XDocument(
            new XDeclaration("1.0", "UTF-8", null),
            new XElement("xmeml", new XAttribute("version", "4"), sequence));

        Directory.CreateDirectory(Path.GetDirectoryName(destinationPath)!);
        var staging = destinationPath + $".{Guid.NewGuid():N}.partial";
        doc.Save(staging);
        File.Move(staging, destinationPath, overwrite: true);
    }

    private static IEnumerable<XElement> BuildVideoTracks(Timeline timeline)
    {
        foreach (var track in timeline.Tracks.Where(t => t.Type != ClipType.Audio))
        {
            var clipItems = track.Clips
                .Where(c => c.MediaType != ClipType.Audio)
                .Select(c => ClipItem(c, timeline.Fps));
            yield return new XElement("track", clipItems);
        }
    }

    private static IEnumerable<XElement> BuildAudioTracks(Timeline timeline)
    {
        foreach (var track in timeline.Tracks.Where(t => t.Type == ClipType.Audio || t.Clips.Any(c => c.MediaType == ClipType.Audio)))
        {
            var clipItems = track.Clips
                .Where(c => c.MediaType == ClipType.Audio || c.MediaType == ClipType.Video)
                .Select(c => ClipItem(c, timeline.Fps, audio: true));
            yield return new XElement("track", clipItems);
        }
    }

    private static XElement ClipItem(Clip clip, int fps, bool audio = false)
    {
        var speed = clip.Speed <= 0 ? 1 : clip.Speed;
        var inPoint = clip.TrimStartFrame;
        var outPoint = clip.TrimStartFrame + clip.SourceFramesConsumed;
        return new XElement("clipitem",
            new XAttribute("id", clip.Id),
            new XElement("name", clip.MediaRef),
            new XElement("enabled", "TRUE"),
            new XElement("duration", clip.DurationFrames),
            new XElement("rate",
                new XElement("timebase", fps),
                new XElement("ntsc", "FALSE")),
            new XElement("start", clip.StartFrame),
            new XElement("end", clip.EndFrame),
            new XElement("in", inPoint),
            new XElement("out", outPoint),
            new XElement("file", new XAttribute("id", "file-" + clip.MediaRef),
                new XElement("name", clip.MediaRef)),
            Math.Abs(speed - 1) > 1e-6
                ? new XElement("filter",
                    new XElement("effect",
                        new XElement("name", "Time Remap"),
                        new XElement("effectid", "timeremap"),
                        new XElement("parameter",
                            new XElement("name", "speed"),
                            new XElement("value", speed.ToString(CultureInfo.InvariantCulture)))))
                : null,
            audio
                ? new XElement("filter",
                    new XElement("effect",
                        new XElement("name", "Audio Levels"),
                        new XElement("effectid", "audiolevels"),
                        new XElement("parameter",
                            new XElement("name", "level"),
                            new XElement("value",
                                clip.Volume.ToString(CultureInfo.InvariantCulture)))))
                : null);
    }
}
