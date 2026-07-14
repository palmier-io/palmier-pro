using PalmierPro.Core.Json;
using PalmierPro.Core.Models;

namespace PalmierPro.Core.Tests;

/// Mirrors Tests/PalmierProTests/Fixtures.swift.
public static class Fixtures
{
    public static Clip Clip(
        string id = "",
        string mediaRef = "media-1",
        ClipType mediaType = ClipType.Video,
        int start = 0,
        int duration = 0,
        int trimStart = 0,
        int trimEnd = 0,
        double speed = 1.0,
        double volume = 1.0)
    {
        var c = new Models.Clip(mediaRef, start, duration)
        {
            Id = id.Length == 0 ? SwiftId.New() : id,
            MediaType = mediaType,
            SourceClipType = mediaType,
            TrimStartFrame = trimStart,
            TrimEndFrame = trimEnd,
            Speed = speed,
            Volume = volume,
        };
        return c;
    }

    public static Track VideoTrack(string? id = null, List<Clip>? clips = null) =>
        new(ClipType.Video, clips ?? []) { Id = id ?? SwiftId.New() };

    public static Track AudioTrack(string? id = null, List<Clip>? clips = null) =>
        new(ClipType.Audio, clips ?? []) { Id = id ?? SwiftId.New() };

    public static Models.Timeline Timeline(int fps = 30, List<Track>? tracks = null) =>
        new() { Fps = fps, Tracks = tracks ?? [] };
}
