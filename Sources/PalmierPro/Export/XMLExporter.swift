import AVFoundation
import Foundation

/// Exports a Timeline as XMEML 4 (Final Cut Pro 7 XML)
///
/// There are two formats for timeline data: XMEML and FCPXML.
/// FCPXML is the newer format that supports more features. But Premiere Pro does not support it natively.
/// If we choose FCPXML, users need to use DaVinci as a bridge or 3rd party software to translate .fcpxml to .xml.
/// Premiere Pro is the current priority so we went with XMEML, even tho its already deprecated.
///
/// How to read this file: the document is built as an `XMLNode` tree (defined at the bottom).
/// Every `el(...)` / `leaf(...)` call is one XML element; `render` owns all indentation and
/// escaping, so no emitter hardcodes whitespace. Read `build()` top-down to see the format: the
/// `<xmeml><sequence><media>` shell, then tracks → clipitems → files / filters / links.
///
/// What transports:
/// - Clip placement & trims → `<clipitem>` `<start>`/`<end>`/`<in>`/`<out>`
/// - Speed → Time Remap filter
/// - Volume (static + keyframed) → Audio Levels filter
/// - Opacity (static + keyframed) → its own Opacity filter
/// - Transform — scale / rotation / position (static + keyframed) → Basic Motion filter
/// - Crop (static + keyframed) → Crop filter
/// - Fade in/out → single-sided transition (Cross Dissolve for video, Cross Fade for audio)
/// - Linked A/V clips → reciprocal `<link>` blocks
/// - Source frame rate → per-file NTSC flag (29.97/23.976/59.94 → ntsc TRUE)
/// - Nested timelines → nested `<sequence>` inside the carrier clipitem (full definition on
///   first use, id reference after — Premiere's own convention); recursive, frozen carriers
///   clamp to the child's length, empty/missing children drop
///
/// What does NOT transport:
/// - Text overlays. FCPXML supports this, not XMEML.
/// - Flips (horizontal/vertical)
/// - Keyframe interpolation curves (linear/hold/smooth): keyframes import with default easing
/// - Adjustments and effects (Clip.effects): Core Image stacks have no XMEML representation
///
/// Coordinates are in timeline frames; FCP7 rotation is counter-clockwise-positive, so we negate our clockwise-positive values.
/// 
/// References:
/// XMEML: https://developer.apple.com/library/archive/documentation/AppleApplications/Reference/FinalCutPro_XML/VersionsoftheInterchangeFormat/VersionsoftheInterchangeFormat.html
/// FCPXML: https://developer.apple.com/documentation/professional-video-applications/fcpxml-reference

enum XMLExporter {

    static func export(timeline: Timeline, resolver: MediaResolver,
                       resolveTimeline: @escaping @Sendable (String) -> Timeline? = { _ in nil },
                       outputURL: URL) async throws {
        let startFrameCache = await sourceTimecodeCache(timeline: timeline, resolver: resolver, resolveTimeline: resolveTimeline)
        let xml = render(timeline: timeline, resolver: resolver, resolveTimeline: resolveTimeline, startFrameCache: startFrameCache)
        guard let data = xml.data(using: .utf8) else { throw ExportError.xmlEncodingFailed }
        try data.write(to: outputURL)
    }

    /// Renders synchronously for deterministic tests.
    static func render(timeline: Timeline, resolver: MediaResolver,
                       resolveTimeline: @escaping (String) -> Timeline? = { _ in nil },
                       startFrameCache: [String: SourceTimecode] = [:]) -> String {
        Builder(timeline: timeline, resolver: resolver, resolveTimeline: resolveTimeline,
                startFrameCache: startFrameCache).build()
    }

    private static func sourceTimecodeCache(
        timeline: Timeline, resolver: MediaResolver, resolveTimeline: (String) -> Timeline?
    ) async -> [String: SourceTimecode] {
        var mediaRefs: Set<String> = []
        for t in [timeline] + timeline.reachableTimelines(resolve: resolveTimeline) {
            for clip in t.tracks.flatMap(\.clips) where clip.sourceClipType != .sequence {
                mediaRefs.insert(clip.mediaRef)
            }
        }
        return await SourceTimingReader.timecodes(mediaRefs: mediaRefs, urls: resolver.expectedURLMap())
    }

