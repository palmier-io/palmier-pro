using System.Globalization;
using System.Text;
using System.Text.Json;
using PalmierPro.Core;
using PalmierPro.Core.Export;
using PalmierPro.Core.Models;
using PalmierPro.Services.Engine;

namespace PalmierPro.Services.Export;

/// The `version` attribute Resolve/FCP gate import on. Every element this exporter emits has
/// existed since FCPXML 1.1 — the body is version-identical.
public enum FcpxmlVersion
{
    V1_10,
    V1_11,
    V1_12,
    V1_13,
    V1_14,
}

public static class FcpxmlVersionExtensions
{
    /// 1.10 is the broadest: every Resolve from 18 up accepts it. Higher versions need Resolve 21+.
    public const FcpxmlVersion Default = FcpxmlVersion.V1_10;

    public static string RawValue(this FcpxmlVersion version) => version switch
    {
        FcpxmlVersion.V1_10 => "1.10",
        FcpxmlVersion.V1_11 => "1.11",
        FcpxmlVersion.V1_12 => "1.12",
        FcpxmlVersion.V1_13 => "1.13",
        FcpxmlVersion.V1_14 => "1.14",
        _ => throw new ArgumentOutOfRangeException(nameof(version)),
    };

    public static string CompatibilityNote(this FcpxmlVersion version) => version switch
    {
        FcpxmlVersion.V1_10 => "DaVinci Resolve 18+, Final Cut Pro 10.6+",
        FcpxmlVersion.V1_11 => "DaVinci Resolve 21+, Final Cut Pro 10.7+",
        FcpxmlVersion.V1_12 => "DaVinci Resolve 21+, Final Cut Pro 10.8+",
        FcpxmlVersion.V1_13 => "DaVinci Resolve 21+, Final Cut Pro 11+",
        FcpxmlVersion.V1_14 => "DaVinci Resolve 21+, Final Cut Pro 12+",
        _ => throw new ArgumentOutOfRangeException(nameof(version)),
    };
}

/// Resolve interprets several FCPXML values off-spec (trim-rect units, imported position scaled by
/// the conform fit at render); Final Cut is spec-literal. Same structure, different value encoding.
public enum FcpxmlTarget
{
    Resolve,
    Fcp,
}

public static class FcpxmlTargetExtensions
{
    public const FcpxmlTarget Default = FcpxmlTarget.Resolve;

    public static string DisplayName(this FcpxmlTarget target) => target switch
    {
        FcpxmlTarget.Resolve => "DaVinci Resolve",
        FcpxmlTarget.Fcp => "Final Cut Pro",
        _ => throw new ArgumentOutOfRangeException(nameof(target)),
    };
}

