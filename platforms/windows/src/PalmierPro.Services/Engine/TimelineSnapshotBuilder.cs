using System.Text.Json;
using PalmierPro.Core.Json;
using PalmierPro.Core.Models;
using PalmierPro.Services.Media;

namespace PalmierPro.Services.Engine;

// ===== Snapshot model — see docs/timeline-snapshot-v1.md for the normative schema =====

public sealed class TimelineSnapshot
{
    public int Version { get; init; } = TimelineSnapshotBuilder.SchemaVersion;
    public int MinorVersion { get; init; } = TimelineSnapshotBuilder.SchemaMinorVersion;
    public int FpsNumerator { get; init; }
    public int FpsDenominator { get; init; } = 1;
    public int OutputWidth { get; init; }
    public int OutputHeight { get; init; }
    public List<SnapshotTrack> Tracks { get; init; } = [];
}

/// One `{ frame, value, interpolation }` entry of a v1.1 keyframe envelope — see
/// docs/timeline-snapshot-v1.md §11. `Frame` is clip-relative (matches Core's KeyframeTrack
/// storage convention — Keyframe.swift's `toOffset`).
public sealed record SnapshotKeyframe<T>(int Frame, T Value, Interpolation Interpolation);

/// One entry of a v1.1 SnapshotClip's ordered `effects` list — mirrors Core's `Effect` verbatim.
public sealed record SnapshotEffect(string Type, bool Enabled, Dictionary<string, EffectParam> Params);

public sealed class SnapshotTrack
{
    public required string Id { get; init; }
    /// "video" | "audio" — the only two Track.Type values that occur (see schema doc §3).
    public ClipType Type { get; init; }
    /// Audio tracks only; meaningless for a video-type track (always false).
    public bool Muted { get; init; }
    public List<SnapshotClip> Clips { get; init; } = [];
    /// v1.2 (docs/timeline-snapshot-v1.md §12) — text clips originally on this track (or, for a
    /// nest-spliced synthetic track, text clips from that flattened sub-track). Always empty for
    /// an audio-type track (text is never audio-compatible). Omitted from the wire format when
    /// empty — see TimelineSnapshotSerializer.
    public List<SnapshotTextClip> TextClips { get; init; } = [];
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

    // v1.1 (docs/timeline-snapshot-v1.md §11) — null/empty means "static", matching v1.
    public List<SnapshotKeyframe<double>>? OpacityKeyframes { get; init; }
    public List<SnapshotKeyframe<Crop>>? CropKeyframes { get; init; }
    public List<SnapshotKeyframe<Transform>>? TransformKeyframes { get; init; }
    /// dB keyframe track (docs/timeline-snapshot-v1.md §5 addendum) — Clip.VolumeTrack, dB values,
    /// clip-relative frames. Serialized inside the `volume` object. Consumed only by the audio mixer
    /// (E4.5); null/empty means static (unity keyframe gain).
    public List<SnapshotKeyframe<double>>? VolumeKeyframes { get; init; }
    public List<SnapshotEffect> Effects { get; init; } = [];
}

/// v1.2 (docs/timeline-snapshot-v1.md §12) — a text clip's own entry, carried on the
/// `SnapshotTrack` it originated from rather than inside `SnapshotTrack.Clips` (it has no
/// `mediaPath`; it isn't decoded media). Mirrors exactly what `Compositing/TextFrameRenderer.swift`
/// + `TextAnimator.swift` actually read off a `.text` `Clip` — no `crop`, no `volume`/fades: the
/// Mac's `composedTextLayer` never consults them for text.
public sealed class SnapshotTextClip
{
    public required string Id { get; init; }
    public int StartFrame { get; init; }
    public int DurationFrames { get; init; }
    public required string Content { get; init; }
    public double Opacity { get; init; } = 1.0;
    public List<SnapshotKeyframe<double>>? OpacityKeyframes { get; init; }
    /// Null means "normal" — same convention as SnapshotClip.BlendMode.
    public BlendMode? BlendMode { get; init; }
    /// The text box: position/anchor AND word-wrap width in one — TextFrameRenderer.boxRect derives
    /// both the placement rect and the CoreText wrap width from this same Transform. Always static:
    /// TextFrameRenderer reads `clip.transform` directly, never `transformAt(frame:)`, so a text
    /// clip's position/scale/rotation keyframe tracks (if any) have no observable render effect on
    /// the Mac — unlike SnapshotClip.Transform, this carries no keyframe envelope.
    public Transform Transform { get; init; } = new();
    public required TextStyle Style { get; init; }
    public required TextAnimation Animation { get; init; }
    /// Clip-relative frames (WordTiming.swift's own convention). Null/empty when the clip has none.
    public List<WordTiming>? WordTimings { get; init; }
    public List<SnapshotEffect> Effects { get; init; } = [];
}