    // MARK: - Source timecode

    /// Builds file timecode fields from embedded metadata or the video rate.
    static func timecodeTags(source: SourceTimecode?, videoTimebase: Int, videoNtsc: Bool)
        -> (base: Int, ntsc: Bool, frame: Int, dropFrame: Bool, string: String) {
        // BWF time references use samples, so rescale them to the video rate.
        if let source, source.quanta > 240 {
            let effectiveFPS = videoNtsc ? Double(videoTimebase) * 1000 / 1001 : Double(videoTimebase)
            let dropFrame = videoNtsc && videoTimebase % 30 == 0
            let frame = Int((source.seconds * effectiveFPS).rounded())
            return (videoTimebase, videoNtsc, frame, dropFrame,
                    formatTimecode(frame: frame, fps: videoTimebase, dropFrame: dropFrame))
        }
        let base = source?.quanta ?? videoTimebase
        let dropFrame = source?.dropFrame ?? (videoNtsc && videoTimebase % 30 == 0)
        let ntsc = dropFrame ? true : videoNtsc
        let frame = source?.frame ?? 0
        return (base, ntsc, frame, dropFrame, formatTimecode(frame: frame, fps: base, dropFrame: dropFrame))
    }

    /// Frame count → SMPTE string; drop-frame (29.97/59.94) uses `;` separators and skips dropped frames.
    static func formatTimecode(frame: Int, fps: Int, dropFrame: Bool) -> String {
        guard fps > 0 else { return "00:00:00:00" }
        var f = frame
        if dropFrame {
            let drop = Int((Double(fps) * 0.066666).rounded())
            // Drop-frame ten-minute blocks contain nine shortened minutes.
            let perMinute = fps * 60 - drop
            let per10 = perMinute * 10 + drop
            let d = f / per10, m = f % per10
            f += drop * 9 * d + (m > drop ? drop * ((m - drop) / perMinute) : 0)
        }
        let sep = dropFrame ? ";" : ":"
        let ff = f % fps, ss = (f / fps) % 60, mm = (f / (fps * 60)) % 60, hh = f / (fps * 3600)
        return String(format: "%02d\(sep)%02d\(sep)%02d\(sep)%02d", hh, mm, ss, ff)
    }

    // MARK: - Builder

    private final class Builder {
        private let timeline: Timeline
        private let resolver: MediaResolver
        private let resolveTimeline: (String) -> Timeline?
        private let fps: Int
        private let seqWidth: Int
        private let seqHeight: Int
        private var curSeqWidth: Int

        private var emittedFiles: Set<FileKey> = []
        private var clipAddresses: [String: ClipAddress] = [:]
        private var clipsByLinkGroup: [String: [Clip]] = [:]
        private let startFrameCache: [String: SourceTimecode]
        // Repeated nests reference the first embedded sequence.
        private var sequenceIds: [String: String] = [:]
        private var emittedSequences: Set<String> = []

        private struct FileKey: Hashable { let mediaRef: String; let isAudio: Bool }
        private struct ClipAddress { let trackIndex: Int; let clipIndex: Int; let isAudio: Bool }

        init(timeline: Timeline, resolver: MediaResolver, resolveTimeline: @escaping (String) -> Timeline?,
             startFrameCache: [String: SourceTimecode]) {
            self.timeline = timeline
            self.resolver = resolver
            self.resolveTimeline = resolveTimeline
            self.fps = timeline.fps
            self.seqWidth = timeline.width
            self.seqHeight = timeline.height
            self.curSeqWidth = timeline.width
            self.startFrameCache = startFrameCache
        }

        // MARK: - Document shell

        func build() -> String {
            sequenceIds[timeline.id] = "sequence-1"
            emittedSequences.insert(timeline.id)
            let root = el("xmeml", attrs: [("version", "4")], [
                sequenceNode(id: "sequence-1", timeline: timeline),
            ])
            return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE xmeml>\n" + renderXML(root, indent: 0)
        }

