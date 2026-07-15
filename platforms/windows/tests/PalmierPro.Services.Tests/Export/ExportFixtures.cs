using PalmierPro.Core.Export;
using PalmierPro.Core.Json;
using PalmierPro.Core.Models;
using PalmierPro.Services.Export;

namespace PalmierPro.Services.Tests.Export;

/// Shared clip/track/timeline/resolver builders for the FCPXML/XMEML exporter tests. Mirrors
/// Tests/PalmierProTests/Fixtures.swift's clip/videoTrack/audioTrack/timeline helpers, plus each
/// Mac exporter test file's own local makeResolver/videoEntry/audioEntry helpers.
internal static class ExportFixtures
{
    public static Clip Clip(
        string? id = null, string mediaRef = "media-1", ClipType mediaType = ClipType.Video,
        int start = 0, int duration = 30, int trimStart = 0, int trimEnd = 0, double speed = 1.0, double volume = 1.0) =>
        new(mediaRef, start, duration)
        {
            Id = id ?? SwiftId.New(),
            MediaType = mediaType,
            SourceClipType = mediaType,
            TrimStartFrame = trimStart,
            TrimEndFrame = trimEnd,
            Speed = speed,
            Volume = volume,
        };

    public static Track VideoTrack(params Clip[] clips) => new(ClipType.Video, [.. clips]) { Id = SwiftId.New() };

    public static Track AudioTrack(params Clip[] clips) => new(ClipType.Audio, [.. clips]) { Id = SwiftId.New() };

    public static Timeline Timeline(int fps = 30, params Track[] tracks) => new() { Fps = fps, Tracks = [.. tracks] };

    /// Fresh, empty scratch directory — each test gets its own so parallel test runs never collide
    /// on the same media/output filenames (the Mac tests share `NSTemporaryDirectory()` directly,
    /// safe there because XCTest/Swift Testing serialize a target's tests by default).
    public static string NewTempDir()
    {
        var dir = Path.Combine(Path.GetTempPath(), "PalmierProExportTests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        return dir;
    }

    /// A `MediaResolver` over the given entries; every `.External` entry's path is touched as an
    /// empty file so `ResolveUrl` succeeds — the exporters only check existence/metadata, never
    /// contents, same convention as `FCPXMLExporterTests.makeResolver`/`XMLExporterTests.makeResolver`.
    public static MediaResolver ResolverFor(params MediaManifestEntry[] entries)
    {
        foreach (var entry in entries)
        {
            if (entry.Source.Kind == MediaSourceKind.External)
            {
                File.WriteAllBytes(entry.Source.Path, []);
            }
        }
        var manifest = new MediaManifest { Entries = [.. entries] };
        return new MediaResolver(() => manifest, () => null);
    }

    public static MediaManifestEntry VideoEntry(
        string id, string dir, double duration = 5, int sourceWidth = 1920, int sourceHeight = 1080, bool? hasAudio = null) =>
        new(id, id, ClipType.Video, MediaSource.External(Path.Combine(dir, $"{id}.mp4")), duration,
            sourceWidth: sourceWidth, sourceHeight: sourceHeight, hasAudio: hasAudio);

    public static MediaManifestEntry AudioEntry(string id, string dir, double duration = 5) =>
        new(id, id, ClipType.Audio, MediaSource.External(Path.Combine(dir, $"{id}.m4a")), duration);

    public static MediaManifestEntry ImageEntry(string id, string dir, int sourceWidth = 1920, int sourceHeight = 1080) =>
        new(id, id, ClipType.Image, MediaSource.External(Path.Combine(dir, $"{id}.png")), 0,
            sourceWidth: sourceWidth, sourceHeight: sourceHeight);

    public static Clip NestCarrier(Timeline child, int start, int? duration = null, int trimStart = 0) =>
        new(child.Id, start, duration ?? child.TotalFrames)
        {
            Id = SwiftId.New(),
            MediaType = ClipType.Sequence,
            SourceClipType = ClipType.Sequence,
            TrimStartFrame = trimStart,
        };
}

/// Always takes the "no matching installed font" fallback path documented on
/// `IFontTraitResolver.Resolve` — family via hyphen-split, face via the canonical bold/italic
/// string. On the Mac, "Helvetica" happens to have real Regular/Bold faces whose symbolic traits
/// match what's requested, so `FCPXMLExporter`'s own fallback produces byte-identical output for
/// the fixtures ported here; this fake reproduces exactly that observed behavior without touching
/// the system font collection (`DirectWriteFontTraitResolver` is the real implementation).
internal sealed class FakeFontTraitResolver : IFontTraitResolver
{
    public ResolvedFontFace Resolve(string fontName, double fontSize, bool isBold, bool isItalic)
    {
        var dash = fontName.IndexOf('-');
        var family = dash > 0 ? fontName[..dash] : fontName;
        var face = (isBold, isItalic) switch
        {
            (true, true) => "Bold Italic",
            (true, false) => "Bold",
            (false, true) => "Italic",
            (false, false) => "Regular",
        };
        return new ResolvedFontFace(family, face);
    }
}

/// Maps mediaRef straight to a fixed timecode table, ignoring the resolved `urls` argument — a
/// simpler double than `FfprobeSourceTimingReader` (which matches by URL) since exporter tests only
/// need to control "this mediaRef has embedded timecode X", never touch a process.
internal sealed class FakeSourceTimingReader(IReadOnlyDictionary<string, SourceTimecode> byMediaRef) : ISourceTimingReader
{
    public Task<Dictionary<string, SourceTimecode>> TimecodesAsync(
        IReadOnlyCollection<string> mediaRefs, IReadOnlyDictionary<string, string> urls)
    {
        var result = new Dictionary<string, SourceTimecode>();
        foreach (var mediaRef in mediaRefs)
        {
            if (byMediaRef.TryGetValue(mediaRef, out var tc))
            {
                result[mediaRef] = tc;
            }
        }
        return Task.FromResult(result);
    }
}