/// `PendingLottieBakes` (docs/lottie-bake-v1.md §10, additive over v1.2) — Lottie clip MediaRefs
/// skipped this build because their bake hasn't completed yet (in flight, or just kicked off).
/// Deliberately separate from <see cref="OfflineMediaRefs"/>: a pending bake is a known, tracked
/// gap, never a missing/corrupt-file error.
public sealed record TimelineSnapshotBuildResult(TimelineSnapshot Snapshot, IReadOnlySet<string> OfflineMediaRefs, IReadOnlySet<string> PendingLottieBakes);

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
    /// v1.2 (docs/timeline-snapshot-v1.md §12, additive over v1.1's §11): text clips now enter the
    /// snapshot via each SnapshotTrack's `textClips` list. Native accepts an absent/unrecognized
    /// `minorVersion` as "no keyframes/effects/text" and never rejects on this field.
    public const int SchemaMinorVersion = 2;

    /// `lottieBakeService` is optional (docs/lottie-bake-v1.md §10) — absent, every Lottie clip is
    /// reported via <see cref="TimelineSnapshotBuildResult.PendingLottieBakes"/> without ever
    /// attempting a bake (a caller not yet wired up to a real service, e.g. most existing tests,
    /// gets the same "always pending" behavior the pre-E4.7 skip already had).
    public static TimelineSnapshotBuildResult Build(ProjectFile project, string timelineId, MediaResolver mediaResolver, ILottieBakeService? lottieBakeService = null)
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
        var ctx = new BuildContext(mediaResolver, timelinesById, lottieBakeService, timeline.Width, timeline.Height);

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
        return new TimelineSnapshotBuildResult(snapshot, ctx.OfflineMediaRefs, ctx.PendingLottieBakes);
    }

    /// Audio-lane-only as of v1.2 (§12) — EmitVideoLane now inlines its own Text/Lottie branch (see
    /// above) so a text clip can land on the right SnapshotTrack instead of being dropped. Text and
    /// Lottie are both ClipType.IsVisual, so neither can legitimately sit on an audio-type track,
    /// but a malformed/legacy project could still have one there; EmitAudioLane keeps filtering
    /// defensively, at both the top-level per-track loop AND every recursive nested-sub-track call
    /// from ExpandNestAudio.
    private static List<Clip> RenderableClips(IEnumerable<Clip> clips) =>
        clips.Where(c => c.MediaType is not (ClipType.Text or ClipType.Lottie))
             .OrderBy(c => c.StartFrame)
             .ToList();

    private sealed class BuildContext(MediaResolver mediaResolver, Dictionary<string, Timeline> timelinesById, ILottieBakeService? lottieBakeService, int outputWidth, int outputHeight)
    {
        public MediaResolver MediaResolver { get; } = mediaResolver;
        public Dictionary<string, Timeline> TimelinesById { get; } = timelinesById;
        public HashSet<string> OfflineMediaRefs { get; } = [];
        public HashSet<string> PendingLottieBakes { get; } = [];
        public ILottieBakeService? LottieBakeService { get; } = lottieBakeService;
        public int OutputWidth { get; } = outputWidth;
        public int OutputHeight { get; } = outputHeight;
    }

    // ----- Video -----

    private static void EmitVideoLane(IEnumerable<Clip> rawClips, string ownTrackId, int depth, BuildContext ctx, List<SnapshotTrack> output)
    {
        var ownClips = new List<SnapshotClip>();
        var ownTextClips = new List<SnapshotTextClip>();
        int previousEndFrame = int.MinValue;
        foreach (var clip in rawClips.OrderBy(c => c.StartFrame))
        {
            // §12 (v1.2): a text clip is never part of the video-track composition invariant below
            // — it renders through its own Direct2D/DirectWrite path (mirrors the Mac's separate
            // `.text` compositing branch in `compositorInstructions`, which likewise never advances
            // `prevEndFrame`). Collected onto THIS track's `textClips` rather than `ownClips` so it
            // inherits this track's paint-order position (§2) without a new ordering scheme. An
            // empty-content text clip is dropped — matches CompositionBuilder's
            // `guard !(clip.textContent ?? "").isEmpty else { continue }`.
            if (clip.MediaType == ClipType.Text)
            {
                if (!string.IsNullOrEmpty(clip.TextContent))
                {
                    ownTextClips.Add(BuildTextClip(clip));
                }
                continue;
            }
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
            // unconditionally — CompositionBuilder.insertAudioLane does the same asymmetrically. A
            // pending (not-yet-baked) Lottie clip is "unresolved" in exactly this same sense — see
            // TryResolveLottieClip (doc §10).
            SnapshotClip snapshotClip;
            bool resolved = clip.MediaType == ClipType.Lottie
                ? TryResolveLottieClip(clip, ctx, out snapshotClip)
                : TryResolveClip(clip, ctx, volumeScale: 1.0, out snapshotClip);
            if (resolved)
            {
                previousEndFrame = clip.EndFrame;
                ownClips.Add(snapshotClip);
            }
        }
        if (ownClips.Count > 0 || ownTextClips.Count > 0)
        {
            output.Add(new SnapshotTrack { Id = ownTrackId, Type = ClipType.Video, Muted = false, Clips = ownClips, TextClips = ownTextClips });
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
        snapshotClip = BuildSnapshotClip(clip, mediaPath, volumeScale, clip.MediaType);
        return true;
    }

    /// Shared by <see cref="TryResolveClip"/> (ordinary video/audio/image clips, `type` = the clip's
    /// own `MediaType`) and the Lottie branch below (a baked Lottie clip becomes an ordinary
    /// `Type = Video` `SnapshotClip` pointing at the cached `.mov` — doc §10's "falls straight into
    /// the same code path a real video clip already takes"). `mediaPath` is always the ALREADY
    /// resolved/baked path, never re-derived from `clip.MediaRef` here.
    private static SnapshotClip BuildSnapshotClip(Clip clip, string mediaPath, double volumeScale, ClipType type) => new()
    {
        Id = clip.Id,
        Type = type,
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
        OpacityKeyframes = BuildKeyframes(clip.OpacityTrack, kf => kf.Value),
        CropKeyframes = BuildKeyframes(clip.CropTrack, kf => kf.Value),
        TransformKeyframes = BuildTransformKeyframes(clip),
        VolumeKeyframes = BuildKeyframes(clip.VolumeTrack, kf => kf.Value),
        Effects = clip.Effects?.Select(ToSnapshotEffect).ToList() ?? [],
    };

    // ----- Lottie (docs/lottie-bake-v1.md §10) -----

    /// Cached -> an ordinary `Type = Video` `SnapshotClip` (zero Lottie-specific code left
    /// downstream of this point). Not cached -> kicks off (or no-ops onto an already in-flight)
    /// bake and reports the ref in `ctx.PendingLottieBakes` instead of `OfflineMediaRefs` — a
    /// pending bake is a known, tracked gap, never a missing/corrupt-file error (doc §10; mirrors
    /// docs/timeline-snapshot-v1.md §6's identical "never OfflineMediaRefs" rule for a skipped
    /// Lottie clip pre-dating this document). `lottieBakeService` absent (no caller wired one up
    /// yet) degrades to "always pending" — the same observable behavior as the v1/v1.1 gap this
    /// replaces, just now correctly signaled via `PendingLottieBakes` instead of a silent skip.
    private static bool TryResolveLottieClip(Clip clip, BuildContext ctx, out SnapshotClip snapshotClip)
    {
        snapshotClip = null!;
        string? sourcePath = ctx.MediaResolver.ResolveUrl(clip.MediaRef);
        if (sourcePath is null)
        {
            ctx.OfflineMediaRefs.Add(clip.MediaRef); // genuinely missing source file — existing semantics, unchanged
            return false;
        }
        if (ctx.LottieBakeService is not { } bakeService)
        {
            ctx.PendingLottieBakes.Add(clip.MediaRef);
            return false;
        }

        (int width, int height) = ResolveLottieBakeSize(clip.MediaRef, ctx);
        var request = new LottieBakeRequest(clip.MediaRef, sourcePath, width, height);
        if (bakeService.TryGetCachedPath(request) is { } cachedPath)
        {
            snapshotClip = BuildSnapshotClip(clip, cachedPath, volumeScale: 1.0, ClipType.Video);
            return true;
        }
        bakeService.BakeAsync(request);
        ctx.PendingLottieBakes.Add(clip.MediaRef);
        return false;
    }

    /// doc §6: `MediaAsset.SourceWidth`/`SourceHeight` (via `MediaResolver.Entry`) when both are
    /// populated and > 0, else the timeline's own output size — a direct port of
    /// `resolveSourceSize(clip.mediaRef) ?? renderSize` (LottieVideoGenerator's Mac counterpart).
    private static (int Width, int Height) ResolveLottieBakeSize(string mediaRef, BuildContext ctx)
    {
        MediaManifestEntry? entry = ctx.MediaResolver.Entry(mediaRef);
        if (entry is { SourceWidth: > 0, SourceHeight: > 0 })
        {
            return (entry.SourceWidth.Value, entry.SourceHeight.Value);
        }
        return (ctx.OutputWidth, ctx.OutputHeight);
    }

    // clip.*Track keyframes are ALREADY clip-relative (Keyframe.swift's `toOffset` is applied at
    // storage time, not just on the public accessor API — see Keyframe.cs's Upsert*Keyframe
    // helpers) — so `kf.Frame` is emitted verbatim, no re-basing needed here.
    private static List<SnapshotKeyframe<T>>? BuildKeyframes<T>(KeyframeTrack<T>? track, Func<Keyframe<T>, T> value)
    {
        if (track is not { IsActive: true })
        {
            return null;
        }
        return track.Keyframes.Select(kf => new SnapshotKeyframe<T>(kf.Frame, value(kf), kf.InterpolationOut)).ToList();
    }

    /// v1.1's `transform` keyframe envelope merges Core's THREE separate tracks
    /// (PositionTrack/ScaleTrack/RotationTrack — there is no single Swift/C# "transform track")
    /// into one combined list: at the union of every keyframe frame across all three, sample the
    /// FULL Transform via <see cref="Clip.TransformAt"/> (which already independently, correctly
    /// samples each underlying track with ITS OWN interpolation mode) — so every emitted anchor
    /// point is an exact sample, not an approximation. The one deliberate simplification is the
    /// curve shape BETWEEN two merged anchors: native re-interpolates the combined Transform
    /// linearly (see docs/timeline-snapshot-v1.md §11), which does not reproduce independent
    /// smooth/hold segments spanning an anchor that only ONE of the three source tracks defines.
    /// Returns null when none of the three tracks are animated (matches v1's static behavior).
    private static List<SnapshotKeyframe<Transform>>? BuildTransformKeyframes(Clip clip)
    {
        if (!clip.HasTransformAnimation)
        {
            return null;
        }
        var offsets = new SortedSet<int>();
        foreach (var kf in clip.PositionTrack?.Keyframes ?? []) offsets.Add(kf.Frame);
        foreach (var kf in clip.ScaleTrack?.Keyframes ?? []) offsets.Add(kf.Frame);
        foreach (var kf in clip.RotationTrack?.Keyframes ?? []) offsets.Add(kf.Frame);
        return offsets
            .Select(o => new SnapshotKeyframe<Transform>(o, clip.TransformAt(clip.StartFrame + o), Interpolation.Linear))
            .ToList();
    }

    private static SnapshotEffect ToSnapshotEffect(Effect effect) =>
        new(effect.Type, effect.Enabled, effect.Params);

    // ----- Text (§12) -----

    private static SnapshotTextClip BuildTextClip(Clip clip) => new()
    {
        Id = clip.Id,
        StartFrame = clip.StartFrame,
        DurationFrames = clip.DurationFrames,
        Content = clip.TextContent ?? "",
        Opacity = clip.Opacity,
        OpacityKeyframes = BuildKeyframes(clip.OpacityTrack, kf => kf.Value),
        BlendMode = clip.BlendMode,
        Transform = clip.Transform,
        // Fallback substitution for a missing/unavailable font name (e.g. "Helvetica-Bold" on a
        // machine with no Helvetica installed) is a render-time concern (§12) — this carries
        // whatever TextStyleJsonConverter's own lenient decode produced, verbatim.
        Style = DeserializeTextField<TextStyle>(clip.TextStyle) ?? new TextStyle(),
        Animation = DeserializeTextField<TextAnimation>(clip.TextAnimation) ?? new TextAnimation(),
        WordTimings = clip.WordTimings,
        Effects = clip.Effects?.Select(ToSnapshotEffect).ToList() ?? [],
    };

    /// `Clip.TextStyle`/`TextAnimation` are stored as raw `JsonElement` (see Timeline.cs's doc
    /// comment on those properties) — this hands the raw JSON to the same lenient
    /// `TextStyleJsonConverter`/`TextAnimationJsonConverter` the project file itself decodes with,
    /// so a missing/legacy-shaped field resolves exactly like it would when the project was opened.
    private static T? DeserializeTextField<T>(JsonElement? raw) where T : class =>
        raw is { } el ? JsonSerializer.Deserialize<T>(el.GetRawText()) : null;
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
        if (s.MinorVersion != 0)
        {
            w.WriteNumber("minorVersion", s.MinorVersion);
        }
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
        if (t.TextClips.Count > 0)
        {
            w.WriteStartArray("textClips");
            foreach (var tc in t.TextClips)
            {
                WriteTextClip(w, tc);
            }
            w.WriteEndArray();
        }
        w.WriteEndObject();
    }

    // v1.2 (docs/timeline-snapshot-v1.md §12) — every key hand-written, same determinism guarantee
    // (§9) as the rest of this serializer.
    private static void WriteTextClip(Utf8JsonWriter w, SnapshotTextClip c)
    {
        w.WriteStartObject();
        w.WriteString("id", c.Id);
        w.WriteNumber("startFrame", c.StartFrame);
        w.WriteNumber("durationFrames", c.DurationFrames);
        w.WriteString("content", c.Content);

        w.WriteStartObject("opacity");
        w.WriteNumber("value", c.Opacity);
        WriteDoubleKeyframes(w, c.OpacityKeyframes);
        w.WriteEndObject();

        if (c.BlendMode is { } blendMode)
        {
            w.WriteString("blendMode", SwiftStringEnumConverter<BlendMode>.RawValue(blendMode));
        }
        else
        {
            w.WriteNull("blendMode");
        }

        // Flat, not a {value, keyframes} envelope — always static, see SnapshotTextClip.Transform.
        w.WriteStartObject("transform");
        WriteTransformValue(w, c.Transform);
        w.WriteEndObject();

        w.WriteStartObject("style");
        WriteTextStyle(w, c.Style);
        w.WriteEndObject();

        w.WriteStartObject("animation");
        WriteTextAnimation(w, c.Animation);
        w.WriteEndObject();

        if (c.WordTimings is { Count: > 0 } timings)
        {
            w.WriteStartArray("wordTimings");
            foreach (var t in timings)
            {
                w.WriteStartObject();
                w.WriteString("text", t.Text);
                w.WriteNumber("startFrame", t.StartFrame);
                w.WriteNumber("endFrame", t.EndFrame);
                w.WriteEndObject();
            }
            w.WriteEndArray();
        }
        else
        {
            w.WriteNull("wordTimings");
        }

        if (c.Effects.Count > 0)
        {
            w.WriteStartArray("effects");
            foreach (var effect in c.Effects)
            {
                WriteEffect(w, effect);
            }
            w.WriteEndArray();
        }

        w.WriteEndObject();
    }

    private static void WriteTextStyle(Utf8JsonWriter w, TextStyle s)
    {
        w.WriteString("fontName", s.FontName);
        w.WriteNumber("fontSize", s.FontSize);
        w.WriteNumber("fontScale", s.FontScale);
        w.WriteBoolean("isBold", s.IsBold);
        w.WriteBoolean("isItalic", s.IsItalic);
        w.WriteStartObject("color");
        WriteRgba(w, s.Color);
        w.WriteEndObject();
        w.WriteString("alignment", SwiftStringEnumConverter<TextStyleAlignment>.RawValue(s.Alignment));
        w.WriteStartObject("shadow");
        w.WriteBoolean("enabled", s.Shadow.Enabled);
        w.WriteStartObject("color");
        WriteRgba(w, s.Shadow.Color);
        w.WriteEndObject();
        w.WriteNumber("offsetX", s.Shadow.OffsetX);
        w.WriteNumber("offsetY", s.Shadow.OffsetY);
        w.WriteNumber("blur", s.Shadow.Blur);
        w.WriteEndObject();
        w.WriteStartObject("background");
        w.WriteBoolean("enabled", s.Background.Enabled);
        w.WriteStartObject("color");
        WriteRgba(w, s.Background.Color);
        w.WriteEndObject();
        w.WriteEndObject();
        w.WriteStartObject("border");
        w.WriteBoolean("enabled", s.Border.Enabled);
        w.WriteStartObject("color");
        WriteRgba(w, s.Border.Color);
        w.WriteEndObject();
        w.WriteEndObject();
    }

    private static void WriteTextAnimation(Utf8JsonWriter w, TextAnimation a)
    {
        w.WriteString("preset", SwiftStringEnumConverter<TextAnimationPreset>.RawValue(a.Preset));
        w.WriteNumber("perWordFrames", a.PerWordFrames);
        if (a.Highlight is { } highlight)
        {
            w.WriteStartObject("highlight");
            WriteRgba(w, highlight);
            w.WriteEndObject();
        }
        else
        {
            w.WriteNull("highlight");
        }
    }

    private static void WriteRgba(Utf8JsonWriter w, TextStyleRgba c)
    {
        w.WriteNumber("r", c.R);
        w.WriteNumber("g", c.G);
        w.WriteNumber("b", c.B);
        w.WriteNumber("a", c.A);
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
        WriteDoubleKeyframes(w, c.OpacityKeyframes);
        w.WriteEndObject();

        w.WriteStartObject("transform");
        w.WriteStartObject("value");
        WriteTransformValue(w, c.Transform);
        w.WriteEndObject();
        if (c.TransformKeyframes is { Count: > 0 } transformKfs)
        {
            w.WriteStartArray("keyframes");
            foreach (var kf in transformKfs)
            {
                w.WriteStartObject();
                w.WriteNumber("frame", kf.Frame);
                w.WriteStartObject("value");
                WriteTransformValue(w, kf.Value);
                w.WriteEndObject();
                w.WriteString("interpolation", SwiftStringEnumConverter<Interpolation>.RawValue(kf.Interpolation));
                w.WriteEndObject();
            }
            w.WriteEndArray();
        }
        else
        {
            w.WriteNull("keyframes");
        }
        w.WriteEndObject();

        w.WriteStartObject("crop");
        w.WriteStartObject("value");
        WriteCropValue(w, c.Crop);
        w.WriteEndObject();
        if (c.CropKeyframes is { Count: > 0 } cropKfs)
        {
            w.WriteStartArray("keyframes");
            foreach (var kf in cropKfs)
            {
                w.WriteStartObject();
                w.WriteNumber("frame", kf.Frame);
                w.WriteStartObject("value");
                WriteCropValue(w, kf.Value);
                w.WriteEndObject();
                w.WriteString("interpolation", SwiftStringEnumConverter<Interpolation>.RawValue(kf.Interpolation));
                w.WriteEndObject();
            }
            w.WriteEndArray();
        }
        else
        {
            w.WriteNull("keyframes");
        }
        w.WriteEndObject();

        w.WriteStartObject("volume");
        w.WriteNumber("gain", c.VolumeGain);
        w.WriteNumber("fadeInFrames", c.FadeInFrames);
        w.WriteNumber("fadeOutFrames", c.FadeOutFrames);
        w.WriteString("fadeInInterpolation", SwiftStringEnumConverter<Interpolation>.RawValue(c.FadeInInterpolation));
        w.WriteString("fadeOutInterpolation", SwiftStringEnumConverter<Interpolation>.RawValue(c.FadeOutInterpolation));
        WriteDoubleKeyframes(w, c.VolumeKeyframes); // volume dB keyframe track — E4.5 (audio playback)
        w.WriteEndObject();

        if (c.Effects.Count > 0)
        {
            w.WriteStartArray("effects");
            foreach (var effect in c.Effects)
            {
                WriteEffect(w, effect);
            }
            w.WriteEndArray();
        }

        w.WriteEndObject();
    }

    private static void WriteTransformValue(Utf8JsonWriter w, Transform t)
    {
        w.WriteNumber("centerX", t.CenterX);
        w.WriteNumber("centerY", t.CenterY);
        w.WriteNumber("width", t.Width);
        w.WriteNumber("height", t.Height);
        w.WriteNumber("rotation", t.Rotation);
        w.WriteBoolean("flipHorizontal", t.FlipHorizontal);
        w.WriteBoolean("flipVertical", t.FlipVertical);
    }

    private static void WriteCropValue(Utf8JsonWriter w, Crop c)
    {
        w.WriteNumber("left", c.Left);
        w.WriteNumber("top", c.Top);
        w.WriteNumber("right", c.Right);
        w.WriteNumber("bottom", c.Bottom);
    }

    private static void WriteDoubleKeyframes(Utf8JsonWriter w, List<SnapshotKeyframe<double>>? keyframes)
    {
        if (keyframes is not { Count: > 0 })
        {
            w.WriteNull("keyframes");
            return;
        }
        w.WriteStartArray("keyframes");
        foreach (var kf in keyframes)
        {
            w.WriteStartObject();
            w.WriteNumber("frame", kf.Frame);
            w.WriteNumber("value", kf.Value);
            w.WriteString("interpolation", SwiftStringEnumConverter<Interpolation>.RawValue(kf.Interpolation));
            w.WriteEndObject();
        }
        w.WriteEndArray();
    }

    // v1.1 effect wire shape (docs/timeline-snapshot-v1.md §11): params[name] = { value, string,
    // keyframes } — deliberately NOT Core's EffectParam project-file key names (which use
    // "track", not "keyframes"); this is the engine's own ABI contract, hand-written like every
    // other object in this serializer (§9's determinism guarantee covers this too).
    private static void WriteEffect(Utf8JsonWriter w, SnapshotEffect effect)
    {
        w.WriteStartObject();
        w.WriteString("type", effect.Type);
        w.WriteBoolean("enabled", effect.Enabled);
        w.WriteStartObject("params");
        foreach (var (key, param) in effect.Params.OrderBy(kv => kv.Key, StringComparer.Ordinal))
        {
            w.WriteStartObject(key);
            if (param.Value is { } v)
            {
                w.WriteNumber("value", v);
            }
            else
            {
                w.WriteNull("value");
            }
            if (param.StringValue is { } s)
            {
                w.WriteString("string", s);
            }
            else
            {
                w.WriteNull("string");
            }
            if (param.Track is { IsActive: true } track)
            {
                w.WriteStartArray("keyframes");
                foreach (var kf in track.Keyframes)
                {
                    w.WriteStartObject();
                    w.WriteNumber("frame", kf.Frame);
                    w.WriteNumber("value", kf.Value);
                    w.WriteString("interpolation", SwiftStringEnumConverter<Interpolation>.RawValue(kf.InterpolationOut));
                    w.WriteEndObject();
                }
                w.WriteEndArray();
            }
            else
            {
                w.WriteNull("keyframes");
            }
            w.WriteEndObject();
        }
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