        /// Builds a root or nested sequence with isolated link state.
        private func sequenceNode(id: String, timeline: Timeline) -> XMLNode {
            let savedAddresses = clipAddresses
            let savedGroups = clipsByLinkGroup
            let savedSeqWidth = curSeqWidth
            clipAddresses = [:]
            clipsByLinkGroup = [:]
            curSeqWidth = timeline.width
            defer {
                clipAddresses = savedAddresses
                clipsByLinkGroup = savedGroups
                curSeqWidth = savedSeqWidth
            }

            // FCP XML orders video tracks bottom→top; our model stores them top→bottom.
            let videoTracks = Array(timeline.tracks.filter { $0.type.isVisual }.reversed())
            let audioTracks = timeline.tracks.filter { $0.type == .audio }
            let sortedVideo = videoTracks.map(sortEmittable)
            let sortedAudio = audioTracks.map(sortEmittable)

            indexAddresses(sortedVideo, isAudio: false)
            indexAddresses(sortedAudio, isAudio: true)
            indexLinkGroups(timeline)

            let videoTrackNodes = zip(videoTracks, sortedVideo).map { trackNode($0, sortedClips: $1, isAudio: false) }
            let audioTrackNodes = zip(audioTracks, sortedAudio).map { trackNode($0, sortedClips: $1, isAudio: true) }

            return el("sequence", attrs: [("id", id)], [
                leaf("name", timeline.name),
                leaf("duration", timeline.totalFrames),
                rate(fps),
                timecodeNode(),
                el("media", [
                    el("video", [videoFormatNode(width: timeline.width, height: timeline.height)] + videoTrackNodes),
                    el("audio", [leaf("numOutputChannels", 2), audioFormatNode(), audioOutputsNode()] + audioTrackNodes),
                ]),
            ])
        }

        private func timecodeNode() -> XMLNode {
            el("timecode", [
                rate(fps),
                leaf("string", "00:00:00:00"),
                leaf("frame", 0),
                leaf("source", "source"),
                leaf("displayformat", "NDF"),
            ])
        }

        private func videoFormatNode(width: Int, height: Int) -> XMLNode {
            el("format", [el("samplecharacteristics", [
                leaf("width", width),
                leaf("height", height),
                bool("anamorphic", false),
                leaf("pixelaspectratio", "square"),
                leaf("fielddominance", "none"),
                rate(fps),
            ])])
        }

        private func audioFormatNode() -> XMLNode {
            el("format", [el("samplecharacteristics", [leaf("samplerate", 48000), leaf("depth", 16)])])
        }

        private func audioOutputsNode() -> XMLNode {
            el("outputs", [el("group", [
                leaf("index", 1),
                leaf("numchannels", 2),
                leaf("downmix", 0),
                el("channel", [leaf("index", 1)]),
                el("channel", [leaf("index", 2)]),
            ])])
        }

        // MARK: - Tracks → clipitems

        private func trackNode(_ track: Track, sortedClips: [Clip], isAudio: Bool) -> XMLNode {
            let enabled = isAudio ? !track.muted : !track.hidden
            var children: [XMLNode] = [bool("enabled", enabled), bool("locked", false)]
            for clip in sortedClips {
                if let fadeIn = fadeTransition(clip, edge: .left, isAudio: isAudio) { children.append(fadeIn) }
                children.append(clipItemNode(clip, isAudio: isAudio))
                if let fadeOut = fadeTransition(clip, edge: .right, isAudio: isAudio) { children.append(fadeOut) }
            }
            return el("track", children)
        }

