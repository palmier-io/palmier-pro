using System.Text.Json;
using PalmierPro.Core.Json;
using PalmierPro.Core.Models;

namespace PalmierPro.Services.Engine;

// ===== Snapshot model — see docs/timeline-snapshot-v1.md for the normative schema =====

public sealed class TimelineSnapshot
{
    public int Version { get; init; } = TimelineSnapshotBuilder.SchemaVersion;
    public int FpsNumerator { get; init; }
    public int FpsDenominator { get; init; } = 1;
    public int OutputWidth { get; init; }
    public int OutputHeight { get; init; }
    public List<SnapshotTrack> Tracks { get; init; } = [];
}

public sealed class SnapshotTrack
{
    public required string Id { get; init; }
    /// "video" | "audio" — the only two Track.Type values that occur (see schema doc §3).
    public ClipType Type { get; init; }
    /// Audio tracks only; meaningless for a video-type track (always false).
    public bool Muted { get; init; }
    public List<SnapshotClip> Clips { get; init; } = [];
}

public sealed class SnapshotClip
{
    public required string Id { get; init; }
    /// "video" | "audio" | "image" — never text/lottie/sequence (schema doc §6).
    public ClipType Type { get; init; }
    public int StartFrame { get; init; }
    public int DurationFrames { get; init; }
    public int TrimStartFrame { get; init; }
    public double Speed { get; init; } = 1.0;
    /// Absolute, pre-resolved. The engine never sees an asset ref.
    public required string MediaPath { get; init; }
    /// Coarse, non-authoritative — see schema doc §5.
    public bool? HasAlphaHint { get; init; }
    /// Null means "normal" (matches Swift's `Clip.blendMode == nil`).
    public BlendMode? BlendMode { get; init; }
    public double Opacity { get; init; } = 1.0;
    public Transform Transform { get; init; } = new();
    public Crop Crop { get; init; } = new();
    public double VolumeGain { get; init; } = 1.0;
    public int FadeInFrames { get; init; }
    public int FadeOutFrames { get; init; }
    public Interpolation FadeInInterpolation { get; init; } = Interpolation.Linear;
    public Interpolation FadeOutInterpolation { get; init; } = Interpolation.Linear;
}

public sealed record TimelineSnapshotBuildResult(TimelineSnapshot Snapshot, IReadOnlySet<string> OfflineMediaRefs);

// ===== Builder =====

/// Builds the v1 engine snapshot from (ProjectFile, timelineId, MediaResolver): flattens nested
/// `.sequence` clips (via <see cref="NestFlattener"/>), resolves every media ref to an absolute
/// path, and hands the result to <see cref="TimelineSnapshotSerializer"/> for deterministic JSON.
/// See docs/timeline-snapshot-v1.md for the schema this produces and the rationale behind every
/// non-obvious decision below (track ordering, nest splicing, volume folding, multicam, media
/// status split).
public static class TimelineSnapshotBuilder
{
    public const int SchemaVersion = 1;

    public static TimelineSnapshotBuildResult Build(ProjectFile project, string timelineId, MediaResolver mediaResolver)
    {
        ArgumentNullException.ThrowIfNull(project);
        ArgumentNullException.ThrowIfNull(mediaResolver);
        var timeline = project.Timelines.FirstOrDefault(t => t.Id == timelineId)
            ?? throw new ArgumentException($"Timeline '{timelineId}' not found in project.", nameof(timelineId));

        var timelinesById = new Dictionary<string, Timeline>();
        foreach (var t in project.Timelines)
        {
            timelinesById[t.Id] = t;
        }
        var ctx = new BuildContext(mediaResolver, timelinesById);

        // §2: output tracks are appended in an order that already satisfies "index 0 paints
        // first/bottom, last index paints last/top" — the reverse of Timeline.Tracks' own
        // index-0-is-top convention. Walking Timeline.Tracks from its LAST index to its FIRST and
        // appending each lane produces exactly that.
        var tracks = new List<SnapshotTrack>();
        for (int i = timeline.Tracks.Count - 1; i >= 0; i--)
        {
            var track = timeline.Tracks[i];
            bool isAudio = track.Type == ClipType.Audio;
            if (!isAudio && track.Hidden)
            {
                continue; // a hidden visual track's clips (incl. any nested sequence clips) never render
            }

            if (isAudio)
            {
                EmitAudioLane(track.Clips, track.Id, outerMuted: track.Muted, volumeScale: 1.0, depth: 0, ctx, tracks);
            }
            else
            {
                EmitVideoLane(track.Clips, track.Id, depth: 0, ctx, tracks);
            }
        }

        var snapshot = new TimelineSnapshot
        {
            Version = SchemaVersion,
            FpsNumerator = timeline.Fps,
            FpsDenominator = 1,
            OutputWidth = timeline.Width,
            OutputHeight = timeline.Height,
            Tracks = tracks,
        };
        return new TimelineSnapshotBuildResult(snapshot, ctx.OfflineMediaRefs);
    }

