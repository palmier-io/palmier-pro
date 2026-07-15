using PalmierPro.App.ViewModels.Editor;
using PalmierPro.Core.Json;
using PalmierPro.Core.Models;
using PalmierPro.Services.Project;

namespace PalmierPro.App.Tests.ViewModels.Editor;

/// Builders mirroring Tests/PalmierProTests/Fixtures.swift, plus the async
/// `ProjectDocument`-backed setup every `TimelineEditorViewModel` test needs (there is no
/// lightweight in-memory `ProjectDocument` constructor — it owns real package I/O, same as
/// `ProjectDocumentTests`/`MenuCommandMatrixTests` already accept).
internal static class EditorFixtures
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
        var c = new Clip(mediaRef, start, duration)
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

    public static Timeline Timeline(int fps = 30, List<Track>? tracks = null) =>
        new() { Fps = fps, Tracks = tracks ?? [] };

    /// Fresh `TimelineEditorViewModel` over a throwaway on-disk project. Caller must dispose the
    /// returned `TempDirectory`.
    public static async Task<(TimelineEditorViewModel Vm, TempDirectory Temp)> MakeAsync(List<Track>? tracks = null)
    {
        var temp = new TempDirectory();
        var doc = await ProjectDocument.CreateNewAsync(temp.Path, "Editor Fixture");
        var vm = new TimelineEditorViewModel(doc);
        if (tracks is not null)
        {
            vm.Timeline = Timeline(tracks: tracks);
        }
        return (vm, temp);
    }
}