        private func clipItemNode(_ clip: Clip, isAudio: Bool) -> XMLNode {
            if clip.sourceClipType == .sequence { return nestClipItemNode(clip, isAudio: isAudio) }
            // Clipitem rate/in/out/duration are in FILE-rate units; start/end stay sequence frames.
            // Resolve conforms in/out against the file's own rate — timeline-rate values land the
            // in-point off by the rate ratio on rate-mismatched sources.
            let (timebase, ntsc) = rateTags(forFPS: resolver.entry(for: clip.mediaRef)?.sourceFPS ?? Double(fps))
            let fileFPS = ntsc ? Double(timebase) * 1000.0 / 1001.0 : Double(timebase)
            let scale = fileFPS / Double(fps)
            let matchesTimeline = abs(scale - 1) < 0.0001
            func fileFrames(_ timelineFrames: Int) -> Int {
                matchesTimeline ? timelineFrames : Int((Double(timelineFrames) * scale).rounded())
            }
            let sourceDuration = sourceDurationFrames(for: clip.mediaRef) ?? clip.sourceDurationFrames
            // Time Remap handles speed through source in/out values.
            let inPoint = fileFrames(clip.trimStartFrame)
            let outPoint = fileFrames(clip.trimStartFrame + clip.sourceFramesConsumed)

            var children: [XMLNode] = [
                leaf("masterclipid", masterclipId(for: clip, isAudio: isAudio)),
                leaf("name", resolver.displayName(for: clip.mediaRef)),
                bool("enabled", true),
                leaf("duration", fileFrames(sourceDuration)),
                matchesTimeline ? rate(fps) : rate(timebase, ntsc: ntsc),
                leaf("start", clip.startFrame),
                leaf("end", clip.endFrame),
                leaf("in", inPoint),
                leaf("out", outPoint),
                fileNode(for: clip.mediaRef, isAudio: isAudio),
            ]
            if let remap = timeRemapFilter(speed: clip.speed, isAudio: isAudio) { children.append(remap) }
            children += isAudio ? volumeFilters(clip) : videoFilters(clip)
            children += linkNodes(for: clip)
            return el("clipitem", attrs: [("id", "clipitem-\(clip.id)")], children)
        }

        /// Embeds a nested sequence once, then references it by ID.
        private func nestClipItemNode(_ clip: Clip, isAudio: Bool) -> XMLNode {
            let child = resolveTimeline(clip.mediaRef)!  // sortEmittable guarantees resolution
            let seqId = sequenceIds[clip.mediaRef] ?? {
                let id = "sequence-\(sequenceIds.count + 1)"
                sequenceIds[clip.mediaRef] = id
                return id
            }()
            let sequence = emittedSequences.insert(clip.mediaRef).inserted
                ? sequenceNode(id: seqId, timeline: child)
                : el("sequence", attrs: [("id", seqId)])

            let inPoint = clip.trimStartFrame
            let outPoint = min(inPoint + clip.durationFrames, child.totalFrames)

            var children: [XMLNode] = [
                leaf("masterclipid", masterclipId(for: clip, isAudio: isAudio)),
                leaf("name", child.name),
                bool("enabled", true),
                leaf("duration", child.totalFrames),
                rate(fps),
                leaf("start", clip.startFrame),
                leaf("end", clip.startFrame + (outPoint - inPoint)),
                leaf("in", inPoint),
                leaf("out", outPoint),
                sequence,
            ]
            children += isAudio ? volumeFilters(clip) : videoFilters(clip)
            children += linkNodes(for: clip)
            return el("clipitem", attrs: [("id", "clipitem-\(clip.id)")], children)
        }

        private func masterclipId(for clip: Clip, isAudio: Bool) -> String {
            if let group = clip.linkGroupId { return "masterclip-\(group)" }
            return "masterclip-\(clip.mediaRef)-\(isAudio ? "audio" : "video")"
        }

        // MARK: - File elements