    /// §6: text/lottie are filtered structurally. Applied inside `EmitVideoLane`/`EmitAudioLane`
    /// themselves (not by their callers) so every entry point — the top-level per-track loop in
    /// `Build`, AND every recursive nested-sub-track call from `ExpandNestVideo`/`ExpandNestAudio`
    /// — filters identically. A nested child timeline's own track can carry text/lottie clips too;
    /// filtering only at the top level would leak them through when nested.
    private static List<Clip> RenderableClips(IEnumerable<Clip> clips) =>
        clips.Where(c => c.MediaType is not (ClipType.Text or ClipType.Lottie))
             .OrderBy(c => c.StartFrame)
             .ToList();

    private sealed class BuildContext(MediaResolver mediaResolver, Dictionary<string, Timeline> timelinesById)
    {
        public MediaResolver MediaResolver { get; } = mediaResolver;
        public Dictionary<string, Timeline> TimelinesById { get; } = timelinesById;
        public HashSet<string> OfflineMediaRefs { get; } = [];
    }

    // ----- Video -----

    private static void EmitVideoLane(IEnumerable<Clip> rawClips, string ownTrackId, int depth, BuildContext ctx, List<SnapshotTrack> output)
    {
        var ownClips = new List<SnapshotClip>();
        int previousEndFrame = int.MinValue;
        foreach (var clip in RenderableClips(rawClips))
        {
            if (clip.DurationFrames <= 0 || clip.StartFrame < previousEndFrame)
            {
                continue; // out-of-order/overlapping clip — matches CompositionBuilder's previousEndFrame guard
            }

            // Video nesting gates on MediaType (mirrors CompositionBuilder.insertVideoLane's
            // `clip.mediaType == .sequence` — contrast with EmitAudioLane, which gates on
            // SourceClipType instead).
            if (clip.MediaType == ClipType.Sequence)
            {
                // previousEndFrame advances unconditionally for a sequence carrier, matching
                // CompositionBuilder.insertVideoLane (it always expands/consumes the carrier's span).
                previousEndFrame = clip.EndFrame;
                ExpandNestVideo(clip, depth, ctx, output);
                continue;
            }
            // previousEndFrame advances ONLY on a successfully-resolved clip — an offline/unprocessable
            // clip must not consume its span, matching CompositionBuilder.insertVideoLane (which advances
            // only inside `if insertClip(...)`). This differs from EmitAudioLane, which advances
            // unconditionally — CompositionBuilder.insertAudioLane does the same asymmetrically.
            if (TryResolveClip(clip, ctx, volumeScale: 1.0, out var snapshotClip))
            {
                previousEndFrame = clip.EndFrame;
                ownClips.Add(snapshotClip);
            }
        }
        if (ownClips.Count > 0)
        {
            output.Add(new SnapshotTrack { Id = ownTrackId, Type = ClipType.Video, Muted = false, Clips = ownClips });
        }
    }

    private static void ExpandNestVideo(Clip carrier, int depth, BuildContext ctx, List<SnapshotTrack> output)
    {
        if (depth >= NestFlattener.MaxDepth)
        {
            return; // recursion guard — mirrors NestFlattener.maxDepth / CompositionBuilder's depth check
        }
        if (!ctx.TimelinesById.TryGetValue(carrier.MediaRef, out var child))
        {
            ctx.OfflineMediaRefs.Add(carrier.MediaRef);
            return;
        }
        var flat = NestFlattener.Flatten(carrier, child, visual: true);
        // §2: recurse the SAME "process last-index-first" convention as the top-level loop in
        // Build(), so flat.VideoTracks[0] (the child's own topmost/frontmost sub-track, per
        // NestFlattener/Flatten preserving child.Tracks' index-0-is-top order) ends up LAST in
        // `output` — i.e. painted last/frontmost — exactly like a non-nested topmost track would.
        for (int i = flat.VideoTracks.Count - 1; i >= 0; i--)
        {
            EmitVideoLane(flat.VideoTracks[i], $"{carrier.Id}#v{i}", depth + 1, ctx, output);
        }
    }

    // ----- Audio -----

