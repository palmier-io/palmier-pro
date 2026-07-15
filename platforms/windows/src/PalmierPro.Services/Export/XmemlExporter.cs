using System.Globalization;
using System.Text;
using PalmierPro.Core;
using PalmierPro.Core.Export;
using PalmierPro.Core.Models;

namespace PalmierPro.Services.Export;

/// Exports a Timeline as XMEML 4 (Final Cut Pro 7 XML), for Premiere Pro (which does not read
/// FCPXML natively). Ported from Export/XMLExporter.swift.
///
/// How to read this file: the document is built as an <see cref="XmlNode"/> tree; `RenderXml` owns
/// all indentation and escaping. Read `Builder.Build` top-down to see the format: the
/// `&lt;xmeml&gt;&lt;sequence&gt;&lt;media&gt;` shell, then tracks → clipitems → files / filters / links.
///
/// What transports:
/// - Clip placement &amp; trims → `&lt;clipitem&gt;` `&lt;start&gt;`/`&lt;end&gt;`/`&lt;in&gt;`/`&lt;out&gt;`
/// - Speed → Time Remap filter
/// - Volume (static + keyframed) → Audio Levels filter
/// - Opacity (static + keyframed) → its own Opacity filter
/// - Transform — scale / rotation / position (static + keyframed) → Basic Motion filter
/// - Crop (static + keyframed) → Crop filter
/// - Fade in/out → single-sided transition (Cross Dissolve for video, Cross Fade for audio)
/// - Linked A/V clips → reciprocal `&lt;link&gt;` blocks
/// - Source frame rate → per-file NTSC flag (29.97/23.976/59.94 → ntsc TRUE)
/// - Nested timelines → nested `&lt;sequence&gt;` inside the carrier clipitem (full definition on
///   first use, id reference after — Premiere's own convention); recursive, frozen carriers clamp
///   to the child's length, empty/missing children drop
///
/// What does NOT transport:
/// - Text overlays. FCPXML supports this, not XMEML.
/// - Flips (horizontal/vertical)
/// - Keyframe interpolation curves (linear/hold/smooth): keyframes import with default easing
/// - Adjustments and effects (Clip.Effects): Core Image stacks have no XMEML representation
///
/// Coordinates are in timeline frames; FCP7 rotation is counter-clockwise-positive, so our
/// clockwise-positive values are negated on emission.
///
/// References:
/// XMEML: https://developer.apple.com/library/archive/documentation/AppleApplications/Reference/FinalCutPro_XML/VersionsoftheInterchangeFormat/VersionsoftheInterchangeFormat.html
/// FCPXML: https://developer.apple.com/documentation/professional-video-applications/fcpxml-reference
public static class XmemlExporter
{
    private static readonly Encoding Utf8NoBom = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false);

    public static async Task ExportAsync(
        Timeline timeline, MediaResolver resolver, ISourceTimingReader timingReader, string outputPath,
        Func<string, Timeline?>? resolveTimeline = null)
    {
        resolveTimeline ??= _ => null;
        var startFrameCache = await SourceTimecodeCacheAsync(timeline, resolver, resolveTimeline, timingReader).ConfigureAwait(false);
        var xml = Render(timeline, resolver, resolveTimeline, startFrameCache);
        File.WriteAllText(outputPath, xml, Utf8NoBom);
    }

    /// Split out so tests can build the document synchronously.
    public static string Render(
        Timeline timeline, MediaResolver resolver, Func<string, Timeline?>? resolveTimeline = null,
        IReadOnlyDictionary<string, SourceTimecode>? startFrameCache = null) =>
        new Builder(timeline, resolver, resolveTimeline ?? (_ => null), startFrameCache ?? new Dictionary<string, SourceTimecode>()).Build();

    private static async Task<Dictionary<string, SourceTimecode>> SourceTimecodeCacheAsync(
        Timeline timeline, MediaResolver resolver, Func<string, Timeline?> resolveTimeline, ISourceTimingReader timingReader)
    {
        var mediaRefs = new HashSet<string>();
        foreach (var t in new[] { timeline }.Concat(timeline.ReachableTimelines(resolveTimeline)))
        {
            foreach (var clip in t.Tracks.SelectMany(tr => tr.Clips).Where(c => c.SourceClipType != ClipType.Sequence))
            {
                mediaRefs.Add(clip.MediaRef);
            }
        }
        return await timingReader.TimecodesAsync(mediaRefs, resolver.ExpectedUrlMap()).ConfigureAwait(false);
    }

    // MARK: - Source timecode

    public readonly record struct TimecodeTags(int Base, bool Ntsc, int Frame, bool DropFrame, string String);

    /// The `<timecode>` values to emit for a file. A `tmcd` timecode runs at its own rate (often 30
    /// DF even on 60p footage), so when present it — not the video rate — drives the rate/format.
    /// When absent, fall back to the video rate and emit a dummy 00:00:00:00.
    public static TimecodeTags TimecodeTagsFor(SourceTimecode? source, int videoTimebase, bool videoNtsc)
    {
        var baseRate = source?.Quanta ?? videoTimebase;
        var dropFrame = source?.DropFrame ?? (videoNtsc && videoTimebase % 30 == 0);
        var ntsc = dropFrame || videoNtsc;
        var frame = source?.Frame ?? 0;
        return new TimecodeTags(baseRate, ntsc, frame, dropFrame, FormatTimecode(frame, baseRate, dropFrame));
    }

    /// Frame count → SMPTE string; drop-frame (29.97/59.94) uses `;` separators and skips dropped frames.
    public static string FormatTimecode(int frame, int fps, bool dropFrame)
    {
        if (fps <= 0)
        {
            return "00:00:00:00";
        }
        var f = frame;
        if (dropFrame)
        {
            var drop = SwiftMath.RoundToInt(fps * 0.066666);   // 2 @ 30, 4 @ 60
            var d = f / (fps * 600);
            var m = f % (fps * 600);
            f += drop * 9 * d + (m > drop ? drop * ((m - drop) / (fps * 60)) : 0);
        }
        var sep = dropFrame ? ";" : ":";
        var ff = f % fps;
        var ss = f / fps % 60;
        var mm = f / (fps * 60) % 60;
        var hh = f / (fps * 3600);
        return $"{hh.ToString("D2", CultureInfo.InvariantCulture)}{sep}{mm.ToString("D2", CultureInfo.InvariantCulture)}{sep}" +
               $"{ss.ToString("D2", CultureInfo.InvariantCulture)}{sep}{ff.ToString("D2", CultureInfo.InvariantCulture)}";
    }

    // MARK: - Builder

    private sealed class Builder
    {
        private readonly Timeline _timeline;
        private readonly MediaResolver _resolver;
        private readonly Func<string, Timeline?> _resolveTimeline;
        private readonly int _fps;
        private readonly int _seqWidth;
        private readonly int _seqHeight;
        private int _curSeqWidth;

        /// Files already emitted in full; repeat references collapse to `<file id="..."/>`.
        private readonly HashSet<(string MediaRef, bool IsAudio)> _emittedFiles = [];
        /// Clip id → position within its media type, used to emit `<link>` cross-references.
        private Dictionary<string, ClipAddress> _clipAddresses = [];
        private Dictionary<string, List<Clip>> _clipsByLinkGroup = [];
        private readonly IReadOnlyDictionary<string, SourceTimecode> _startFrameCache;
        /// Child timeline id -> XMEML sequence id; first carrier embeds the full definition, later
        /// carriers reference it (Premiere's own nested-sequence convention).
        private readonly Dictionary<string, string> _sequenceIds = [];
        private readonly HashSet<string> _emittedSequences = [];

        private readonly record struct ClipAddress(int TrackIndex, int ClipIndex, bool IsAudio);  // indices 1-based

        public Builder(Timeline timeline, MediaResolver resolver, Func<string, Timeline?> resolveTimeline,
            IReadOnlyDictionary<string, SourceTimecode> startFrameCache)
        {
            _timeline = timeline;
            _resolver = resolver;
            _resolveTimeline = resolveTimeline;
            _fps = timeline.Fps;
            _seqWidth = timeline.Width;
            _seqHeight = timeline.Height;
            _curSeqWidth = timeline.Width;
            _startFrameCache = startFrameCache;
        }

        // MARK: - Document shell

        public string Build()
        {
            _sequenceIds[_timeline.Id] = "sequence-1";
            _emittedSequences.Add(_timeline.Id);
            var root = El("xmeml", attrs: [("version", "4")], children: [SequenceNode("sequence-1", _timeline)]);
            return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE xmeml>\n" + RenderXml(root, 0);
        }

        /// One timeline as a `<sequence>`; used for the root and, recursively, nested timelines.
        /// Link/address state is per-sequence, so it stacks around the recursive build.
        private XmlNode SequenceNode(string id, Timeline timeline)
        {
            var savedAddresses = _clipAddresses;
            var savedGroups = _clipsByLinkGroup;
            var savedSeqWidth = _curSeqWidth;
            _clipAddresses = [];
            _clipsByLinkGroup = [];
            _curSeqWidth = timeline.Width;
            try
            {
                // FCP XML orders video tracks bottom→top; our model stores them top→bottom.
                var videoTracks = timeline.Tracks.Where(t => t.Type.IsVisual()).Reverse().ToList();
                var audioTracks = timeline.Tracks.Where(t => t.Type == ClipType.Audio).ToList();
                var sortedVideo = videoTracks.Select(SortEmittable).ToList();
                var sortedAudio = audioTracks.Select(SortEmittable).ToList();

                IndexAddresses(sortedVideo, isAudio: false);
                IndexAddresses(sortedAudio, isAudio: true);
                IndexLinkGroups(timeline);

                var videoTrackNodes = videoTracks.Zip(sortedVideo, (t, c) => TrackNode(t, c, isAudio: false)).ToList();
                var audioTrackNodes = audioTracks.Zip(sortedAudio, (t, c) => TrackNode(t, c, isAudio: true)).ToList();

                return El("sequence", attrs: [("id", id)], children:
                [
                    Leaf("name", timeline.Name),
                    Leaf("duration", timeline.TotalFrames),
                    Rate(_fps),
                    TimecodeNode(),
                    El("media", children:
                    [
                        El("video", children: Prepend(VideoFormatNode(timeline.Width, timeline.Height), videoTrackNodes)),
                        El("audio", children: Prepend3(Leaf("numOutputChannels", 2), AudioFormatNode(), AudioOutputsNode(), audioTrackNodes)),
                    ]),
                ]);
            }
            finally
            {
                _clipAddresses = savedAddresses;
                _clipsByLinkGroup = savedGroups;
                _curSeqWidth = savedSeqWidth;
            }
        }

        private static List<XmlNode> Prepend(XmlNode first, List<XmlNode> rest)
        {
            var list = new List<XmlNode>(rest.Count + 1) { first };
            list.AddRange(rest);
            return list;
        }

        private static List<XmlNode> Prepend3(XmlNode a, XmlNode b, XmlNode c, List<XmlNode> rest)
        {
            var list = new List<XmlNode>(rest.Count + 3) { a, b, c };
            list.AddRange(rest);
            return list;
        }

        private XmlNode TimecodeNode() => El("timecode", children:
        [
            Rate(_fps),
            Leaf("string", "00:00:00:00"),
            Leaf("frame", 0),
            Leaf("source", "source"),
            Leaf("displayformat", "NDF"),
        ]);

        private XmlNode VideoFormatNode(int width, int height) => El("format", children:
        [
            El("samplecharacteristics", children:
            [
                Leaf("width", width), Leaf("height", height), Bool("anamorphic", false),
                Leaf("pixelaspectratio", "square"), Leaf("fielddominance", "none"), Rate(_fps),
            ]),
        ]);

        private static XmlNode AudioFormatNode() => El("format", children:
        [
            El("samplecharacteristics", children: [Leaf("samplerate", 48000), Leaf("depth", 16)]),
        ]);

        private static XmlNode AudioOutputsNode() => El("outputs", children:
        [
            El("group", children:
            [
                Leaf("index", 1), Leaf("numchannels", 2), Leaf("downmix", 0),
                El("channel", children: [Leaf("index", 1)]), El("channel", children: [Leaf("index", 2)]),
            ]),
        ]);

        // MARK: - Tracks → clipitems

        private XmlNode TrackNode(Track track, List<Clip> sortedClips, bool isAudio)
        {
            var enabled = isAudio ? !track.Muted : !track.Hidden;
            var children = new List<XmlNode> { Bool("enabled", enabled), Bool("locked", false) };
            foreach (var clip in sortedClips)
            {
                if (FadeTransition(clip, FadeEdge.Left, isAudio) is { } fadeIn)
                {
                    children.Add(fadeIn);
                }
                children.Add(ClipItemNode(clip, isAudio));
                if (FadeTransition(clip, FadeEdge.Right, isAudio) is { } fadeOut)
                {
                    children.Add(fadeOut);
                }
            }
            return El("track", children: children);
        }

        private XmlNode ClipItemNode(Clip clip, bool isAudio)
        {
            if (clip.SourceClipType == ClipType.Sequence)
            {
                return NestClipItemNode(clip, isAudio);
            }
            var sourceDuration = SourceDurationFrames(clip.MediaRef) ?? clip.SourceDurationFrames;
            // in/out are source-frame offsets, so they span SourceFramesConsumed (Time Remap handles rate).
            var inPoint = clip.TrimStartFrame;
            var outPoint = clip.TrimStartFrame + clip.SourceFramesConsumed;

            var children = new List<XmlNode>
            {
                Leaf("masterclipid", MasterclipId(clip, isAudio)),
                Leaf("name", _resolver.DisplayName(clip.MediaRef)),
                Bool("enabled", true),
                Leaf("duration", sourceDuration),
                Rate(_fps),
                Leaf("start", clip.StartFrame),
                Leaf("end", clip.EndFrame),
                Leaf("in", inPoint),
                Leaf("out", outPoint),
                FileNode(clip.MediaRef, isAudio),
            };
            if (TimeRemapFilter(clip.Speed, isAudio) is { } remap)
            {
                children.Add(remap);
            }
            children.AddRange(isAudio ? VolumeFilters(clip) : VideoFilters(clip));
            children.AddRange(LinkNodes(clip));
            return El("clipitem", attrs: [("id", $"clipitem-{clip.Id}")], children: children);
        }

        /// Nest carrier: a clipitem over the child `<sequence>` — full definition on first use, id
        /// reference after. The frozen carrier is clamped to the child's current length.
        private XmlNode NestClipItemNode(Clip clip, bool isAudio)
        {
            var child = _resolveTimeline(clip.MediaRef) ??
                throw new InvalidOperationException("nest carrier's child timeline unresolved — SortEmittable should have filtered it");
            if (!_sequenceIds.TryGetValue(clip.MediaRef, out var seqId))
            {
                seqId = $"sequence-{_sequenceIds.Count + 1}";
                _sequenceIds[clip.MediaRef] = seqId;
            }
            var sequence = _emittedSequences.Add(clip.MediaRef)
                ? SequenceNode(seqId, child)
                : El("sequence", attrs: [("id", seqId)]);

            var inPoint = clip.TrimStartFrame;
            var outPoint = Math.Min(inPoint + clip.DurationFrames, child.TotalFrames);

            var children = new List<XmlNode>
            {
                Leaf("masterclipid", MasterclipId(clip, isAudio)),
                Leaf("name", child.Name),
                Bool("enabled", true),
                Leaf("duration", child.TotalFrames),
                Rate(_fps),
                Leaf("start", clip.StartFrame),
                Leaf("end", clip.StartFrame + (outPoint - inPoint)),
                Leaf("in", inPoint),
                Leaf("out", outPoint),
                sequence,
            };
            children.AddRange(isAudio ? VolumeFilters(clip) : VideoFilters(clip));
            children.AddRange(LinkNodes(clip));
            return El("clipitem", attrs: [("id", $"clipitem-{clip.Id}")], children: children);
        }

        private static string MasterclipId(Clip clip, bool isAudio) =>
            clip.LinkGroupId is { } group ? $"masterclip-{group}" : $"masterclip-{clip.MediaRef}-{(isAudio ? "audio" : "video")}";

        // MARK: - File elements

        /// Separate ids per media type — Premiere rejects a clipitem pointing at a `<file>` of the
        /// wrong type. Repeats collapse to a self-closing `<file id="..."/>`.
        private XmlNode FileNode(string mediaRef, bool isAudio)
        {
            var fileId = $"file-{mediaRef}-{(isAudio ? "audio" : "video")}";
            var key = (mediaRef, isAudio);
            if (_emittedFiles.Contains(key))
            {
                return El("file", attrs: [("id", fileId)]);
            }
            _emittedFiles.Add(key);

            var entry = _resolver.Entry(mediaRef);
            var url = _resolver.ResolveUrl(mediaRef);
            // Resolve matches media by exact filename + extension.
            var fileName = url is not null ? Path.GetFileName(url) : entry?.Name ?? mediaRef;
            // Resolve needs Premiere's extra-slash host form; the canonical single-slash one fails.
            var pathUrl = url is not null
                ? new Uri(url).AbsoluteUri.Replace("file://", "file://localhost//")
                : $"media/{mediaRef}";
            // A still decodes to exactly 1 frame.
            var isImage = entry?.Type == ClipType.Image;
            var durationFrames = isImage ? 1 : entry is not null ? Math.Max(0, SwiftMath.SecondsToFrame(entry.Duration, _fps)) : 0;
            var (timebase, ntsc) = RateTags(entry?.SourceFPS ?? _fps);

            var videoChildren = new List<XmlNode>();
            if (isImage)
            {
                videoChildren.Add(Leaf("duration", 1));
            }
            videoChildren.Add(El("samplecharacteristics", children:
            [
                Leaf("width", entry?.SourceWidth ?? _seqWidth),
                Leaf("height", entry?.SourceHeight ?? _seqHeight),
                Bool("anamorphic", false),
                Leaf("pixelaspectratio", "square"),
                Leaf("fielddominance", "none"),
                Rate(timebase, ntsc),
            ]));

            var media = isAudio
                ? El("media", children:
                  [
                      El("audio", children:
                      [
                          El("samplecharacteristics", children: [Leaf("samplerate", 48000), Leaf("depth", 16)]),
                          Leaf("channelcount", 2),
                      ]),
                  ])
                : El("media", children: [El("video", children: videoChildren)]);

            // timecode is required for Davinci Resolve; computed by the unit-tested TimecodeTagsFor.
            var tc = TimecodeTagsFor(SourceTimecodeFor(mediaRef), timebase, ntsc);
            var timecode = El("timecode", children:
            [
                Rate(tc.Base, tc.Ntsc),
                Leaf("string", tc.String),
                Leaf("frame", tc.Frame),
                Leaf("displayformat", tc.DropFrame ? "DF" : "NDF"),
            ]);
            return El("file", attrs: [("id", fileId)], children:
            [
                Leaf("name", fileName),
                Leaf("pathurl", pathUrl),
                Rate(timebase, ntsc),
                Leaf("duration", durationFrames),
                timecode,
                media,
            ]);
        }

        /// Source start timecode — one read serves both the video and audio file nodes.
        private SourceTimecode? SourceTimecodeFor(string mediaRef) =>
            _startFrameCache.TryGetValue(mediaRef, out var tc) ? tc : null;

        // MARK: - Links

        /// Linked clips emit a `<link>` per partner so Premiere rebuilds the A/V pair.
        private List<XmlNode> LinkNodes(Clip clip)
        {
            if (clip.LinkGroupId is not { } group || !_clipsByLinkGroup.TryGetValue(group, out var partners) || partners.Count <= 1)
            {
                return [];
            }
            return partners
                .Where(p => _clipAddresses.ContainsKey(p.Id))
                .Select(partner =>
                {
                    var addr = _clipAddresses[partner.Id];
                    return El("link", children:
                    [
                        Leaf("linkclipref", $"clipitem-{partner.Id}"),
                        Leaf("mediatype", addr.IsAudio ? "audio" : "video"),
                        Leaf("trackindex", addr.TrackIndex),
                        Leaf("clipindex", addr.ClipIndex),
                    ]);
                })
                .ToList();
        }

        // MARK: - Transitions (fades)

        /// A fade exports as a single-sided dissolve to black/silence (no clip-to-clip model).
        private XmlNode? FadeTransition(Clip clip, FadeEdge edge, bool isAudio)
        {
            var frames = clip.FadeFrames(edge);
            if (frames <= 0)
            {
                return null;
            }

            int start, end, cutFrames;
            string alignment;
            if (edge == FadeEdge.Left)
            {
                start = clip.StartFrame;
                end = clip.StartFrame + frames;
                alignment = "start-black";
                cutFrames = 0;
            }
            else
            {
                start = clip.EndFrame - frames;
                end = clip.EndFrame;
                alignment = "end-black";
                cutFrames = frames;
            }

            var children = new List<XmlNode> { Leaf("start", start), Leaf("end", end), Leaf("alignment", alignment) };
            if (isAudio)
            {
                children.Add(Rate(_fps));
                children.Add(Effect("Cross Fade ( 0dB)", "KGAudioTransCrossFade0dB", "transition", "audio"));
            }
            else
            {
                // Premiere's private cut-point, in ticks (254016000000/sec): 0 for fade-in, full length for fade-out.
                var cutPointTicks = (long)cutFrames * (254_016_000_000L / _fps);
                children.Add(Leaf("cutPointTicks", cutPointTicks.ToString(CultureInfo.InvariantCulture)));
                children.Add(Rate(_fps));
                children.Add(Effect("Cross Dissolve", "Cross Dissolve", "transition", "video", category: "Dissolve", body:
                [
                    Leaf("wipecode", 0), Leaf("wipeaccuracy", 100), Leaf("startratio", 0), Leaf("endratio", 1),
                    Bool("reverse", false),
                ]));
            }
            return El("transitionitem", children: children);
        }

        // MARK: - Filters

        /// Premiere needs this to apply speed; it won't infer it from the in/out vs start/end ratio.
        private XmlNode? TimeRemapFilter(double speed, bool isAudio)
        {
            if (speed == 1.0)
            {
                return null;
            }
            return Filter(Effect("Time Remap", "timeremap", "motion", isAudio ? "audio" : "video", body:
            [
                Parameter("variablespeed", "variablespeed", Leaf("value", 0), min: "0", max: "1"),
                Parameter("speed", "speed", Leaf("value", (speed * 100).ToString("F4", CultureInfo.InvariantCulture)), min: "-100000", max: "100000"),
                Parameter("reverse", "reverse", Bool("value", false)),
                Parameter("frameblending", "frameblending", Bool("value", false)),
            ]));
        }

        /// `level` is linear (1 = 0 dB, clamped to ~3.98). Uses fade-excluded volume since fades
        /// export separately as a transition.
        private List<XmlNode> VolumeFilters(Clip clip)
        {
            static double ClampLevel(double v) => Math.Max(0, Math.Min(v, 3.98));
            var frames = clip.KeyframeFrames(AnimatableProperty.Volume);
            XmlNode level;
            if (frames.Count == 0)
            {
                if (clip.Volume == 1.0)
                {
                    return [];
                }
                level = ScalarParam("level", "Level", "0", "3.98107", ClampLevel(clip.Volume), decimals: 4);
            }
            else
            {
                var kfs = frames.Select(f => (When: f - clip.StartFrame, Value: ClampLevel(clip.RawVolumeAt(f)))).ToList();
                level = ScalarParam("level", "Level", "0", "3.98107", kfs[0].Value, kfs, decimals: 4);
            }
            return [Filter(Effect("Audio Levels", "audiolevels", "audio", "audio", body: [level]))];
        }

        private List<XmlNode> VideoFilters(Clip clip) =>
            new List<XmlNode?> { MotionFilter(clip), CropFilter(clip), OpacityFilter(clip) }.OfType<XmlNode>().ToList();

        /// Basic Motion: scale, rotation, center — keyframed, or static (defaults omitted).
        private XmlNode? MotionFilter(Clip clip)
        {
            var sourceWidth = _resolver.Entry(clip.MediaRef)?.SourceWidth ?? 0;
            // Scale is relative to the sequence being emitted — a nested child's canvas, not the root's.
            double ScalePct(double width) => sourceWidth > 0 ? (double)_curSeqWidth / sourceWidth * width * 100 : width * 100;

            // FCP7 center uses normalized coordinates (0 = center), not pixels.
            static (double X, double Y) Center(Transform t) => (t.CenterX - 0.5, t.CenterY - 0.5);

            // Center depends on position + scale, so sample all transform params at the union of frames.
            var frames = new SortedSet<int>(
                clip.KeyframeFrames(AnimatableProperty.Position)
                    .Concat(clip.KeyframeFrames(AnimatableProperty.Scale))
                    .Concat(clip.KeyframeFrames(AnimatableProperty.Rotation))).ToList();

            List<XmlNode> parameters;
            if (frames.Count == 0)
            {
                var t = clip.Transform;
                var c = Center(t);
                var scaled = ScalePct(t.Width);
                var rotated = -t.Rotation;
                var needsCenter = Math.Abs(c.X) > 0.001 || Math.Abs(c.Y) > 0.001;   // normalized, so a small epsilon
                var needsScale = Math.Abs(scaled - 100) > 0.1;
                var needsRotation = Math.Abs(rotated) > 0.05;
                if (!needsCenter && !needsScale && !needsRotation)
                {
                    return null;
                }
                parameters = [];
                if (needsScale)
                {
                    parameters.Add(ScalarParam("scale", "Scale", "0", "1000", scaled));
                }
                if (needsRotation)
                {
                    parameters.Add(ScalarParam("rotation", "Rotation", "-100000", "100000", rotated));
                }
                if (needsCenter)
                {
                    parameters.Add(CenterParam(c));
                }
            }
            else
            {
                var scaleKfs = frames.Select(f => (When: f - clip.StartFrame, Value: ScalePct(clip.SizeAt(f).Width))).ToList();
                var rotationKfs = frames.Select(f => (When: f - clip.StartFrame, Value: -clip.RotationAt(f))).ToList();
                var centerKfs = frames.Select(f =>
                {
                    var c = Center(clip.TransformAt(f));
                    return (When: f - clip.StartFrame, X: c.X, Y: c.Y);
                }).ToList();
                parameters =
                [
                    ScalarParam("scale", "Scale", "0", "1000", scaleKfs[0].Value, scaleKfs),
                    ScalarParam("rotation", "Rotation", "-100000", "100000", rotationKfs[0].Value, rotationKfs),
                    CenterParam((centerKfs[0].X, centerKfs[0].Y), centerKfs),
                ];
            }
            return Filter(Effect("Basic Motion", "basic", "motion", "video", body: parameters));
        }

        /// Crop filter — edge insets as 0–100 percentages (our model stores 0–1 fractions).
        private XmlNode? CropFilter(Clip clip)
        {
            var frames = clip.KeyframeFrames(AnimatableProperty.Crop);
            if (frames.Count == 0 && clip.Crop.IsIdentity)
            {
                return null;
            }

            XmlNode Edge(string id, Func<Crop, double> select)
            {
                if (frames.Count == 0)
                {
                    return ScalarParam(id, id, "0", "100", select(clip.Crop) * 100);
                }
                var kfs = frames.Select(f => (When: f - clip.StartFrame, Value: select(clip.CropAt(f)) * 100)).ToList();
                return ScalarParam(id, id, "0", "100", kfs[0].Value, kfs);
            }
            var parameters = new List<XmlNode>
            {
                Edge("left", c => c.Left), Edge("right", c => c.Right), Edge("top", c => c.Top), Edge("bottom", c => c.Bottom),
            };
            return Filter(Effect("Crop", "crop", "motion", "video", category: "motion", body: parameters));
        }

        /// FCP7 keeps opacity in its own Opacity effect (Basic Motion has no opacity parameter).
        private XmlNode? OpacityFilter(Clip clip)
        {
            var frames = clip.KeyframeFrames(AnimatableProperty.Opacity);
            XmlNode opacity;
            if (frames.Count == 0)
            {
                if (clip.Opacity == 1.0)
                {
                    return null;
                }
                opacity = ScalarParam("opacity", "Opacity", "0", "100", clip.Opacity * 100, decimals: 1);
            }
            else
            {
                var kfs = frames.Select(f => (When: f - clip.StartFrame, Value: clip.RawOpacityAt(f) * 100)).ToList();
                opacity = ScalarParam("opacity", "Opacity", "0", "100", kfs[0].Value, kfs, decimals: 1);
            }
            return Filter(Effect("Opacity", "opacity", "motion", "video", body: [opacity]));
        }

        // MARK: - Indexing helpers

        /// Drops unresolvable clips so track builders and `<link>` indices agree.
        private List<Clip> SortEmittable(Track track) =>
            track.Clips
                .Where(clip => clip.SourceClipType == ClipType.Sequence
                    ? clip.TrimStartFrame < (_resolveTimeline(clip.MediaRef)?.TotalFrames ?? 0)
                    : _resolver.ResolveUrl(clip.MediaRef) is not null)
                .OrderBy(c => c.StartFrame)
                .ToList();

        private void IndexAddresses(List<List<Clip>> sortedTracks, bool isAudio)
        {
            for (var ti = 0; ti < sortedTracks.Count; ti++)
            {
                var clips = sortedTracks[ti];
                for (var ci = 0; ci < clips.Count; ci++)
                {
                    _clipAddresses[clips[ci].Id] = new ClipAddress(ti + 1, ci + 1, isAudio);
                }
            }
        }

        private void IndexLinkGroups(Timeline timeline)
        {
            foreach (var track in timeline.Tracks)
            {
                foreach (var clip in track.Clips)
                {
                    if (clip.LinkGroupId is not { } group)
                    {
                        continue;
                    }
                    if (!_clipsByLinkGroup.TryGetValue(group, out var list))
                    {
                        list = [];
                        _clipsByLinkGroup[group] = list;
                    }
                    list.Add(clip);
                }
            }
        }

        private int? SourceDurationFrames(string mediaRef)
        {
            if (_resolver.Entry(mediaRef)?.Duration is not { } seconds)
            {
                return null;
            }
            return Math.Max(0, SwiftMath.SecondsToFrame(seconds, _fps));
        }

        /// Real fps → FCP7 (timebase, ntsc). NTSC rates (timebase×1000/1001: 29.97, 23.976, …) set ntsc TRUE.
        private static (int Timebase, bool Ntsc) RateTags(double rawFps)
        {
            var timebase = Math.Max(1, SwiftMath.RoundToInt(rawFps));
            var ntscRate = timebase * 1000.0 / 1001.0;
            return (timebase, Math.Abs(rawFps - ntscRate) < Math.Abs(rawFps - timebase));
        }

        // MARK: - Effect & parameter builders

        private static XmlNode Rate(int timebase, bool ntsc = false) =>
            El("rate", children: [Leaf("timebase", timebase), Bool("ntsc", ntsc)]);

        private static XmlNode Filter(XmlNode effect) => El("filter", children: [effect]);

        private static XmlNode Effect(string name, string id, string type, string mediatype, string? category = null, List<XmlNode>? body = null)
        {
            var children = new List<XmlNode> { Leaf("name", name), Leaf("effectid", id) };
            if (category is not null)
            {
                children.Add(Leaf("effectcategory", category));
            }
            children.Add(Leaf("effecttype", type));
            children.Add(Leaf("mediatype", mediatype));
            children.AddRange(body ?? []);
            return El("effect", children: children);
        }

        /// A `<parameter>`; `value` is its `<value>` node, optionally animated by `keyframes`.
        private static XmlNode Parameter(string id, string name, XmlNode value, string? min = null, string? max = null,
            List<(int When, XmlNode Value)>? keyframes = null)
        {
            var children = new List<XmlNode> { Leaf("parameterid", id), Leaf("name", name) };
            if (min is not null)
            {
                children.Add(Leaf("valuemin", min));
            }
            if (max is not null)
            {
                children.Add(Leaf("valuemax", max));
            }
            children.Add(value);
            children.AddRange((keyframes ?? []).Select(k => El("keyframe", children: [Leaf("when", k.When), k.Value])));
            return El("parameter", children: children);
        }

        /// Scalar `<parameter>` whose value (and keyframes) are numbers formatted to `decimals` places.
        private static XmlNode ScalarParam(string id, string name, string min, string max, double baseValue,
            List<(int When, double Value)>? keyframes = null, int decimals = 2) =>
            Parameter(id, name, Leaf("value", FormatFixed(baseValue, decimals)), min, max,
                (keyframes ?? []).Select(k => (k.When, (XmlNode)Leaf("value", FormatFixed(k.Value, decimals)))).ToList());

        /// Two-component Center `<parameter>` whose value is a `<horiz>`/`<vert>` pair.
        private static XmlNode CenterParam((double X, double Y) baseValue, List<(int When, double X, double Y)>? keyframes = null)
        {
            static XmlNode Vec(double x, double y) =>
                El("value", children: [Leaf("horiz", FormatFixed(x, 5)), Leaf("vert", FormatFixed(y, 5))]);
            return Parameter("center", "Center", Vec(baseValue.X, baseValue.Y),
                keyframes: (keyframes ?? []).Select(k => (k.When, Vec(k.X, k.Y))).ToList());
        }

        private static string FormatFixed(double value, int decimals) => value.ToString("F" + decimals, CultureInfo.InvariantCulture);
    }

    // MARK: - XML rendering

    /// A minimal XML tree. The emitters above describe document *structure*; `RenderXml` owns every
    /// bit of whitespace and escaping so no fragment ever hardcodes its own indentation.
    private sealed class XmlNode(string name, List<(string, string)>? attrs = null, string? text = null, List<XmlNode>? children = null)
    {
        public string Name { get; } = name;
        public List<(string, string)> Attributes { get; } = attrs ?? [];
        public string? Text { get; } = text;         // leaf value → `<name>text</name>`
        public List<XmlNode> Children { get; } = children ?? [];   // empty + no text → self-closing `<name/>`
    }

    private static XmlNode El(string name, List<XmlNode>? children = null) => new(name, children: children);
    private static XmlNode El(string name, List<(string, string)> attrs, List<XmlNode>? children = null) => new(name, attrs: attrs, children: children);
    private static XmlNode Leaf(string name, string value) => new(name, text: value);
    private static XmlNode Leaf(string name, int value) => new(name, text: value.ToString(CultureInfo.InvariantCulture));
    private static XmlNode Bool(string name, bool value) => new(name, text: value ? "TRUE" : "FALSE");

    private static string RenderXml(XmlNode node, int indent)
    {
        var pad = new string(' ', indent);
        var attrs = string.Concat(node.Attributes.Select(a => $" {a.Item1}=\"{EscapeXml(a.Item2)}\""));
        if (node.Text is { } text)
        {
            return $"{pad}<{node.Name}{attrs}>{EscapeXml(text)}</{node.Name}>";
        }
        if (node.Children.Count == 0)
        {
            return $"{pad}<{node.Name}{attrs}/>";
        }
        var inner = string.Join("\n", node.Children.Select(c => RenderXml(c, indent + 2)));
        return $"{pad}<{node.Name}{attrs}>\n{inner}\n{pad}</{node.Name}>";
    }

    private static string EscapeXml(string s) => s
        .Replace("&", "&amp;")
        .Replace("<", "&lt;")
        .Replace(">", "&gt;")
        .Replace("\"", "&quot;")
        .Replace("'", "&apos;");
}