        /// Emits media-specific file IDs and collapses repeated definitions to references.
        private func fileNode(for mediaRef: String, isAudio: Bool) -> XMLNode {
            let fileId = "file-\(mediaRef)-\(isAudio ? "audio" : "video")"
            let key = FileKey(mediaRef: mediaRef, isAudio: isAudio)
            if emittedFiles.contains(key) { return el("file", attrs: [("id", fileId)]) }
            emittedFiles.insert(key)

            let entry = resolver.entry(for: mediaRef)
            let url = resolver.resolveURL(for: mediaRef)
            // Resolve matches media by exact filename + extension.
            let fileName = url?.lastPathComponent ?? entry?.name ?? mediaRef
            // Resolve needs Premiere's extra-slash host form; the canonical single-slash one fails.
            let pathUrl = url
                .map { $0.absoluteString.replacingOccurrences(of: "file://", with: "file://localhost//") }
                ?? "media/\(mediaRef)"
            // Stills decode as one frame.
            let isImage = entry?.type == .image
            let (timebase, ntsc) = rateTags(forFPS: entry?.sourceFPS ?? Double(fps))
            // Duration in the file's own rate units, consistent with the rate element it sits beside.
            let fileFPS = ntsc ? Double(timebase) * 1000.0 / 1001.0 : Double(timebase)
            let durationFrames = isImage ? 1 : (entry.map { max(0, Int(($0.duration * fileFPS).rounded())) } ?? 0)

            let media: XMLNode = isAudio
                ? el("media", [el("audio", [
                    el("samplecharacteristics", [leaf("samplerate", 48000), leaf("depth", 16)]),
                    leaf("channelcount", 2),
                  ])])
                : el("media", [el("video", (isImage ? [leaf("duration", 1)] : []) + [el("samplecharacteristics", [
                    leaf("width", entry?.sourceWidth ?? seqWidth),
                    leaf("height", entry?.sourceHeight ?? seqHeight),
                    bool("anamorphic", false),
                    leaf("pixelaspectratio", "square"),
                    leaf("fielddominance", "none"),
                    rate(timebase, ntsc: ntsc),
                  ])])])

            // Resolve requires the timecode element.
            let tc = XMLExporter.timecodeTags(source: sourceTimecode(for: mediaRef), videoTimebase: timebase, videoNtsc: ntsc)
            let timecode = el("timecode", [
                rate(tc.base, ntsc: tc.ntsc),
                leaf("string", tc.string),
                leaf("frame", tc.frame),
                leaf("displayformat", tc.dropFrame ? "DF" : "NDF"),
            ])
            return el("file", attrs: [("id", fileId)], [
                leaf("name", fileName),
                leaf("pathurl", pathUrl),
                rate(timebase, ntsc: ntsc),
                leaf("duration", durationFrames),
                timecode,
                media,
            ])
        }

        private func sourceTimecode(for mediaRef: String) -> SourceTimecode? {
            startFrameCache[mediaRef]
        }

        // MARK: - Links

        /// Linked clips emit a `<link>` per partner so Premiere rebuilds the A/V pair.
        private func linkNodes(for clip: Clip) -> [XMLNode] {
            guard let group = clip.linkGroupId,
                  let partners = clipsByLinkGroup[group], partners.count > 1 else { return [] }
            return partners.compactMap { partner in
                guard let addr = clipAddresses[partner.id] else { return nil }
                return el("link", [
                    leaf("linkclipref", "clipitem-\(partner.id)"),
                    leaf("mediatype", addr.isAudio ? "audio" : "video"),
                    leaf("trackindex", addr.trackIndex),
                    leaf("clipindex", addr.clipIndex),
                ])
            }
        }

        // MARK: - Transitions (fades)

        /// A fade exports as a single-sided dissolve to black/silence (no clip-to-clip model).
        private func fadeTransition(_ clip: Clip, edge: FadeEdge, isAudio: Bool) -> XMLNode? {
            let frames = clip.fadeFrames(edge)
            guard frames > 0 else { return nil }

            let start: Int, end: Int, alignment: String, cutFrames: Int
            switch edge {
            case .left:  start = clip.startFrame;          end = clip.startFrame + frames; alignment = "start-black"; cutFrames = 0
            case .right: start = clip.endFrame - frames;   end = clip.endFrame;            alignment = "end-black";   cutFrames = frames
            }

            var children: [XMLNode] = [leaf("start", start), leaf("end", end), leaf("alignment", alignment)]
            if isAudio {
                children.append(rate(fps))
                children.append(effect(name: "Cross Fade ( 0dB)", id: "KGAudioTransCrossFade0dB", type: "transition", mediatype: "audio"))
            } else {
                // Premiere stores fade cut points in 254016000000 ticks per second.
                let cutPointTicks = Int64(cutFrames) * (Int64(254_016_000_000) / Int64(fps))
                children.append(leaf("cutPointTicks", String(cutPointTicks)))
                children.append(rate(fps))
                children.append(effect(name: "Cross Dissolve", id: "Cross Dissolve", type: "transition", mediatype: "video", category: "Dissolve", body: [
                    leaf("wipecode", 0),
                    leaf("wipeaccuracy", 100),
                    leaf("startratio", 0),
                    leaf("endratio", 1),
                    bool("reverse", false),
                ]))
            }
            return el("transitionitem", children)
        }