/// Exports a Timeline as FCPXML (for DaVinci Resolve / Final Cut Pro). Companion to XmemlExporter
/// (XMEML, for Premiere). Ported from Export/FCPXMLExporter.swift — read `Builder.Build` top-down:
/// `&lt;fcpxml&gt;` → `&lt;resources&gt;` (formats + assets + per-clip compound clips) →
/// `&lt;library&gt;/&lt;event&gt;/&lt;project&gt;/&lt;sequence&gt;`. The timeline is one `&lt;gap&gt;`
/// with every clip connected on a lane.
///
/// Encoding facts (reverse-engineered from Resolve round-trips):
/// - Position: unit = 1% of frame height, square, origin at center, +Y up; pre-divided by the
///   clip's per-axis conform-fit fraction (Resolve scales imported positions by it at render).
/// - Scale: multiplier on the conform-fit size, so we divide the aspect-fit out of width/height.
/// - Rotation: degrees, negated (FCP is counter-clockwise-positive). Flip: negative scale.
/// - Crop: `&lt;trim-rect&gt;` in Resolve's units — left/right: source px ÷ (seqHeight/100);
///   top/bottom: crop fraction ÷ conform-fit scale.
/// - Clips are flat `&lt;asset-clip&gt;`s (stills: `&lt;video&gt;`); only an A/V source played
///   one-sided rides a compound `&lt;media&gt;`/`&lt;ref-clip&gt;` (Resolve honors `srcEnable` only
///   on ref-clips).
/// - Retime: a `&lt;timeMap&gt;` on the clip ramps the whole media (output[0, media/speed] →
///   source[0, media]) and `start` windows in along the output axis (= source in-point ÷ speed).
///   A clip-local ramp blacks the tail.
/// - Keyframes: child `&lt;param&gt;/&lt;keyframeAnimation&gt;`; `time` is offset by `start` (the
///   output axis), `value` in the param's own unit. Volume: `&lt;adjust-volume amount&gt;` in dB.
///
/// Font resolution (family/face for `text-style`) is delegated to <see cref="IFontTraitResolver"/> —
/// the Windows replacement for the Mac's `NSFont`/`CTFontGetSymbolicTraits` pair.
///
/// Reference: https://developer.apple.com/documentation/professional-video-applications/fcpxml-reference
public static class FcpxmlExporter
{
    private static readonly Encoding Utf8NoBom = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false);
    private static readonly JsonSerializerOptions TextStyleJsonOptions = new();

    public static async Task ExportAsync(
        Timeline timeline,
        MediaResolver resolver,
        ISourceTimingReader timingReader,
        IFontTraitResolver fontResolver,
        string outputPath,
        Func<string, Timeline?>? resolveTimeline = null,
        FcpxmlVersion version = FcpxmlVersionExtensions.Default,
        FcpxmlTarget target = FcpxmlTargetExtensions.Default)
    {
        resolveTimeline ??= _ => null;

        // Media refs across the parent and every reachable nested timeline.
        var mediaRefs = new HashSet<string>();
        var queue = new List<Timeline> { timeline };
        var visited = new HashSet<string>();
        var i = 0;
        while (i < queue.Count)
        {
            var t = queue[i];
            i += 1;
            if (!visited.Add(t.Id))
            {
                continue;
            }
            foreach (var clip in t.Tracks.SelectMany(tr => tr.Clips))
            {
                if (clip.SourceClipType == ClipType.Sequence)
                {
                    if (resolveTimeline(clip.MediaRef) is { } child)
                    {
                        queue.Add(child);
                    }
                }
                else
                {
                    mediaRefs.Add(clip.MediaRef);
                }
            }
        }

        var timecodes = await timingReader.TimecodesAsync(mediaRefs, resolver.ExpectedUrlMap()).ConfigureAwait(false);
        var xml = Render(timeline, resolver, fontResolver, resolveTimeline, version, target, timecodes);
        File.WriteAllText(outputPath, xml, Utf8NoBom);
    }

    /// Build the document from an explicit timecode map. Split out so tests can inject embedded
    /// timecodes without a `tmcd`-carrying media file on disk.
    public static string Render(
        Timeline timeline,
        MediaResolver resolver,
        IFontTraitResolver fontResolver,
        Func<string, Timeline?>? resolveTimeline = null,
        FcpxmlVersion version = FcpxmlVersionExtensions.Default,
        FcpxmlTarget target = FcpxmlTargetExtensions.Default,
        IReadOnlyDictionary<string, SourceTimecode>? startTimecodes = null) =>
        new Builder(
            timeline, resolver, fontResolver, resolveTimeline ?? (_ => null),
            version, target, startTimecodes ?? new Dictionary<string, SourceTimecode>()).Build();

    private readonly record struct EmittableClip(Clip Clip, int Lane, bool Enabled);

    /// One asset per resolved source file.
    private sealed class MediaResource(
        string mediaRef, string assetId, string? formatId, string? compoundId,
        MediaManifestEntry entry, string url, int durationFrames, bool hasVideo, bool hasAudio, int startTimecodeFrames)
    {
        public string MediaRef { get; } = mediaRef;
        public string AssetId { get; } = assetId;
        public string? FormatId { get; } = formatId;
        public string? CompoundId { get; } = compoundId;
        public MediaManifestEntry Entry { get; } = entry;
        public string Url { get; } = url;
        public int DurationFrames { get; } = durationFrames;
        public bool HasVideo { get; } = hasVideo;
        public bool HasAudio { get; } = hasAudio;
        /// Embedded start timecode in timeline-frame units; 0 when absent.
        public int StartTimecodeFrames { get; } = startTimecodeFrames;
    }

    private sealed class ResourceCaps
    {
        public List<string> MediaRefs { get; } = [];
        public bool HasVideo { get; set; }
        public bool HasAudio { get; set; }
        public int Duration { get; set; }
        public required MediaManifestEntry Entry { get; init; }
        public required string Url { get; init; }
    }

    private sealed class Builder
    {
        private const string SequenceFormatId = "r1";
        private const string TitleEffectId = "titleBasic";

        private readonly Timeline _timeline;
        private readonly MediaResolver _resolver;
        private readonly IFontTraitResolver _fontResolver;
        private readonly Func<string, Timeline?> _resolveTimeline;
        private readonly FcpxmlVersion _version;
        private readonly FcpxmlTarget _target;
        private readonly IReadOnlyDictionary<string, SourceTimecode> _startTimecodes;
        private readonly int _fps;
        private readonly int _seqWidth;
        private readonly int _seqHeight;

        private readonly Dictionary<string, int> _resourceIndex = [];
        private readonly List<MediaResource> _resources = [];
        private int _nextTextStyleId = 1;
        // A synced A/V pair collapses into one flat asset-clip; the audio partner is dropped, its volume kept.
        private readonly Dictionary<string, Clip> _linkedAudioForVideo = [];
        private readonly HashSet<string> _redundantAudioClipIds = [];
        private readonly HashSet<string> _usedCompoundIds = [];
        // Nested timelines, discovery order; each becomes a <media><sequence> compound resource.
        private readonly List<(string MediaId, Timeline Timeline)> _nests = [];
        private readonly Dictionary<string, string> _nestIndex = [];

        public Builder(
            Timeline timeline, MediaResolver resolver, IFontTraitResolver fontResolver,
            Func<string, Timeline?> resolveTimeline, FcpxmlVersion version, FcpxmlTarget target,
            IReadOnlyDictionary<string, SourceTimecode> startTimecodes)
        {
            _timeline = timeline;
            _resolver = resolver;
            _fontResolver = fontResolver;
            _resolveTimeline = resolveTimeline;
            _version = version;
            _target = target;
            _startTimecodes = startTimecodes;
            _fps = Math.Max(1, timeline.Fps);
            _seqWidth = timeline.Width;
            _seqHeight = timeline.Height;
        }

        public string Build()
        {
            CollectNests();
            var clips = EmittableClips(_timeline);
            var nestedClips = _nests.SelectMany(n => EmittableClips(n.Timeline)).ToList();
            var allClips = clips.Concat(nestedClips).ToList();
            CollectResources(allClips);
            IndexLinkedPairs(allClips);
            MarkUsedCompounds(allClips);
            var hasTitles = allClips.Any(c => c.Clip.MediaType == ClipType.Text);
            var root = new FcpxmlNode("fcpxml", attrs: [("version", _version.RawValue())], children:
            [
                ResourcesNode(hasTitles),
                LibraryNode(clips),
            ]);
            return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE fcpxml>\n" + RenderFcpxml(root, 0);
        }

        /// Unresolvable or empty children stay out of `_nestIndex`, so `IsEmittable` drops their carriers.
        private void CollectNests()
        {
            var reachable = _timeline.ReachableTimelines(_resolveTimeline, NestFlattener.MaxDepth, t => t.TotalFrames > 0);
            foreach (var child in reachable)
            {
                var mediaId = $"nest{_nests.Count + 1}";
                _nestIndex[child.Id] = mediaId;
                _nests.Add((mediaId, child));
            }
        }

        // Video + audio with matching linkGroup, source, timing, and enabled state are a synced pair.
        private void IndexLinkedPairs(List<EmittableClip> clips)
        {
            var byGroup = new Dictionary<string, (List<EmittableClip> Videos, List<EmittableClip> Audios)>();
            foreach (var item in clips)
            {
                if (item.Clip.LinkGroupId is not { } group)
                {
                    continue;
                }
                if (!byGroup.TryGetValue(group, out var pair))
                {
                    pair = ([], []);
                    byGroup[group] = pair;
                }
                switch (item.Clip.MediaType)
                {
                    case ClipType.Video or ClipType.Image or ClipType.Sequence:
                        pair.Videos.Add(item);
                        break;
                    case ClipType.Audio:
                        pair.Audios.Add(item);
                        break;
                }
            }
            foreach (var (_, pair) in byGroup)
            {
                if (pair.Videos.Count != 1 || pair.Audios.Count != 1)
                {
                    continue;
                }
                var v = pair.Videos[0];
                var a = pair.Audios[0];
                if (v.Clip.MediaRef != a.Clip.MediaRef || v.Enabled != a.Enabled ||
                    v.Clip.StartFrame != a.Clip.StartFrame || v.Clip.DurationFrames != a.Clip.DurationFrames ||
                    v.Clip.TrimStartFrame != a.Clip.TrimStartFrame || Math.Abs(v.Clip.Speed - a.Clip.Speed) >= 0.0001)
                {
                    continue;
                }
                _linkedAudioForVideo[v.Clip.Id] = a.Clip;
                _redundantAudioClipIds.Add(a.Clip.Id);
            }
        }

        // Mirrors AssetClipNode's ref-clip condition; only referenced compounds get a <media> resource.
        private void MarkUsedCompounds(List<EmittableClip> clips)
        {
            foreach (var item in clips)
            {
                if (_redundantAudioClipIds.Contains(item.Clip.Id))
                {
                    continue;
                }
                if (!_resourceIndex.TryGetValue(item.Clip.MediaRef, out var i))
                {
                    continue;
                }
                if (_resources[i].CompoundId is not { } compoundId || _linkedAudioForVideo.ContainsKey(item.Clip.Id))
                {
                    continue;
                }
                _usedCompoundIds.Add(compoundId);
            }
        }

        private FcpxmlNode ResourcesNode(bool hasTitles)
        {
            var children = new List<FcpxmlNode>
            {
                new("format", attrs:
                [
                    ("id", SequenceFormatId),
                    ("name", SequenceFormatName(_seqWidth, _seqHeight, _fps)),
                    ("frameDuration", FrameDuration(_fps)),
                    ("width", _seqWidth.ToString(CultureInfo.InvariantCulture)),
                    ("height", _seqHeight.ToString(CultureInfo.InvariantCulture)),
                    ("colorSpace", "1-1-1 (Rec. 709)"),
                ]),
            };

            if (hasTitles)
            {
                children.Add(new FcpxmlNode("effect", attrs:
                [
                    ("id", TitleEffectId),
                    ("name", "Basic Title"),
                    ("uid", ".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti"),
                ]));
            }

            children.AddRange(_resources.Select(FormatNode).OfType<FcpxmlNode>());
            children.AddRange(_resources.Select(AssetNode));
            children.AddRange(_resources.Select(CompoundClipNode).OfType<FcpxmlNode>());
            children.AddRange(_nests.Select(NestFormatNode).OfType<FcpxmlNode>());
            children.AddRange(_nests.Select(NestMediaNode));
            return new FcpxmlNode("resources", children: children);
        }

        private string NestFormatId((string MediaId, Timeline Timeline) nest) =>
            nest.Timeline.Width == _seqWidth && nest.Timeline.Height == _seqHeight ? SequenceFormatId : $"{nest.MediaId}Format";

        private FcpxmlNode? NestFormatNode((string MediaId, Timeline Timeline) nest)
        {
            var formatId = NestFormatId(nest);
            if (formatId == SequenceFormatId)
            {
                return null;
            }
            return new FcpxmlNode("format", attrs:
            [
                ("id", formatId),
                ("name", SequenceFormatName(nest.Timeline.Width, nest.Timeline.Height, _fps)),
                ("frameDuration", FrameDuration(_fps)),
                ("width", nest.Timeline.Width.ToString(CultureInfo.InvariantCulture)),
                ("height", nest.Timeline.Height.ToString(CultureInfo.InvariantCulture)),
                ("colorSpace", "1-1-1 (Rec. 709)"),
            ]);
        }

        /// A nested timeline as a compound-clip resource: same gap-with-lanes shape as the project.
        private FcpxmlNode NestMediaNode((string MediaId, Timeline Timeline) nest)
        {
            var duration = Time(nest.Timeline.TotalFrames);
            var gap = new FcpxmlNode("gap", attrs:
            [
                ("name", "Timeline"), ("offset", "0s"), ("start", "0s"), ("duration", duration),
            ], children: StoryNodes(EmittableClips(nest.Timeline)));
            var sequence = new FcpxmlNode("sequence", attrs:
            [
                ("format", NestFormatId(nest)), ("duration", duration), ("tcStart", "0s"), ("tcFormat", "NDF"),
                ("audioLayout", "stereo"), ("audioRate", "48k"),
            ], children: [new FcpxmlNode("spine", children: [gap])]);
            return new FcpxmlNode("media", attrs: [("id", nest.MediaId), ("name", nest.Timeline.Name)], children: [sequence]);
        }

        private FcpxmlNode? CompoundClipNode(MediaResource resource)
        {
            if (resource.CompoundId is not { } compoundId || !_usedCompoundIds.Contains(compoundId))
            {
                return null;
            }
            var dur = Time(resource.DurationFrames);
            // The compound spine is 0-based but reads the asset from its own timecode origin, so
            // `start` must equal the asset's embedded start timecode.
            var tcStart = Time(resource.StartTimecodeFrames);
            var innerClip = new FcpxmlNode("asset-clip", attrs:
            [
                ("ref", resource.AssetId), ("name", FileName(resource)), ("duration", dur),
                ("start", tcStart), ("offset", "0s"), ("format", resource.FormatId ?? SequenceFormatId),
            ]);
            var sequence = new FcpxmlNode("sequence", attrs:
            [
                ("format", resource.FormatId ?? SequenceFormatId), ("duration", dur), ("tcStart", "0s"), ("tcFormat", "NDF"),
            ], children: [new FcpxmlNode("spine", children: [innerClip])]);
            return new FcpxmlNode("media", attrs: [("id", compoundId), ("name", FileName(resource))], children: [sequence]);
        }

        private FcpxmlNode LibraryNode(List<EmittableClip> clips) =>
            new("library", children:
            [
                new FcpxmlNode("event", attrs: [("name", "Palmier Export")], children: [ProjectNode(clips)]),
            ]);

        private FcpxmlNode ProjectNode(List<EmittableClip> clips)
        {
            var duration = Time(_timeline.TotalFrames);
            var spine = _timeline.TotalFrames > 0
                ? new FcpxmlNode("spine", children:
                  [
                      new FcpxmlNode("gap", attrs:
                      [
                          ("name", "Timeline"), ("offset", "0s"), ("start", "0s"), ("duration", duration),
                      ], children: StoryNodes(clips)),
                  ])
                : new FcpxmlNode("spine");

            return new FcpxmlNode("project", attrs: [("name", _timeline.Name)], children:
            [
                new FcpxmlNode("sequence", attrs:
                [
                    ("format", SequenceFormatId), ("duration", duration), ("tcStart", "0s"), ("tcFormat", "NDF"),
                    ("audioLayout", "stereo"), ("audioRate", "48k"),
                ], children: [spine]),
            ]);
        }

        private List<FcpxmlNode> StoryNodes(List<EmittableClip> clips) =>
            clips
                .Where(c => !_redundantAudioClipIds.Contains(c.Clip.Id))
                .OrderBy(c => c.Clip.StartFrame)
                .ThenBy(c => c.Lane)
                .Select(item => item.Clip.MediaType switch
                {
                    ClipType.Text => TitleNode(item),
                    ClipType.Audio or ClipType.Video or ClipType.Image or ClipType.Sequence => AssetClipNode(item),
                    ClipType.Lottie => null,
                    _ => throw new ArgumentOutOfRangeException(),
                })
                .OfType<FcpxmlNode>()
                .ToList();

        private FcpxmlNode? AssetClipNode(EmittableClip item)
        {
            var clip = item.Clip;

            // Nested timeline → <ref-clip> over its compound-clip media resource.
            if (clip.SourceClipType == ClipType.Sequence)
            {
                if (!_nestIndex.TryGetValue(clip.MediaRef, out var mediaId))
                {
                    return null;
                }
                var child = _resolveTimeline(clip.MediaRef);
                if (child is null)
                {
                    return null;
                }
                // A frozen carrier can outlive the child's current length; clamp to content.
                var duration = Math.Min(clip.DurationFrames, Math.Max(0, child.TotalFrames - clip.TrimStartFrame));
                if (duration <= 0)
                {
                    return null;
                }
                var attrs = new List<(string, string)>
                {
                    ("ref", mediaId), ("name", child.Name), ("lane", item.Lane.ToString(CultureInfo.InvariantCulture)),
                    ("offset", Time(clip.StartFrame)), ("start", Time(clip.TrimStartFrame)),
                    ("duration", Time(duration)), ("enabled", item.Enabled ? "1" : "0"),
                };
                if (clip.MediaType == ClipType.Audio)
                {
                    attrs.Add(("srcEnable", "audio"));
                    List<FcpxmlNode?> audioChildren = [VolumeNode(clip)];
                    return new FcpxmlNode("ref-clip", attrs: attrs, children: audioChildren.OfType<FcpxmlNode>().ToList());
                }
                var nestLinkedAudio = _linkedAudioForVideo.GetValueOrDefault(clip.Id);
                if (nestLinkedAudio is null)
                {
                    attrs.Add(("srcEnable", "video"));
                }
                List<FcpxmlNode?> videoChildren =
                [
                    new FcpxmlNode("adjust-conform", attrs: [("type", "fit")]),
                    CropNode(clip),
                    TransformNode(clip),
                    BlendNode(clip),
                    nestLinkedAudio is not null ? VolumeNode(nestLinkedAudio) : null,
                ];
                return new FcpxmlNode("ref-clip", attrs: attrs, children: videoChildren.OfType<FcpxmlNode>().ToList());
            }

            if (!_resourceIndex.TryGetValue(clip.MediaRef, out var i))
            {
                return null;
            }
            var resource = _resources[i];
            var linkedAudio = _linkedAudioForVideo.GetValueOrDefault(clip.Id);

            // One-sided A/V rides the compound (Resolve honors srcEnable only on ref-clips);
            // everything else exports flat.
            if (resource.CompoundId is { } compoundId && linkedAudio is null)
            {
                var videoOnly = clip.MediaType != ClipType.Audio;
                var compoundAttrs = new List<(string, string)>
                {
                    ("ref", compoundId), ("name", FileName(resource)), ("lane", item.Lane.ToString(CultureInfo.InvariantCulture)),
                    ("offset", Time(clip.StartFrame)), ("start", ClipStart(clip)),
                    ("duration", Time(clip.DurationFrames)), ("enabled", item.Enabled ? "1" : "0"),
                    ("srcEnable", videoOnly ? "video" : "audio"),
                };
                // Child order is DTD-fixed: timeMap, crop, conform, transform, blend, volume.
                List<FcpxmlNode?> compoundChildren = videoOnly
                    ?
                    [
                        TimeMapNode(clip, resource.DurationFrames), CropNode(clip),
                        new FcpxmlNode("adjust-conform", attrs: [("type", "fit")]), TransformNode(clip), BlendNode(clip),
                    ]
                    : [TimeMapNode(clip, resource.DurationFrames), VolumeNode(clip)];
                return new FcpxmlNode("ref-clip", attrs: compoundAttrs, children: compoundChildren.OfType<FcpxmlNode>().ToList());
            }

            var origin = resource.StartTimecodeFrames;
            var visual = clip.MediaType != ClipType.Audio;
            var flatAttrs = new List<(string, string)>
            {
                ("ref", resource.AssetId), ("name", FileName(resource)), ("lane", item.Lane.ToString(CultureInfo.InvariantCulture)),
                ("offset", Time(clip.StartFrame)), ("start", ClipStart(clip, origin)),
                ("duration", Time(clip.DurationFrames)), ("enabled", item.Enabled ? "1" : "0"),
            };
            List<FcpxmlNode?> flatChildren =
            [
                TimeMapNode(clip, resource.DurationFrames, origin),
                visual ? CropNode(clip) : null,
                visual ? new FcpxmlNode("adjust-conform", attrs: [("type", "fit")]) : null,
                visual ? TransformNode(clip) : null,
                visual ? BlendNode(clip) : null,
                resource.HasAudio ? VolumeNode(linkedAudio ?? clip) : null,
            ];
            // Stills export as <video>, the shape FCP itself writes.
            return new FcpxmlNode(clip.MediaType == ClipType.Image ? "video" : "asset-clip",
                attrs: flatAttrs, children: flatChildren.OfType<FcpxmlNode>().ToList());
        }

        private FcpxmlNode? TitleNode(EmittableClip item)
        {
            var clip = item.Clip;
            if (string.IsNullOrEmpty(clip.TextContent))
            {
                return null;
            }
            var style = ResolveTextStyle(clip);
            var styleId = $"textStyle{_nextTextStyleId}";
            _nextTextStyleId += 1;

            var textNodes = new List<FcpxmlNode>
            {
                new("text", children: [new FcpxmlNode("text-style", attrs: [("ref", styleId)], text: clip.TextContent)]),
                new("text-style-def", attrs: [("id", styleId)], children:
                [
                    new FcpxmlNode("text-style", attrs: TextStyleAttributes(style)),
                ]),
            };
            textNodes.AddRange(TitleTransformNodes(clip.Transform));
            if (BlendNode(clip) is { } blend)
            {
                textNodes.Add(blend);
            }
            return new FcpxmlNode("title", attrs:
            [
                ("ref", TitleEffectId),
                ("name", clip.TextContent),
                ("lane", item.Lane.ToString(CultureInfo.InvariantCulture)),
                ("offset", Time(clip.StartFrame)),
                ("start", "0s"),
                ("duration", Time(clip.DurationFrames)),
                ("enabled", item.Enabled ? "1" : "0"),
            ], children: textNodes);
        }

        private static TextStyle ResolveTextStyle(Clip clip) =>
            clip.TextStyle is { } json ? json.Deserialize<TextStyle>(TextStyleJsonOptions) ?? new TextStyle() : new TextStyle();

        private FcpxmlNode? BlendNode(Clip clip)
        {
            var frames = clip.KeyframeFrames(AnimatableProperty.Opacity);
            if (!(clip.Opacity < 0.9995 || frames.Count > 0))
            {
                return null;
            }
            var children = new List<FcpxmlNode>();
            if (frames.Count > 0)
            {
                children.Add(KeyframeParam("amount", FormatNumber(clip.Opacity), clip, AnimatableProperty.Opacity, frames,
                    f => FormatNumber(clip.RawOpacityAt(f))));
            }
            return new FcpxmlNode("adjust-blend", attrs: [("amount", FormatNumber(clip.Opacity))], children: children);
        }

        /// Position + scale + rotation (static or keyframed) for a video/image clip.
        private FcpxmlNode? TransformNode(Clip clip)
        {
            var t = clip.Transform;
            var posFrames = clip.KeyframeFrames(AnimatableProperty.Position);
            var rotFrames = clip.KeyframeFrames(AnimatableProperty.Rotation);
            var scaleFrames = clip.KeyframeFrames(AnimatableProperty.Scale);
            var baseScale = ScaleValue(t.Width, t.Height, clip);
            var moved = Math.Abs(t.CenterX - 0.5) > 0.0005 || Math.Abs(t.CenterY - 0.5) > 0.0005;
            var rotated = Math.Abs(t.Rotation) > 0.005;
            var scaled = baseScale != "1 1";
            if (!(moved || rotated || scaled || posFrames.Count > 0 || rotFrames.Count > 0 || scaleFrames.Count > 0))
            {
                return null;
            }

            var fit = _target == FcpxmlTarget.Resolve ? FitFractions(clip) : (W: 1.0, H: 1.0);
            var attrs = new List<(string, string)> { ("scale", baseScale) };
            if (rotated || rotFrames.Count > 0)
            {
                attrs.Add(("rotation", FormatNumber(-t.Rotation)));
            }
            attrs.Add(("anchor", "0 0"));
            attrs.Add(("position", PositionValue(t, fit)));

            var parameters = new List<FcpxmlNode>();
            if (scaleFrames.Count > 0)
            {
                parameters.Add(KeyframeParam("scale", baseScale, clip, AnimatableProperty.Scale, scaleFrames, f =>
                {
                    var s = clip.SizeAt(f);
                    return ScaleValue(s.Width, s.Height, clip);
                }));
            }
            if (posFrames.Count > 0)
            {
                parameters.Add(KeyframeParam("position", PositionValue(t, fit), clip, AnimatableProperty.Position, posFrames,
                    f => PositionValue(clip.TransformAt(f), fit)));
            }
            if (rotFrames.Count > 0)
            {
                parameters.Add(KeyframeParam("rotation", FormatNumber(-t.Rotation), clip, AnimatableProperty.Rotation, rotFrames,
                    f => FormatNumber(-clip.RotationAt(f))));
            }
            return new FcpxmlNode("adjust-transform", attrs: attrs, children: parameters);
        }

        /// Divide the aspect-fit out of our frame-fraction width/height so only user scaling remains.
        private string ScaleValue(double width, double height, Clip clip)
        {
            var fit = FitFractions(clip);
            var sx = width / fit.W;
            var sy = height / fit.H;
            if (clip.Transform.FlipHorizontal)
            {
                sx = -sx;
            }
            if (clip.Transform.FlipVertical)
            {
                sy = -sy;
            }
            return $"{FormatNumber(sx)} {FormatNumber(sy)}";
        }

        /// A keyframed `<param>`: time is in the clip's output axis, value uses the param's own unit.
        private FcpxmlNode KeyframeParam(string name, string baseValue, Clip clip, AnimatableProperty property,
            List<int> frames, Func<int, string> value)
        {
            var keyframes = frames.OrderBy(f => f).Select(f =>
            {
                var attrs = new List<(string, string)> { ("time", KeyframeTime(f, clip)) };
                if (clip.InterpolationAt(property, f) == Interpolation.Linear)
                {
                    attrs.Add(("curve", "linear"));
                }
                attrs.Add(("value", value(f)));
                return new FcpxmlNode("keyframe", attrs: attrs);
            }).ToList();
            return new FcpxmlNode("param", attrs: [("name", name), ("value", baseValue)], children:
            [
                new FcpxmlNode("keyframeAnimation", children: keyframes),
            ]);
        }

        /// A retimed clip's keyframes live in the timeMap's output axis, so `time` is offset by the
        /// clip's `start` (= ClipStart): `start + (f − startFrame)/fps`. Unspeeded clips have no
        /// timeMap origin, so they stay clip-relative.
        private string KeyframeTime(int f, Clip clip)
        {
            if (Math.Abs(clip.Speed - 1.0) <= 0.001)
            {
                return Time(f - clip.StartFrame);
            }
            var (p, q) = RationalSpeed(clip.Speed);
            var num = clip.TrimStartFrame * q + (f - clip.StartFrame) * p;
            return RationalTime(num, _fps * p);
        }

        /// Resolve's trim-rect units: left/right = source px ÷ (seqHeight/100); top/bottom = crop
        /// fraction ÷ conform-fit scale. FCP (and unknown source dims): plain percentages.
        private FcpxmlNode? CropNode(Clip clip)
        {
            var c = clip.Crop;
            if (c.IsIdentity)
            {
                return null;
            }
            double lr = 100.0, tb = 100.0;
            if (_target == FcpxmlTarget.Resolve &&
                _resolver.Entry(clip.MediaRef) is { SourceWidth: { } sw, SourceHeight: { } sh } && sw > 0 && sh > 0)
            {
                var fit = Math.Min((double)_seqWidth / sw, (double)_seqHeight / sh);
                lr = sw * 100.0 / _seqHeight;
                tb = 100.0 / fit;
            }
            return new FcpxmlNode("adjust-crop", attrs: [("mode", "trim")], children:
            [
                new FcpxmlNode("trim-rect", attrs:
                [
                    ("top", FormatNumber(c.Top * tb)),
                    ("right", FormatNumber(c.Right * lr)),
                    ("bottom", FormatNumber(c.Bottom * tb)),
                    ("left", FormatNumber(c.Left * lr)),
                ]),
            ]);
        }

        private FcpxmlNode? VolumeNode(Clip clip)
        {
            // Keyframed audio volume has no FCPXML form Resolve round-trips (its own export drops
            // it), so export the static level only.
            if (Math.Abs(clip.Volume - 1.0) <= 0.0005)
            {
                return null;
            }
            return new FcpxmlNode("adjust-volume", attrs: [("amount", FormatNumber(Decibels(clip.Volume)))]);
        }

        private static double Decibels(double linear) => linear > 0 ? 20.0 * Math.Log10(linear) : -96.0;

        /// Source in-point in the post-retime output axis Resolve expects (source ÷ speed); the raw
        /// source frame when unspeeded. `origin` is the asset's embedded start timecode, added only
        /// to the unspeeded case (a retimed clip carries its origin in the timeMap values, not `start`).
        private string ClipStart(Clip clip, int origin = 0)
        {
            if (Math.Abs(clip.Speed - 1.0) <= 0.001)
            {
                return Time(origin + clip.TrimStartFrame);
            }
            var (p, q) = RationalSpeed(clip.Speed);
            return RationalTime(clip.TrimStartFrame * q, _fps * p);
        }

        /// Resolve ramps the WHOLE media (`output[0, media/speed] → source[0, media]`) and windows in
        /// via `start`/`duration`. A ramp that stops at the clip edge leaves no tail mapping → black
        /// last frames.
        private FcpxmlNode? TimeMapNode(Clip clip, int mediaFrames, int origin = 0)
        {
            if (Math.Abs(clip.Speed - 1.0) <= 0.001 || mediaFrames <= 0)
            {
                return null;
            }
            var (p, q) = RationalSpeed(clip.Speed);
            return new FcpxmlNode("timeMap", attrs: [("frameSampling", "floor")], children:
            [
                new FcpxmlNode("timept", attrs:
                [
                    ("time", "0s"), ("value", Time(origin)), ("interp", "linear"),
                ]),
                new FcpxmlNode("timept", attrs:
                [
                    ("time", RationalTime(mediaFrames * q, _fps * p)),  // media / speed
                    ("value", Time(origin + mediaFrames)),              // full media from origin
                    ("interp", "linear"),
                ]),
            ]);
        }

        /// Speed as a small-denominator fraction, so the timeMap slope is exact and `start` maps back
        /// to the original source frame. Speeds are user values (1.25, 1.24, 2.0, 0.5…).
        private static (int P, int Q) RationalSpeed(double speed)
        {
            (int P, int Q) best = (1, 1);
            var bestErr = double.PositiveInfinity;
            for (var q = 1; q <= 1000; q++)
            {
                var p = SwiftMath.RoundToInt(speed * q);
                if (p <= 0)
                {
                    continue;
                }
                var err = Math.Abs(speed - (double)p / q);
                if (err < bestErr)
                {
                    best = (p, q);
                    bestErr = err;
                    if (err == 0)
                    {
                        break;
                    }
                }
            }
            return best;
        }

        private static string RationalTime(int num, int den)
        {
            if (num == 0)
            {
                return "0s";
            }
            var g = Gcd(Math.Abs(num), Math.Abs(den));
            var n = num / g;
            var d = den / g;
            return d == 1 ? $"{n}s" : $"{n}/{d}s";
        }

        private void CollectResources(List<EmittableClip> clips)
        {
            var order = new List<string>();
            var caps = new Dictionary<string, ResourceCaps>();

            foreach (var item in clips)
            {
                var clip = item.Clip;
                if (clip.MediaType is ClipType.Text or ClipType.Lottie)
                {
                    continue;
                }
                var entry = _resolver.Entry(clip.MediaRef);
                var url = _resolver.ResolveUrl(clip.MediaRef);
                if (entry is null || url is null)
                {
                    continue;
                }

                var key = SourceKey(url);
                var duration = SourceDurationFrames(entry, clip);
                var isVisual = clip.MediaType != ClipType.Audio;
                // Audio clip → audio stream; video clip → audio too if the source file carries it.
                var isAudio = clip.MediaType == ClipType.Audio || (clip.MediaType == ClipType.Video && entry.HasAudio == true);
                if (!caps.TryGetValue(key, out var entryCaps))
                {
                    order.Add(key);
                    entryCaps = new ResourceCaps { Entry = entry, Url = url };
                    caps[key] = entryCaps;
                }
                if (!entryCaps.MediaRefs.Contains(clip.MediaRef))
                {
                    entryCaps.MediaRefs.Add(clip.MediaRef);
                }
                entryCaps.HasVideo = entryCaps.HasVideo || isVisual;
                entryCaps.HasAudio = entryCaps.HasAudio || isAudio;
                entryCaps.Duration = Math.Max(entryCaps.Duration, duration);
            }

            foreach (var key in order)
            {
                if (!caps.TryGetValue(key, out var c))
                {
                    continue;
                }
                var id = _resources.Count + 1;
                foreach (var reference in c.MediaRefs)
                {
                    _resourceIndex[reference] = _resources.Count;
                }
                var tcFrames = c.MediaRefs
                    .Select(r => _startTimecodes.TryGetValue(r, out var tc) ? (SourceTimecode?)tc : null)
                    .FirstOrDefault(tc => tc is not null)?.FramesAtFps(_fps) ?? 0;
                _resources.Add(new MediaResource(
                    mediaRef: c.MediaRefs.FirstOrDefault() ?? c.Entry.Id,
                    assetId: $"asset{id}",
                    formatId: c.HasVideo ? $"r{id + 1}" : null,
                    // Only an A/V source can need srcEnable gating, so only it gets a compound.
                    compoundId: c.HasVideo && c.HasAudio ? $"media{id}" : null,
                    entry: c.Entry,
                    url: c.Url,
                    durationFrames: c.Duration,
                    hasVideo: c.HasVideo,
                    hasAudio: c.HasAudio,
                    startTimecodeFrames: tcFrames));
            }
        }

        private static string SourceKey(string url) => Path.GetFullPath(url);

        private FcpxmlNode? FormatNode(MediaResource resource)
        {
            if (resource.FormatId is not { } formatId)
            {
                return null;
            }
            var width = resource.Entry.SourceWidth ?? _seqWidth;
            var height = resource.Entry.SourceHeight ?? _seqHeight;
            var rawFps = resource.Entry.SourceFPS ?? _fps;
            return new FcpxmlNode("format", attrs:
            [
                ("id", formatId),
                ("name", VideoFormatName(width, height, rawFps)),
                ("frameDuration", FrameDuration(rawFps)),
                ("width", width.ToString(CultureInfo.InvariantCulture)),
                ("height", height.ToString(CultureInfo.InvariantCulture)),
                ("colorSpace", "1-1-1 (Rec. 709)"),
            ]);
        }

        // Resolve relinks by matching the `name` attribute to the file on disk, so the extension must
        // be present — a stripped name shows every clip as Media Offline.
        private static string FileName(MediaResource resource) => Path.GetFileName(resource.Url);

        private FcpxmlNode AssetNode(MediaResource resource)
        {
            var attrs = new List<(string, string)>
            {
                ("id", resource.AssetId),
                ("name", FileName(resource)),
                ("start", Time(resource.StartTimecodeFrames)),
                ("duration", Time(resource.DurationFrames)),
            };
            if (resource.HasVideo)
            {
                attrs.Add(("hasVideo", "1"));
                attrs.Add(("videoSources", "1"));
                if (resource.FormatId is { } formatId)
                {
                    attrs.Add(("format", formatId));
                }
            }
            if (resource.HasAudio)
            {
                // We don't probe channels/rate; 2ch/48k is FCP's default and doesn't affect relinking.
                attrs.Add(("hasAudio", "1"));
                attrs.Add(("audioSources", "1"));
                attrs.Add(("audioChannels", "2"));
                attrs.Add(("audioRate", "48000"));
            }
            return new FcpxmlNode("asset", attrs: attrs, children:
            [
                new FcpxmlNode("media-rep", attrs: [("kind", "original-media"), ("src", MediaSrc(resource))]),
            ]);
        }

        // Percent-encode the sub-delims .NET's Uri leaves literal — Resolve's relinker fails on
        // their XML-entity forms (&amp;apos;).
        private static string MediaSrc(MediaResource resource)
        {
            var absoluteUri = new Uri(resource.Url).AbsoluteUri;
            var sb = new StringBuilder(absoluteUri.Length);
            foreach (var ch in absoluteUri)
            {
                if ("'!$&()*+,;=".IndexOf(ch) >= 0)
                {
                    sb.Append('%').Append(((byte)ch).ToString("X2", CultureInfo.InvariantCulture));
                }
                else
                {
                    sb.Append(ch);
                }
            }
            return sb.ToString();
        }

        private int SourceDurationFrames(MediaManifestEntry entry, Clip clip)
        {
            var manifestFrames = Math.Max(0, SwiftMath.SecondsToFrame(entry.Duration, _fps));
            return Math.Max(manifestFrames, clip.SourceDurationFrames);
        }

        private List<EmittableClip> EmittableClips(Timeline timeline)
        {
            var visualTrackCount = timeline.Tracks.Count(t => t.Type.IsVisual());
            var visualOrdinal = 0;
            var audioOrdinal = 0;
            var clips = new List<EmittableClip>();

            foreach (var track in timeline.Tracks)
            {
                int lane;
                bool enabled;
                if (track.Type.IsVisual())
                {
                    lane = visualTrackCount - visualOrdinal;
                    enabled = !track.Hidden;
                    visualOrdinal += 1;
                }
                else if (track.Type == ClipType.Audio)
                {
                    lane = -(audioOrdinal + 1);
                    enabled = !track.Muted;
                    audioOrdinal += 1;
                }
                else
                {
                    continue;
                }
                clips.AddRange(track.Clips
                    .Where(IsEmittable)
                    .OrderBy(c => c.StartFrame)
                    .Select(c => new EmittableClip(c, lane, enabled)));
            }
            return clips;
        }

        private bool IsEmittable(Clip clip)
        {
            if (clip.DurationFrames <= 0)
            {
                return false;
            }
            // Nest carriers emit when their child timeline resolved to a compound resource.
            if (clip.SourceClipType == ClipType.Sequence)
            {
                return _nestIndex.ContainsKey(clip.MediaRef);
            }
            return clip.MediaType switch
            {
                ClipType.Text => !string.IsNullOrEmpty(clip.TextContent),
                ClipType.Lottie or ClipType.Sequence => false,
                ClipType.Audio or ClipType.Video or ClipType.Image => _resolver.ResolveUrl(clip.MediaRef) is not null,
                _ => throw new ArgumentOutOfRangeException(),
            };
        }

        private string Time(int frames)
        {
            if (frames == 0)
            {
                return "0s";
            }
            var divisor = Gcd(Math.Abs(frames), _fps);
            var numerator = frames / divisor;
            var denominator = _fps / divisor;
            return denominator == 1 ? $"{numerator}s" : $"{numerator}/{denominator}s";
        }

        private static string VideoFormatName(int width, int height, double rawFps) =>
            RecognizedVideoFormatName(width, height, rawFps) ?? $"FFVideoFormat{width}x{height}p{FormatRateSuffix(rawFps)}";

        private static string SequenceFormatName(int width, int height, double rawFps) =>
            RecognizedVideoFormatName(width, height, rawFps) ?? "FFVideoFormatRateUndefined";

        private static string? RecognizedVideoFormatName(int width, int height, double rawFps)
        {
            var rate = FormatRateSuffix(rawFps);
            return (width, height) switch
            {
                (1280, 720) => $"FFVideoFormat720p{rate}",
                (1920, 1080) => $"FFVideoFormat1080p{rate}",
                (3840, 2160) => $"FFVideoFormat3840x2160p{rate}",
                (4096, 2160) => $"FFVideoFormat4096x2160p{rate}",
                _ => null,
            };
        }

        private static string FormatRateSuffix(double rawFps)
        {
            var rounded = Math.Max(1, SwiftMath.RoundToInt(rawFps));
            var ntscRate = rounded * 1000.0 / 1001.0;
            if (Math.Abs(rawFps - ntscRate) < Math.Abs(rawFps - rounded))
            {
                var fps100 = SwiftMath.RoundToInt(ntscRate * 100.0);
                return $"{fps100 / 100}{(fps100 % 100).ToString("D2", CultureInfo.InvariantCulture)}";
            }
            return rounded.ToString(CultureInfo.InvariantCulture);
        }

        private static string FrameDuration(double rawFps)
        {
            var rounded = Math.Max(1, SwiftMath.RoundToInt(rawFps));
            var ntscRate = rounded * 1000.0 / 1001.0;
            if (Math.Abs(rawFps - ntscRate) < Math.Abs(rawFps - rounded))
            {
                return $"1001/{rounded * 1000}s";
            }
            return $"1/{rounded}s";
        }

        private static string ColorString(TextStyleRgba color) =>
            $"{FormatNumber(color.R)} {FormatNumber(color.G)} {FormatNumber(color.B)} {FormatNumber(color.A)}";

        private List<(string, string)> TextStyleAttributes(TextStyle style)
        {
            var resolved = _fontResolver.Resolve(style.FontName, style.FontSize, style.IsBold, style.IsItalic);
            var fontSize = style.FontSize * style.FontScale;
            var attrs = new List<(string, string)>
            {
                ("font", resolved.Family),
                ("fontFace", resolved.Face),
                ("fontSize", FormatNumber(fontSize)),
                ("fontColor", ColorString(style.Color)),
                ("alignment", AlignmentRawValue(style.Alignment)),
            };
            if (style.Border.Enabled)
            {
                // GlyphBorderStrokeWidth is NSAttributedString's percent-of-font-size convention.
                attrs.Add(("strokeColor", ColorString(style.Border.Color)));
                attrs.Add(("strokeWidth", FormatNumber(Math.Abs(TextStyle.GlyphBorderStrokeWidth) / 100 * fontSize)));
            }
            return attrs;
        }

        private static string AlignmentRawValue(TextStyleAlignment alignment) => alignment switch
        {
            TextStyleAlignment.Left => "left",
            TextStyleAlignment.Center => "center",
            TextStyleAlignment.Right => "right",
            _ => throw new ArgumentOutOfRangeException(nameof(alignment)),
        };

        private List<FcpxmlNode> TitleTransformNodes(Transform transform) =>
        [
            new("adjust-conform", attrs: [("type", "fit")]),
            new FcpxmlNode("adjust-transform", attrs:
            [
                ("scale", "1 1"), ("anchor", "0 0"), ("position", PositionValue(transform, (1, 1))),
            ]),
        ];

        private string PositionValue(Transform transform, (double W, double H) fit)
        {
            var unit = _seqHeight / 100.0;
            var x = (transform.CenterX - 0.5) * _seqWidth / unit / fit.W;
            var y = (0.5 - transform.CenterY) * _seqHeight / unit / fit.H;
            return $"{FormatNumber(x)} {FormatNumber(y)}";
        }

        /// Per-axis conform-fit fractions of the sequence frame; 1×1 when source dims are unknown.
        private (double W, double H) FitFractions(Clip clip)
        {
            if (_resolver.Entry(clip.MediaRef) is not { SourceWidth: { } sw, SourceHeight: { } sh } || sw <= 0 || sh <= 0)
            {
                return (1, 1);
            }
            var sourceAspect = (double)sw / sh;
            var frameAspect = (double)_seqWidth / _seqHeight;
            return sourceAspect >= frameAspect ? (1, frameAspect / sourceAspect) : (sourceAspect / frameAspect, 1);
        }

        private static string FormatNumber(double value)
        {
            var rounded = SwiftMath.Round(value * 10000) / 10000;
            if (rounded == SwiftMath.Round(rounded))
            {
                return ((long)SwiftMath.Round(rounded)).ToString(CultureInfo.InvariantCulture);
            }
            var s = rounded.ToString("F4", CultureInfo.InvariantCulture);
            s = s.TrimEnd('0');
            if (s.EndsWith('.'))
            {
                s = s[..^1];
            }
            return s;
        }

        private static int Gcd(int a, int b)
        {
            int x = a, y = b;
            while (y != 0)
            {
                var r = x % y;
                x = y;
                y = r;
            }
            return Math.Max(1, x);
        }
    }

    private sealed class FcpxmlNode(string name, List<(string, string)>? attrs = null, string? text = null, List<FcpxmlNode>? children = null)
    {
        public string Name { get; } = name;
        public List<(string, string)> Attrs { get; } = attrs ?? [];
        public string? Text { get; } = text;
        public List<FcpxmlNode> Children { get; } = children ?? [];
    }

    private static string RenderFcpxml(FcpxmlNode node, int indent)
    {
        var pad = new string(' ', indent);
        var attrs = string.Concat(node.Attrs.Select(a => $" {a.Item1}=\"{EscapeFcpxml(a.Item2)}\""));
        if (node.Text is { } text)
        {
            return $"{pad}<{node.Name}{attrs}>{EscapeFcpxml(text)}</{node.Name}>";
        }
        if (node.Children.Count == 0)
        {
            return $"{pad}<{node.Name}{attrs}/>";
        }
        var inner = string.Join("\n", node.Children.Select(c => RenderFcpxml(c, indent + 2)));
        return $"{pad}<{node.Name}{attrs}>\n{inner}\n{pad}</{node.Name}>";
    }

    private static string EscapeFcpxml(string s) => s
        .Replace("&", "&amp;")
        .Replace("<", "&lt;")
        .Replace(">", "&gt;")
        .Replace("\"", "&quot;")
        .Replace("'", "&apos;");
}