    private static void EmitAudioLane(
        IEnumerable<Clip> rawClips, string ownTrackId, bool outerMuted, double volumeScale, int depth, BuildContext ctx, List<SnapshotTrack> output)
    {
        var ownClips = new List<SnapshotClip>();
        int previousEndFrame = int.MinValue;
        foreach (var clip in RenderableClips(rawClips))
        {
            if (clip.DurationFrames <= 0 || clip.StartFrame < previousEndFrame)
            {
                continue;
            }
            previousEndFrame = clip.EndFrame;

            // Audio nesting is gated on SourceClipType, not MediaType — a nest's audio typically
            // reaches an audio-type track only as a "detached audio" derived clip (MediaType has
            // become .Audio; SourceClipType still remembers .Sequence). Mirrors
            // CompositionBuilder.insertAudioLane's `clip.sourceClipType == .sequence` check exactly
            // (the video lane, by contrast, gates on MediaType — see EmitVideoLane).
            if (clip.SourceClipType == ClipType.Sequence)
            {
                // §4: fold this carrier's own static Volume into the accumulated scale before recursing.
                ExpandNestAudio(clip, outerMuted, volumeScale * clip.Volume, depth, ctx, output);
                continue;
            }
            if (TryResolveClip(clip, ctx, volumeScale, out var snapshotClip))
            {
                ownClips.Add(snapshotClip);
            }
        }
        if (ownClips.Count > 0)
        {
            output.Add(new SnapshotTrack { Id = ownTrackId, Type = ClipType.Audio, Muted = outerMuted, Clips = ownClips });
        }
    }

    private static void ExpandNestAudio(Clip carrier, bool outerMuted, double volumeScale, int depth, BuildContext ctx, List<SnapshotTrack> output)
    {
        if (depth >= NestFlattener.MaxDepth)
        {
            return;
        }
        if (!ctx.TimelinesById.TryGetValue(carrier.MediaRef, out var child))
        {
            ctx.OfflineMediaRefs.Add(carrier.MediaRef);
            return;
        }
        var flat = NestFlattener.Flatten(carrier, child, visual: false);
        // Order is inaudible for a pure additive gain mix, but reversed to match EmitVideoLane's
        // convention exactly (deterministic, and one fewer thing to explain differently per lane kind).
        for (int i = flat.AudioTracks.Count - 1; i >= 0; i--)
        {
            // outerMuted threads through unchanged at every depth — mirrors CompositionBuilder's
            // buildVisuals(), which keys the mute check off the ORIGINAL top-level parentTrackIndex
            // regardless of nesting depth.
            EmitAudioLane(flat.AudioTracks[i], $"{carrier.Id}#a{i}", outerMuted, volumeScale, depth + 1, ctx, output);
        }
    }

    // ----- Leaf clip resolution -----

    private static bool TryResolveClip(Clip clip, BuildContext ctx, double volumeScale, out SnapshotClip snapshotClip)
    {
        var mediaPath = ctx.MediaResolver.ResolveUrl(clip.MediaRef);
        if (mediaPath is null)
        {
            ctx.OfflineMediaRefs.Add(clip.MediaRef);
            snapshotClip = null!;
            return false;
        }
        snapshotClip = new SnapshotClip
        {
            Id = clip.Id,
            Type = clip.MediaType,
            StartFrame = clip.StartFrame,
            DurationFrames = clip.DurationFrames,
            TrimStartFrame = clip.TrimStartFrame,
            Speed = clip.Speed,
            MediaPath = mediaPath,
            HasAlphaHint = AlphaHint.Compute(clip, mediaPath),
            BlendMode = clip.BlendMode,
            Opacity = clip.Opacity,
            Transform = clip.Transform,
            Crop = clip.Crop,
            VolumeGain = clip.Volume * volumeScale,
            FadeInFrames = clip.FadeInFrames,
            FadeOutFrames = clip.FadeOutFrames,
            FadeInInterpolation = clip.FadeInInterpolation,
            FadeOutInterpolation = clip.FadeOutInterpolation,
        };
        return true;
    }
}

/// Coarse, extension-based `hasAlphaHint` — see docs/timeline-snapshot-v1.md §5. Never authoritative.
internal static class AlphaHint
{
    private static readonly HashSet<string> AlphaCapable = new(StringComparer.OrdinalIgnoreCase) { ".png", ".webp", ".tiff" };
    private static readonly HashSet<string> NeverAlpha = new(StringComparer.OrdinalIgnoreCase) { ".jpg", ".jpeg" };

    public static bool? Compute(Clip clip, string mediaPath)
    {
        if (clip.MediaType != ClipType.Image)
        {
            return null; // video/audio alpha is determined authoritatively by the engine from the codec
        }
        var ext = Path.GetExtension(mediaPath);
        if (AlphaCapable.Contains(ext))
        {
            return true;
        }
        if (NeverAlpha.Contains(ext))
        {
            return false;
        }
        return null; // e.g. .heic — ambiguous without pixel inspection
    }
}

// ===== Deterministic serializer =====