        // MARK: - Filters

        /// Premiere needs this to apply speed; it won't infer it from the in/out vs start/end ratio.
        private func timeRemapFilter(speed: Double, isAudio: Bool) -> XMLNode? {
            guard speed != 1.0 else { return nil }
            return filter(effect(name: "Time Remap", id: "timeremap", type: "motion", mediatype: isAudio ? "audio" : "video", body: [
                parameter(id: "variablespeed", name: "variablespeed", min: "0", max: "1", value: leaf("value", 0)),
                parameter(id: "speed", name: "speed", min: "-100000", max: "100000", value: leaf("value", String(format: "%.4f", speed * 100))),
                parameter(id: "reverse", name: "reverse", value: bool("value", false)),
                parameter(id: "frameblending", name: "frameblending", value: bool("value", false)),
            ]))
        }

        /// Exports fade-independent linear gain, clamped to Premiere's maximum.
        private func volumeFilters(_ clip: Clip) -> [XMLNode] {
            func clampLevel(_ v: Double) -> Double { max(0, min(v, 3.98)) }
            let frames = clip.keyframeFrames(for: .volume)
            let level: XMLNode
            if frames.isEmpty {
                guard clip.volume != 1.0 else { return [] }
                level = scalarParam(id: "level", name: "Level", min: "0", max: "3.98107", base: clampLevel(clip.volume), spec: "%.4f")
            } else {
                let kfs = frames.map { (when: $0 - clip.startFrame, value: clampLevel(clip.rawVolumeAt(frame: $0))) }
                level = scalarParam(id: "level", name: "Level", min: "0", max: "3.98107", base: kfs[0].value, keyframes: kfs, spec: "%.4f")
            }
            return [filter(effect(name: "Audio Levels", id: "audiolevels", type: "audio", mediatype: "audio", body: [level]))]
        }

        private func videoFilters(_ clip: Clip) -> [XMLNode] {
            [motionFilter(clip), cropFilter(clip), opacityFilter(clip)].compactMap { $0 }
        }

        /// Emits nondefault Basic Motion parameters.
        private func motionFilter(_ clip: Clip) -> XMLNode? {
            let sourceWidth = resolver.entry(for: clip.mediaRef)?.sourceWidth ?? 0
            // Nested transforms use the child sequence canvas.
            func scalePct(_ width: Double) -> Double {
                sourceWidth > 0 ? (Double(curSeqWidth) / Double(sourceWidth)) * width * 100 : width * 100
            }

            // FCP7 center uses normalized coordinates (0 = center), not pixels.
            func center(_ t: Transform) -> (x: Double, y: Double) {
                (t.centerX - 0.5, t.centerY - 0.5)
            }

            // Center depends on position + scale, so sample all transform params at the union of frames.
            let frames = Set(clip.keyframeFrames(for: .position)
                + clip.keyframeFrames(for: .scale)
                + clip.keyframeFrames(for: .rotation)).sorted()

            var params: [XMLNode] = []
            if frames.isEmpty {
                let t = clip.transform
                let c = center(t), scaled = scalePct(t.width), rotated = -t.rotation
                let needsCenter = abs(c.x) > 0.001 || abs(c.y) > 0.001
                let needsScale = abs(scaled - 100) > 0.1
                let needsRotation = abs(rotated) > 0.05
                guard needsCenter || needsScale || needsRotation else { return nil }
                if needsScale { params.append(scalarParam(id: "scale", name: "Scale", min: "0", max: "1000", base: scaled)) }
                if needsRotation { params.append(scalarParam(id: "rotation", name: "Rotation", min: "-100000", max: "100000", base: rotated)) }
                if needsCenter { params.append(centerParam(base: c)) }
            } else {
                let scaleKfs = frames.map { (when: $0 - clip.startFrame, value: scalePct(clip.sizeAt(frame: $0).width)) }
                let rotationKfs = frames.map { (when: $0 - clip.startFrame, value: -clip.rotationAt(frame: $0)) }
                let centerKfs = frames.map { f -> (when: Int, x: Double, y: Double) in
                    let c = center(clip.transformAt(frame: f)); return (f - clip.startFrame, c.x, c.y)
                }
                params = [
                    scalarParam(id: "scale", name: "Scale", min: "0", max: "1000", base: scaleKfs[0].value, keyframes: scaleKfs),
                    scalarParam(id: "rotation", name: "Rotation", min: "-100000", max: "100000", base: rotationKfs[0].value, keyframes: rotationKfs),
                    centerParam(base: (centerKfs[0].x, centerKfs[0].y), keyframes: centerKfs),
                ]
            }
            return filter(effect(name: "Basic Motion", id: "basic", type: "motion", mediatype: "video", body: params))
        }

        /// Converts crop fractions to FCP7 percentages.
        private func cropFilter(_ clip: Clip) -> XMLNode? {
            let frames = clip.keyframeFrames(for: .crop)
            if frames.isEmpty && clip.crop.isIdentity { return nil }

            func edge(_ id: String, _ kp: KeyPath<Crop, Double>) -> XMLNode {
                if frames.isEmpty {
                    return scalarParam(id: id, name: id, min: "0", max: "100", base: clip.crop[keyPath: kp] * 100)
                }
                let kfs = frames.map { (when: $0 - clip.startFrame, value: clip.cropAt(frame: $0)[keyPath: kp] * 100) }
                return scalarParam(id: id, name: id, min: "0", max: "100", base: kfs[0].value, keyframes: kfs)
            }
            let params = [edge("left", \.left), edge("right", \.right), edge("top", \.top), edge("bottom", \.bottom)]
            return filter(effect(name: "Crop", id: "crop", type: "motion", mediatype: "video", category: "motion", body: params))
        }

        /// Emits opacity separately from Basic Motion.
        private func opacityFilter(_ clip: Clip) -> XMLNode? {
            let frames = clip.keyframeFrames(for: .opacity)
            let opacity: XMLNode
            if frames.isEmpty {
                guard clip.opacity != 1.0 else { return nil }
                opacity = scalarParam(id: "opacity", name: "Opacity", min: "0", max: "100", base: clip.opacity * 100, spec: "%.1f")
            } else {
                let kfs = frames.map { (when: $0 - clip.startFrame, value: clip.rawOpacityAt(frame: $0) * 100) }
                opacity = scalarParam(id: "opacity", name: "Opacity", min: "0", max: "100", base: kfs[0].value, keyframes: kfs, spec: "%.1f")
            }
            return filter(effect(name: "Opacity", id: "opacity", type: "motion", mediatype: "video", body: [opacity]))
        }

        // MARK: - Indexing helpers

        /// Drops unresolved clips before assigning link indices.
        private func sortEmittable(_ track: Track) -> [Clip] {
            track.clips
                .filter { clip in
                    // Drop carriers trimmed beyond the child timeline.
                    clip.sourceClipType == .sequence
                        ? clip.trimStartFrame < (resolveTimeline(clip.mediaRef)?.totalFrames ?? 0)
                        : resolver.resolveURL(for: clip.mediaRef) != nil
                }
                .sorted { $0.startFrame < $1.startFrame }
        }

        private func indexAddresses(_ sortedTracks: [[Clip]], isAudio: Bool) {
            for (ti, clips) in sortedTracks.enumerated() {
                for (ci, clip) in clips.enumerated() {
                    clipAddresses[clip.id] = ClipAddress(trackIndex: ti + 1, clipIndex: ci + 1, isAudio: isAudio)
                }
            }
        }

        private func indexLinkGroups(_ timeline: Timeline) {
            for track in timeline.tracks {
                for clip in track.clips {
                    guard let group = clip.linkGroupId else { continue }
                    clipsByLinkGroup[group, default: []].append(clip)
                }
            }
        }

        private func sourceDurationFrames(for mediaRef: String) -> Int? {
            guard let seconds = resolver.entry(for: mediaRef)?.duration else { return nil }
            return max(0, secondsToFrame(seconds: seconds, fps: fps))
        }

        /// Converts a real frame rate to FCP7 timebase and NTSC fields.
        private func rateTags(forFPS rawFps: Double) -> (timebase: Int, ntsc: Bool) {
            let timebase = max(1, Int(rawFps.rounded()))
            let ntscRate = Double(timebase) * 1000.0 / 1001.0
            return (timebase, abs(rawFps - ntscRate) < abs(rawFps - Double(timebase)))
        }