/// Writes a `TimelineSnapshot` as deterministic UTF-8 JSON: every object uses a fixed,
/// hand-written key order (no `JsonSerializer` reflection, no dictionary iteration anywhere in
/// this schema) so identical input always produces byte-identical output. See
/// docs/timeline-snapshot-v1.md §9.
public static class TimelineSnapshotSerializer
{
    private static readonly JsonWriterOptions WriterOptions = new() { Indented = true };

    public static byte[] ToJsonBytes(TimelineSnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, WriterOptions))
        {
            WriteSnapshot(writer, snapshot);
        }
        return stream.ToArray();
    }

    private static void WriteSnapshot(Utf8JsonWriter w, TimelineSnapshot s)
    {
        w.WriteStartObject();
        w.WriteNumber("version", s.Version);
        w.WriteStartObject("fps");
        w.WriteNumber("numerator", s.FpsNumerator);
        w.WriteNumber("denominator", s.FpsDenominator);
        w.WriteEndObject();
        w.WriteNumber("outputWidth", s.OutputWidth);
        w.WriteNumber("outputHeight", s.OutputHeight);
        w.WriteStartArray("tracks");
        foreach (var t in s.Tracks)
        {
            WriteTrack(w, t);
        }
        w.WriteEndArray();
        w.WriteEndObject();
    }

    private static void WriteTrack(Utf8JsonWriter w, SnapshotTrack t)
    {
        w.WriteStartObject();
        w.WriteString("id", t.Id);
        w.WriteString("type", SwiftStringEnumConverter<ClipType>.RawValue(t.Type));
        w.WriteBoolean("muted", t.Muted);
        w.WriteStartArray("clips");
        foreach (var c in t.Clips)
        {
            WriteClip(w, c);
        }
        w.WriteEndArray();
        w.WriteEndObject();
    }

    private static void WriteClip(Utf8JsonWriter w, SnapshotClip c)
    {
        w.WriteStartObject();
        w.WriteString("id", c.Id);
        w.WriteString("type", SwiftStringEnumConverter<ClipType>.RawValue(c.Type));
        w.WriteNumber("startFrame", c.StartFrame);
        w.WriteNumber("durationFrames", c.DurationFrames);
        w.WriteNumber("trimStartFrame", c.TrimStartFrame);
        w.WriteNumber("speed", c.Speed);
        w.WriteString("mediaPath", c.MediaPath);
        WriteNullableBool(w, "hasAlphaHint", c.HasAlphaHint);
        if (c.BlendMode is { } blendMode)
        {
            w.WriteString("blendMode", SwiftStringEnumConverter<BlendMode>.RawValue(blendMode));
        }
        else
        {
            w.WriteNull("blendMode");
        }

        w.WriteStartObject("opacity");
        w.WriteNumber("value", c.Opacity);
        w.WriteNull("keyframes");
        w.WriteEndObject();

        w.WriteStartObject("transform");
        w.WriteStartObject("value");
        w.WriteNumber("centerX", c.Transform.CenterX);
        w.WriteNumber("centerY", c.Transform.CenterY);
        w.WriteNumber("width", c.Transform.Width);
        w.WriteNumber("height", c.Transform.Height);
        w.WriteNumber("rotation", c.Transform.Rotation);
        w.WriteBoolean("flipHorizontal", c.Transform.FlipHorizontal);
        w.WriteBoolean("flipVertical", c.Transform.FlipVertical);
        w.WriteEndObject();
        w.WriteNull("keyframes");
        w.WriteEndObject();

        w.WriteStartObject("crop");
        w.WriteStartObject("value");
        w.WriteNumber("left", c.Crop.Left);
        w.WriteNumber("top", c.Crop.Top);
        w.WriteNumber("right", c.Crop.Right);
        w.WriteNumber("bottom", c.Crop.Bottom);
        w.WriteEndObject();
        w.WriteNull("keyframes");
        w.WriteEndObject();

        w.WriteStartObject("volume");
        w.WriteNumber("gain", c.VolumeGain);
        w.WriteNumber("fadeInFrames", c.FadeInFrames);
        w.WriteNumber("fadeOutFrames", c.FadeOutFrames);
        w.WriteString("fadeInInterpolation", SwiftStringEnumConverter<Interpolation>.RawValue(c.FadeInInterpolation));
        w.WriteString("fadeOutInterpolation", SwiftStringEnumConverter<Interpolation>.RawValue(c.FadeOutInterpolation));
        w.WriteNull("keyframes");
        w.WriteEndObject();

        w.WriteEndObject();
    }

    private static void WriteNullableBool(Utf8JsonWriter w, string name, bool? value)
    {
        if (value is { } v)
        {
            w.WriteBoolean(name, v);
        }
        else
        {
            w.WriteNull(name);
        }
    }
}