        // MARK: - Effect & parameter builders

        private func rate(_ timebase: Int, ntsc: Bool = false) -> XMLNode {
            el("rate", [leaf("timebase", timebase), bool("ntsc", ntsc)])
        }

        private func filter(_ effect: XMLNode) -> XMLNode { el("filter", [effect]) }

        private func effect(name: String, id: String, type: String, mediatype: String,
                            category: String? = nil, body: [XMLNode] = []) -> XMLNode {
            var children = [leaf("name", name), leaf("effectid", id)]
            if let category { children.append(leaf("effectcategory", category)) }
            children.append(leaf("effecttype", type))
            children.append(leaf("mediatype", mediatype))
            children += body
            return el("effect", children)
        }

        private func parameter(id: String, name: String, min: String? = nil, max: String? = nil,
                               value: XMLNode, keyframes: [(when: Int, value: XMLNode)] = []) -> XMLNode {
            var children = [leaf("parameterid", id), leaf("name", name)]
            if let min { children.append(leaf("valuemin", min)) }
            if let max { children.append(leaf("valuemax", max)) }
            children.append(value)
            children += keyframes.map { el("keyframe", [leaf("when", $0.when), $0.value]) }
            return el("parameter", children)
        }

        private func scalarParam(id: String, name: String, min: String, max: String, base: Double,
                                 keyframes: [(when: Int, value: Double)] = [], spec: String = "%.2f") -> XMLNode {
            parameter(id: id, name: name, min: min, max: max,
                      value: leaf("value", String(format: spec, base)),
                      keyframes: keyframes.map { (when: $0.when, value: leaf("value", String(format: spec, $0.value))) })
        }

        private func centerParam(base: (x: Double, y: Double), keyframes: [(when: Int, x: Double, y: Double)] = []) -> XMLNode {
            func vec(_ x: Double, _ y: Double) -> XMLNode {
                el("value", [leaf("horiz", String(format: "%.5f", x)), leaf("vert", String(format: "%.5f", y))])
            }
            return parameter(id: "center", name: "Center", value: vec(base.x, base.y),
                             keyframes: keyframes.map { (when: $0.when, value: vec($0.x, $0.y)) })
        }
    }
}

// MARK: - XML rendering

/// Minimal XML tree with centralized escaping and whitespace.
private struct XMLNode {
    let name: String
    var attributes: [(String, String)] = []
    var text: String? = nil
    var children: [XMLNode] = []
}

private func el(_ name: String, _ children: [XMLNode] = []) -> XMLNode {
    XMLNode(name: name, children: children)
}
private func el(_ name: String, attrs: [(String, String)], _ children: [XMLNode] = []) -> XMLNode {
    XMLNode(name: name, attributes: attrs, children: children)
}
private func leaf(_ name: String, _ value: String) -> XMLNode { XMLNode(name: name, text: value) }
private func leaf(_ name: String, _ value: Int) -> XMLNode { XMLNode(name: name, text: String(value)) }
private func bool(_ name: String, _ value: Bool) -> XMLNode { XMLNode(name: name, text: value ? "TRUE" : "FALSE") }

private func renderXML(_ node: XMLNode, indent: Int) -> String {
    let pad = String(repeating: " ", count: indent)
    let attrs = node.attributes.map { " \($0.0)=\"\(escapeXML($0.1))\"" }.joined()
    if let text = node.text {
        return "\(pad)<\(node.name)\(attrs)>\(escapeXML(text))</\(node.name)>"
    }
    guard !node.children.isEmpty else { return "\(pad)<\(node.name)\(attrs)/>" }
    let inner = node.children.map { renderXML($0, indent: indent + 2) }.joined(separator: "\n")
    return "\(pad)<\(node.name)\(attrs)>\n\(inner)\n\(pad)</\(node.name)>"
}

private func escapeXML(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
     .replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;")
     .replacingOccurrences(of: "\"", with: "&quot;")
     .replacingOccurrences(of: "'", with: "&apos;")
}
