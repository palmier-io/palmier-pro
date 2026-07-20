import AppKit
import CoreText
import Foundation

/// The `version` attribute Resolve/FCP gate import on (a literal allow-list), so it's the only thing
/// the user picks. Every element we emit has existed since FCPXML 1.1 — the body is version-identical.
enum FCPXMLVersion: String, CaseIterable, Identifiable, Sendable {
    case v1_10 = "1.10"
    case v1_11 = "1.11"
    case v1_12 = "1.12"
    case v1_13 = "1.13"
    case v1_14 = "1.14"

    var id: String { rawValue }
    /// 1.10 is the broadest: every Resolve from 18 up accepts it. Higher versions need Resolve 21+.
    static let `default`: FCPXMLVersion = .v1_10

    var compatibilityNote: String {
        switch self {
        case .v1_10: "DaVinci Resolve 18+, Final Cut Pro 10.6+"
        case .v1_11: "DaVinci Resolve 21+, Final Cut Pro 10.7+"
        case .v1_12: "DaVinci Resolve 21+, Final Cut Pro 10.8+"
        case .v1_13: "DaVinci Resolve 21+, Final Cut Pro 11+"
        case .v1_14: "DaVinci Resolve 21+, Final Cut Pro 12+"
        }
    }
}

/// Resolve interprets several FCPXML values off-spec (trim-rect units, imported position scaled by
/// the conform fit at render); Final Cut is spec-literal. Same structure, different value encoding.
enum FCPXMLTarget: String, CaseIterable, Identifiable, Sendable {
    case resolve
    case fcp

    var id: String { rawValue }
    static let `default`: FCPXMLTarget = .resolve

    var displayName: String {
        switch self {
        case .resolve: "DaVinci Resolve"
        case .fcp: "Final Cut Pro"
        }
    }
}

/// Exports a Timeline as FCPXML (for DaVinci Resolve / Final Cut Pro). Companion to XMLExporter
/// (XMEML, for Premiere). The document is an `FCPXMLNode` tree (defined at the bottom); `renderFCPXML`
/// owns indentation and escaping. Read `build()` top-down: `<fcpxml>` → `<resources>` (formats +
/// assets + per-clip compound clips) → `<library>/<event>/<project>/<sequence>`. The timeline is one
/// `<gap>` with every clip connected on a lane.
///
/// Encoding facts (reverse-engineered from Resolve round-trips):
/// - Position: unit = 1% of frame height, square, origin at center, +Y up; pre-divided by the
///   clip's per-axis conform-fit fraction (Resolve scales imported positions by it at render).
/// - Scale: multiplier on the conform-fit size, so we divide the aspect-fit out of width/height.
/// - Rotation: degrees, negated (FCP is counter-clockwise-positive). Flip: negative scale.
/// - Crop: `<trim-rect>` in Resolve's units — left/right: source px ÷ (seqHeight/100);
///   top/bottom: crop fraction ÷ conform-fit scale.
/// - Clips are flat `<asset-clip>`s (stills: `<video>`); only an A/V source played one-sided
///   rides a compound `<media>`/`<ref-clip>` (Resolve honors `srcEnable` only on ref-clips).
/// - Retime: a `<timeMap>` on the clip ramps the whole media (output[0, media/speed] →
///   source[0, media]) and `start` windows in along the output axis (= source in-point ÷ speed).
///   A clip-local ramp blacks the tail.
/// - Keyframes: child `<param>/<keyframeAnimation>`; `time` is offset by `start` (the output axis),
///   `value` in the param's own unit. Volume: `<adjust-volume amount>` in dB.
///
/// What transports: clip placement/trims, speed, lane order, enabled state; text + font/face/
/// size/color/alignment/stroke; position/scale/rotation/flip (+ position/scale/rotation keyframes);
/// crop; opacity (+ keyframes); static volume; source start timecode, so Resolve doesn't flag a
/// mismatch against the media's embedded timecode.
///
/// What does NOT: keyframed audio volume and audio fades (Resolve drops both itself); text
/// background boxes (no FCPXML form); crop keyframes; title rotation/scale; color &
/// effects; Lottie clips.
///
/// Reference: https://developer.apple.com/documentation/professional-video-applications/fcpxml-reference
enum FCPXMLExporter {
    static func export(timeline: Timeline, resolver: MediaResolver,
                       resolveTimeline: @escaping @Sendable (String) -> Timeline? = { _ in nil },
                       version: FCPXMLVersion = .default, target: FCPXMLTarget = .default,
                       outputURL: URL) async throws {
        // Include media from every reachable nested timeline.
        var mediaRefs: Set<String> = []
        var queue = [timeline]
        var visited: Set<String> = []
        var i = 0
        while i < queue.count {
            let t = queue[i]
            i += 1
            guard visited.insert(t.id).inserted else { continue }
            for clip in t.tracks.flatMap(\.clips) {
                if clip.sourceClipType == .sequence {
                    if let child = resolveTimeline(clip.mediaRef) { queue.append(child) }
                } else {
                    mediaRefs.insert(clip.mediaRef)
                }
            }
        }
        let timecodes = await SourceTimingReader.timecodes(mediaRefs: mediaRefs, urls: resolver.expectedURLMap())
        let xml = render(timeline: timeline, resolver: resolver, resolveTimeline: resolveTimeline,
                         version: version, target: target, startTimecodes: timecodes)
        guard let data = xml.data(using: .utf8) else { throw ExportError.xmlEncodingFailed }
        try data.write(to: outputURL)
    }

    /// Renders with injectable source timecodes for deterministic tests.
    static func render(timeline: Timeline, resolver: MediaResolver,
                       resolveTimeline: @escaping (String) -> Timeline? = { _ in nil },
                       version: FCPXMLVersion = .default,
                       target: FCPXMLTarget = .default, startTimecodes: [String: SourceTimecode] = [:]) -> String {
        Builder(timeline: timeline, resolver: resolver, resolveTimeline: resolveTimeline,
                version: version, target: target, startTimecodes: startTimecodes).build()
    }

    private final class Builder {
        private let timeline: Timeline
        private let resolver: MediaResolver
        private let resolveTimeline: (String) -> Timeline?
        private let version: FCPXMLVersion
        private let target: FCPXMLTarget
        private let startTimecodes: [String: SourceTimecode]
        private let fps: Int
        private let seqWidth: Int
        private let seqHeight: Int
        private let sequenceFormatId = "r1"
        private let titleEffectId = "titleBasic"
        private var resourceIndex: [String: Int] = [:]
        private var resources: [MediaResource] = []
        private var nextTextStyleId = 1
        // Synced pairs export as one asset clip while retaining audio volume.
        private var linkedAudioForVideo: [String: Clip] = [:]
        private var redundantAudioClipIds: Set<String> = []
        private var usedCompoundIds: Set<String> = []
        // Nested timelines become compound resources in discovery order.
        private var nests: [(mediaId: String, timeline: Timeline)] = []
        private var nestIndex: [String: String] = [:]

        private struct EmittableClip {
            let clip: Clip
            let lane: Int
            let enabled: Bool
        }

        private struct MediaResource {
            let mediaRef: String
            let assetId: String
            let formatId: String?
            let compoundId: String?
            let entry: MediaManifestEntry
            let url: URL
            var durationFrames: Int
            let hasVideo: Bool
            let hasAudio: Bool
            let startTimecode: (num: Int, den: Int)
        }

        init(timeline: Timeline, resolver: MediaResolver, resolveTimeline: @escaping (String) -> Timeline?,
             version: FCPXMLVersion, target: FCPXMLTarget, startTimecodes: [String: SourceTimecode]) {
            self.timeline = timeline
            self.resolver = resolver
            self.resolveTimeline = resolveTimeline
            self.version = version
            self.target = target
            self.startTimecodes = startTimecodes
            self.fps = max(1, timeline.fps)
            self.seqWidth = timeline.width
            self.seqHeight = timeline.height
        }

        func build() -> String {
            collectNests()
            let clips = emittableClips(of: timeline)
            let nestedClips = nests.flatMap { emittableClips(of: $0.timeline) }
            collectResources(from: clips + nestedClips)
            indexLinkedPairs(clips + nestedClips)
            markUsedCompounds(clips + nestedClips)
            let hasTitles = (clips + nestedClips).contains { $0.clip.mediaType == .text }
            let root = FCPXMLNode(name: "fcpxml", attributes: [("version", version.rawValue)], children: [
                resourcesNode(hasTitles: hasTitles),
                libraryNode(clips: clips),
            ])
            return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE fcpxml>\n" + renderFCPXML(root, indent: 0)
        }

        /// Indexes nonempty, resolvable nested timelines.
        private func collectNests() {
            let reachable = timeline.reachableTimelines(
                resolve: resolveTimeline, maxDepth: NestFlattener.maxDepth, include: { $0.totalFrames > 0 }
            )
            for child in reachable {
                let mediaId = "nest\(nests.count + 1)"
                nestIndex[child.id] = mediaId
                nests.append((mediaId, child))
            }
        }

        private func indexLinkedPairs(_ clips: [EmittableClip]) {
            var byGroup: [String: (videos: [EmittableClip], audios: [EmittableClip])] = [:]
            for item in clips {
                guard let group = item.clip.linkGroupId else { continue }
                switch item.clip.mediaType {
                case .video, .image, .sequence: byGroup[group, default: ([], [])].videos.append(item)
                case .audio: byGroup[group, default: ([], [])].audios.append(item)
                default: break
                }
            }
            for (_, pair) in byGroup {
                guard pair.videos.count == 1, pair.audios.count == 1 else { continue }
                let v = pair.videos[0], a = pair.audios[0]
                guard v.clip.mediaRef == a.clip.mediaRef, v.enabled == a.enabled,
                      v.clip.startFrame == a.clip.startFrame, v.clip.durationFrames == a.clip.durationFrames,
                      v.clip.trimStartFrame == a.clip.trimStartFrame, abs(v.clip.speed - a.clip.speed) < 0.0001
                else { continue }
                linkedAudioForVideo[v.clip.id] = a.clip
                redundantAudioClipIds.insert(a.clip.id)
            }
        }

        // Emit compound resources only when referenced.
        private func markUsedCompounds(_ clips: [EmittableClip]) {
            for item in clips where !redundantAudioClipIds.contains(item.clip.id) {
                guard let i = resourceIndex[item.clip.mediaRef],
                      let compoundId = resources[i].compoundId,
                      linkedAudioForVideo[item.clip.id] == nil else { continue }
                usedCompoundIds.insert(compoundId)
            }
        }

        private func resourcesNode(hasTitles: Bool) -> FCPXMLNode {
            var children: [FCPXMLNode] = [
                FCPXMLNode(name: "format", attributes: [
                    ("id", sequenceFormatId),
                    ("name", sequenceFormatName(width: seqWidth, height: seqHeight, fps: Double(fps))),
                    ("frameDuration", frameDuration(forFPS: Double(fps))),
                    ("width", "\(seqWidth)"),
                    ("height", "\(seqHeight)"),
                    ("colorSpace", "1-1-1 (Rec. 709)"),
                ]),
            ]

            if hasTitles {
                children.append(FCPXMLNode(name: "effect", attributes: [
                    ("id", titleEffectId),
                    ("name", "Basic Title"),
                    ("uid", ".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti"),
                ]))
            }

            children += resources.compactMap(formatNode)
            children += resources.map(assetNode)
            children += resources.compactMap(compoundClipNode)
            children += nests.compactMap(nestFormatNode)
            children += nests.map(nestMediaNode)
            return FCPXMLNode(name: "resources", children: children)
        }

        private func nestFormatId(_ nest: (mediaId: String, timeline: Timeline)) -> String {
            nest.timeline.width == seqWidth && nest.timeline.height == seqHeight
                ? sequenceFormatId : "\(nest.mediaId)Format"
        }

        private func nestFormatNode(_ nest: (mediaId: String, timeline: Timeline)) -> FCPXMLNode? {
            let formatId = nestFormatId(nest)
            guard formatId != sequenceFormatId else { return nil }
            return FCPXMLNode(name: "format", attributes: [
                ("id", formatId),
                ("name", sequenceFormatName(width: nest.timeline.width, height: nest.timeline.height, fps: Double(fps))),
                ("frameDuration", frameDuration(forFPS: Double(fps))),
                ("width", "\(nest.timeline.width)"),
                ("height", "\(nest.timeline.height)"),
                ("colorSpace", "1-1-1 (Rec. 709)"),
            ])
        }

        private func nestMediaNode(_ nest: (mediaId: String, timeline: Timeline)) -> FCPXMLNode {
            let duration = time(frames: nest.timeline.totalFrames)
            let gap = FCPXMLNode(name: "gap", attributes: [
                ("name", "Timeline"),
                ("offset", "0s"),
                ("start", "0s"),
                ("duration", duration),
            ], children: storyNodes(for: emittableClips(of: nest.timeline)))
            let sequence = FCPXMLNode(name: "sequence", attributes: [
                ("format", nestFormatId(nest)),
                ("duration", duration),
                ("tcStart", "0s"),
                ("tcFormat", "NDF"),
                ("audioLayout", "stereo"),
                ("audioRate", "48k"),
            ], children: [FCPXMLNode(name: "spine", children: [gap])])
            return FCPXMLNode(name: "media", attributes: [
                ("id", nest.mediaId),
                ("name", nest.timeline.name),
            ], children: [sequence])
        }

        private func compoundClipNode(for resource: MediaResource) -> FCPXMLNode? {
            guard let compoundId = resource.compoundId, usedCompoundIds.contains(compoundId) else { return nil }
            let dur = time(frames: resource.durationFrames)
            // Compound spines stay 0-based while reading from the asset timecode origin.
            let tcStart = rationalTime(num: resource.startTimecode.num, den: resource.startTimecode.den)
            let innerClip = FCPXMLNode(name: "asset-clip", attributes: [
                ("ref", resource.assetId),
                ("name", fileName(for: resource)),
                ("duration", dur),
                ("start", tcStart),
                ("offset", "0s"),
                ("format", resource.formatId ?? sequenceFormatId),
            ])
            let sequence = FCPXMLNode(name: "sequence", attributes: [
                ("format", resource.formatId ?? sequenceFormatId),
                ("duration", dur),
                ("tcStart", "0s"),
                ("tcFormat", "NDF"),
            ], children: [FCPXMLNode(name: "spine", children: [innerClip])])
            return FCPXMLNode(name: "media", attributes: [
                ("id", compoundId),
                ("name", fileName(for: resource)),
            ], children: [sequence])
        }

        private func libraryNode(clips: [EmittableClip]) -> FCPXMLNode {
            FCPXMLNode(name: "library", children: [
                FCPXMLNode(name: "event", attributes: [("name", "Palmier Export")], children: [
                    projectNode(clips: clips),
                ]),
            ])
        }

        private func projectNode(clips: [EmittableClip]) -> FCPXMLNode {
            let duration = time(frames: timeline.totalFrames)
            let spine: FCPXMLNode = timeline.totalFrames > 0
                ? FCPXMLNode(name: "spine", children: [
                    FCPXMLNode(name: "gap", attributes: [
                        ("name", "Timeline"),
                        ("offset", "0s"),
                        ("start", "0s"),
                        ("duration", duration),
                    ], children: storyNodes(for: clips)),
                  ])
                : FCPXMLNode(name: "spine")

            return FCPXMLNode(name: "project", attributes: [("name", timeline.name)], children: [
                FCPXMLNode(name: "sequence", attributes: [
                    ("format", sequenceFormatId),
                    ("duration", duration),
                    ("tcStart", "0s"),
                    ("tcFormat", "NDF"),
                    ("audioLayout", "stereo"),
                    ("audioRate", "48k"),
                ], children: [spine]),
            ])
        }

        private func storyNodes(for clips: [EmittableClip]) -> [FCPXMLNode] {
            clips
                .filter { !redundantAudioClipIds.contains($0.clip.id) }
                .sorted {
                    if $0.clip.startFrame != $1.clip.startFrame { return $0.clip.startFrame < $1.clip.startFrame }
                    return $0.lane < $1.lane
                }
                .compactMap { item in
                    switch item.clip.mediaType {
                    case .text:
                        return titleNode(for: item)
                    case .audio, .video, .image, .sequence:
                        return assetClipNode(for: item)
                    case .lottie:
                        return nil
                    }
                }
        }

        private func assetClipNode(for item: EmittableClip) -> FCPXMLNode? {
            let clip = item.clip

            if clip.sourceClipType == .sequence {
                guard let mediaId = nestIndex[clip.mediaRef],
                      let child = resolveTimeline(clip.mediaRef) else { return nil }
                // Frozen carriers may outlive the child timeline.
                let duration = min(clip.durationFrames, max(0, child.totalFrames - clip.trimStartFrame))
                guard duration > 0 else { return nil }
                var attrs: [(String, String)] = [
                    ("ref", mediaId),
                    ("name", child.name),
                    ("lane", "\(item.lane)"),
                    ("offset", time(frames: clip.startFrame)),
                    ("start", time(frames: clip.trimStartFrame)),
                    ("duration", time(frames: duration)),
                    ("enabled", item.enabled ? "1" : "0"),
                ]
                if clip.mediaType == .audio {
                    attrs.append(("srcEnable", "audio"))
                    return FCPXMLNode(name: "ref-clip", attributes: attrs,
                                      children: [volumeNode(for: clip)].compactMap { $0 })
                }
                let nestLinkedAudio = linkedAudioForVideo[clip.id]
                if nestLinkedAudio == nil { attrs.append(("srcEnable", "video")) }
                return FCPXMLNode(name: "ref-clip", attributes: attrs, children: [
                    FCPXMLNode(name: "adjust-conform", attributes: [("type", "fit")]),
                    cropNode(for: clip),
                    transformNode(for: clip),
                    blendNode(for: clip),
                    nestLinkedAudio.flatMap(volumeNode),
                ].compactMap { $0 })
            }

            guard let i = resourceIndex[clip.mediaRef] else { return nil }
            let resource = resources[i]
            let linkedAudio = linkedAudioForVideo[clip.id]

            // Resolve honors srcEnable only on ref-clips.
            if let compoundId = resource.compoundId, linkedAudio == nil {
                let videoOnly = clip.mediaType != .audio
                let attrs: [(String, String)] = [
                    ("ref", compoundId),
                    ("name", fileName(for: resource)),
                    ("lane", "\(item.lane)"),
                    ("offset", time(frames: clip.startFrame)),
                    ("start", clipStart(for: clip)),
                    ("duration", time(frames: clip.durationFrames)),
                    ("enabled", item.enabled ? "1" : "0"),
                    ("srcEnable", videoOnly ? "video" : "audio"),
                ]
                // Child order is fixed by the DTD.
                let children: [FCPXMLNode?] = videoOnly
                    ? [timeMapNode(for: clip, mediaFrames: resource.durationFrames),
                       cropNode(for: clip),
                       FCPXMLNode(name: "adjust-conform", attributes: [("type", "fit")]),
                       transformNode(for: clip),
                       blendNode(for: clip)]
                    : [timeMapNode(for: clip, mediaFrames: resource.durationFrames),
                       volumeNode(for: clip)]
                return FCPXMLNode(name: "ref-clip", attributes: attrs, children: children.compactMap { $0 })
            }

            let origin = resource.startTimecode
            let visual = clip.mediaType != .audio
            let attrs: [(String, String)] = [
                ("ref", resource.assetId),
                ("name", fileName(for: resource)),
                ("lane", "\(item.lane)"),
                ("offset", time(frames: clip.startFrame)),
                ("start", clipStart(for: clip, origin: origin)),
                ("duration", time(frames: clip.durationFrames)),
                ("enabled", item.enabled ? "1" : "0"),
            ]
            let children: [FCPXMLNode?] = [
                timeMapNode(for: clip, mediaFrames: resource.durationFrames, origin: origin),
                visual ? cropNode(for: clip) : nil,
                visual ? FCPXMLNode(name: "adjust-conform", attributes: [("type", "fit")]) : nil,
                visual ? transformNode(for: clip) : nil,
                visual ? blendNode(for: clip) : nil,
                resource.hasAudio ? volumeNode(for: linkedAudio ?? clip) : nil,
            ]
            // Final Cut writes stills as video elements.
            return FCPXMLNode(name: clip.mediaType == .image ? "video" : "asset-clip",
                              attributes: attrs, children: children.compactMap { $0 })
        }

        private func titleNode(for item: EmittableClip) -> FCPXMLNode? {
            let clip = item.clip
            guard let content = clip.textContent, !content.isEmpty else { return nil }
            let style = clip.textStyle ?? TextStyle()
            let styleId = "textStyle\(nextTextStyleId)"
            nextTextStyleId += 1

            var textNodes: [FCPXMLNode] = [
                FCPXMLNode(name: "text", children: [
                    FCPXMLNode(name: "text-style", attributes: [("ref", styleId)], text: style.displayText(content)),
                ]),
                FCPXMLNode(name: "text-style-def", attributes: [("id", styleId)], children: [
                    FCPXMLNode(name: "text-style", attributes: textStyleAttributes(for: style)),
                ]),
            ]
            textNodes += titleTransformNodes(for: clip.transform)
            if let blend = blendNode(for: clip) { textNodes.append(blend) }
            return FCPXMLNode(name: "title", attributes: [
                ("ref", titleEffectId),
                ("name", content),
                ("lane", "\(item.lane)"),
                ("offset", time(frames: clip.startFrame)),
                ("start", "0s"),
                ("duration", time(frames: clip.durationFrames)),
                ("enabled", item.enabled ? "1" : "0"),
            ], children: textNodes)
        }

        private func blendNode(for clip: Clip) -> FCPXMLNode? {
            let frames = clip.keyframeFrames(for: .opacity)
            guard clip.opacity < 0.9995 || !frames.isEmpty else { return nil }
            var children: [FCPXMLNode] = []
            if !frames.isEmpty {
                children.append(keyframeParam(name: "amount", base: formatNumber(clip.opacity), clip: clip,
                                              property: .opacity, frames: frames) {
                    self.formatNumber(clip.rawOpacityAt(frame: $0))
                })
            }
            return FCPXMLNode(name: "adjust-blend", attributes: [("amount", formatNumber(clip.opacity))], children: children)
        }

        private func transformNode(for clip: Clip) -> FCPXMLNode? {
            let t = clip.transform
            let posFrames = clip.keyframeFrames(for: .position)
            let rotFrames = clip.keyframeFrames(for: .rotation)
            let scaleFrames = clip.keyframeFrames(for: .scale)
            let base = scaleValue(width: t.width, height: t.height, for: clip)
            let moved = abs(t.centerX - 0.5) > 0.0005 || abs(t.centerY - 0.5) > 0.0005
            let rotated = abs(t.rotation) > 0.005
            let scaled = base != "1 1"
            guard moved || rotated || scaled
                    || !posFrames.isEmpty || !rotFrames.isEmpty || !scaleFrames.isEmpty else { return nil }

            let fit = target == .resolve ? fitFractions(for: clip) : (w: 1.0, h: 1.0)
            var attrs: [(String, String)] = [("scale", base)]
            if rotated || !rotFrames.isEmpty { attrs.append(("rotation", formatNumber(-t.rotation))) }
            attrs.append(("anchor", "0 0"))
            attrs.append(("position", positionValue(for: t, fit: fit)))

            var params: [FCPXMLNode] = []
            if !scaleFrames.isEmpty {
                params.append(keyframeParam(name: "scale", base: base, clip: clip,
                                            property: .scale, frames: scaleFrames) {
                    let s = clip.sizeAt(frame: $0)
                    return self.scaleValue(width: s.width, height: s.height, for: clip)
                })
            }
            if !posFrames.isEmpty {
                params.append(keyframeParam(name: "position", base: positionValue(for: t, fit: fit), clip: clip,
                                            property: .position, frames: posFrames) {
                    self.positionValue(for: clip.transformAt(frame: $0), fit: fit)
                })
            }
            if !rotFrames.isEmpty {
                params.append(keyframeParam(name: "rotation", base: formatNumber(-t.rotation), clip: clip,
                                            property: .rotation, frames: rotFrames) {
                    self.formatNumber(-clip.rotationAt(frame: $0))
                })
            }
            return FCPXMLNode(name: "adjust-transform", attributes: attrs, children: params)
        }

        /// Removes aspect-fit scaling from the exported user scale.
        private func scaleValue(width: Double, height: Double, for clip: Clip) -> String {
            let fit = fitFractions(for: clip)
            var sx = width / fit.w
            var sy = height / fit.h
            if clip.transform.flipHorizontal { sx = -sx }
            if clip.transform.flipVertical { sy = -sy }
            return "\(formatNumber(sx)) \(formatNumber(sy))"
        }

        private func keyframeParam(name: String, base: String, clip: Clip, property: AnimatableProperty,
                                   frames: [Int], value: (Int) -> String) -> FCPXMLNode {
            let keyframes = frames.sorted().map { f -> FCPXMLNode in
                var attrs: [(String, String)] = [("time", keyframeTime(f, clip: clip))]
                if clip.interpolation(for: property, atFrame: f) == .linear { attrs.append(("curve", "linear")) }
                attrs.append(("value", value(f)))
                return FCPXMLNode(name: "keyframe", attributes: attrs)
            }
            return FCPXMLNode(name: "param", attributes: [("name", name), ("value", base)], children: [
                FCPXMLNode(name: "keyframeAnimation", children: keyframes),
            ])
        }

        /// Offsets retimed keyframes into the time map's output axis.
        private func keyframeTime(_ f: Int, clip: Clip) -> String {
            guard abs(clip.speed - 1.0) > 0.001 else { return time(frames: f - clip.startFrame) }
            let (p, q) = rationalSpeed(clip.speed)
            let num = clip.trimStartFrame * q + (f - clip.startFrame) * p
            return rationalTime(num: num, den: fps * p)
        }

        /// Uses Resolve trim units when source dimensions are known.
        private func cropNode(for clip: Clip) -> FCPXMLNode? {
            let c = clip.crop
            guard !c.isIdentity else { return nil }
            var lr = 100.0, tb = 100.0
            if target == .resolve,
               let entry = resolver.entry(for: clip.mediaRef),
               let sw = entry.sourceWidth, let sh = entry.sourceHeight, sw > 0, sh > 0 {
                let fit = min(Double(seqWidth) / Double(sw), Double(seqHeight) / Double(sh))
                lr = Double(sw) * 100.0 / Double(seqHeight)
                tb = 100.0 / fit
            }
            return FCPXMLNode(name: "adjust-crop", attributes: [("mode", "trim")], children: [
                FCPXMLNode(name: "trim-rect", attributes: [
                    ("top", formatNumber(c.top * tb)),
                    ("right", formatNumber(c.right * lr)),
                    ("bottom", formatNumber(c.bottom * tb)),
                    ("left", formatNumber(c.left * lr)),
                ]),
            ])
        }

        private func volumeNode(for clip: Clip) -> FCPXMLNode? {
            // Resolve drops keyframed volume on round-trip.
            guard abs(clip.volume - 1.0) > 0.0005 else { return nil }
            return FCPXMLNode(name: "adjust-volume", attributes: [("amount", formatNumber(decibels(clip.volume)))])
        }

        private func decibels(_ linear: Double) -> Double {
            linear > 0 ? 20.0 * log10(linear) : -96.0
        }

        /// Uses the time-map output axis for retimed clips and the source origin otherwise.
        private func clipStart(for clip: Clip, origin: (num: Int, den: Int) = (0, 1)) -> String {
            guard abs(clip.speed - 1.0) > 0.001 else { return time(frames: clip.trimStartFrame, from: origin) }
            let (p, q) = rationalSpeed(clip.speed)
            return rationalTime(num: clip.trimStartFrame * q, den: fps * p)
        }

        /// Maps the full asset so retimed clips do not end on black frames.
        private func timeMapNode(for clip: Clip, mediaFrames: Int, origin: (num: Int, den: Int) = (0, 1)) -> FCPXMLNode? {
            guard abs(clip.speed - 1.0) > 0.001, mediaFrames > 0 else { return nil }
            let (p, q) = rationalSpeed(clip.speed)
            return FCPXMLNode(name: "timeMap", attributes: [("frameSampling", "floor")], children: [
                FCPXMLNode(name: "timept", attributes: [
                    ("time", "0s"), ("value", rationalTime(num: origin.num, den: origin.den)), ("interp", "linear"),
                ]),
                FCPXMLNode(name: "timept", attributes: [
                    ("time", rationalTime(num: mediaFrames * q, den: fps * p)),
                    ("value", time(frames: mediaFrames, from: origin)),
                    ("interp", "linear"),
                ]),
            ])
        }

        /// Approximates user-entered speed with a small exact fraction.
        private func rationalSpeed(_ speed: Double) -> (p: Int, q: Int) {
            var best = (p: 1, q: 1), bestErr = Double.infinity
            for q in 1...1000 {
                let p = Int((speed * Double(q)).rounded())
                guard p > 0 else { continue }
                let err = abs(speed - Double(p) / Double(q))
                if err < bestErr { best = (p, q); bestErr = err; if err == 0 { break } }
            }
            return best
        }

        private func rationalTime(num: Int, den: Int) -> String {
            guard num != 0 else { return "0s" }
            let g = gcd(abs(num), abs(den))
            let n = num / g, d = den / g
            return d == 1 ? "\(n)s" : "\(n)/\(d)s"
        }

        private func collectResources(from clips: [EmittableClip]) {
            struct Caps {
                var mediaRefs: [String]
                var hasVideo = false
                var hasAudio = false
                var duration = 0
                let entry: MediaManifestEntry
                let url: URL
            }
            var order: [String] = []
            var caps: [String: Caps] = [:]

            for item in clips {
                let clip = item.clip
                guard clip.mediaType != .text, clip.mediaType != .lottie,
                      let entry = resolver.entry(for: clip.mediaRef),
                      let url = resolver.resolveURL(for: clip.mediaRef) else { continue }

                let key = sourceKey(for: url)
                let duration = sourceDurationFrames(for: entry, clip: clip)
                let isVisual = clip.mediaType != .audio
                // Video resources include source audio when present.
                let isAudio = clip.mediaType == .audio || (clip.mediaType == .video && entry.hasAudio == true)
                var entryCaps = caps[key] ?? {
                    order.append(key)
                    return Caps(mediaRefs: [], entry: entry, url: url)
                }()
                if !entryCaps.mediaRefs.contains(clip.mediaRef) {
                    entryCaps.mediaRefs.append(clip.mediaRef)
                }
                entryCaps.hasVideo = entryCaps.hasVideo || isVisual
                entryCaps.hasAudio = entryCaps.hasAudio || isAudio
                entryCaps.duration = max(entryCaps.duration, duration)
                caps[key] = entryCaps
            }

            for key in order {
                guard let c = caps[key] else { continue }
                let id = resources.count + 1
                for ref in c.mediaRefs {
                    resourceIndex[ref] = resources.count
                }
                let tc = c.mediaRefs.compactMap { startTimecodes[$0] }.first?.rationalSeconds ?? (0, 1)
                resources.append(MediaResource(
                    mediaRef: c.mediaRefs.first ?? c.entry.id,
                    assetId: "asset\(id)",
                    formatId: c.hasVideo ? "r\(id + 1)" : nil,
                    // Only A/V sources need srcEnable gating through a compound.
                    compoundId: c.hasVideo && c.hasAudio ? "media\(id)" : nil,
                    entry: c.entry,
                    url: c.url,
                    durationFrames: c.duration,
                    hasVideo: c.hasVideo,
                    hasAudio: c.hasAudio,
                    startTimecode: tc
                ))
            }
        }

        private func sourceKey(for url: URL) -> String {
            url.standardizedFileURL.resolvingSymlinksInPath().path
        }

        private func formatNode(for resource: MediaResource) -> FCPXMLNode? {
            guard let formatId = resource.formatId else { return nil }
            let width = resource.entry.sourceWidth ?? seqWidth
            let height = resource.entry.sourceHeight ?? seqHeight
            let rawFPS = resource.entry.sourceFPS ?? Double(fps)
            return FCPXMLNode(name: "format", attributes: [
                ("id", formatId),
                ("name", videoFormatName(width: width, height: height, fps: rawFPS)),
                ("frameDuration", frameDuration(forFPS: rawFPS)),
                ("width", "\(width)"),
                ("height", "\(height)"),
                ("colorSpace", "1-1-1 (Rec. 709)"),
            ])
        }

        // Resolve relinks by the full filename, including its extension.
        private func fileName(for resource: MediaResource) -> String {
            resource.url.lastPathComponent
        }

        private func assetNode(for resource: MediaResource) -> FCPXMLNode {
            var attrs: [(String, String)] = [
                ("id", resource.assetId),
                ("name", fileName(for: resource)),
                ("start", rationalTime(num: resource.startTimecode.num, den: resource.startTimecode.den)),
                ("duration", time(frames: resource.durationFrames)),
            ]
            if resource.hasVideo {
                attrs.append(("hasVideo", "1"))
                attrs.append(("videoSources", "1"))
                if let formatId = resource.formatId {
                    attrs.append(("format", formatId))
                }
            }
            if resource.hasAudio {
                // Default audio metadata does not affect relinking.
                attrs.append(("hasAudio", "1"))
                attrs.append(("audioSources", "1"))
                attrs.append(("audioChannels", "2"))
                attrs.append(("audioRate", "48000"))
            }
            return FCPXMLNode(name: "asset", attributes: attrs, children: [
                FCPXMLNode(name: "media-rep", attributes: [
                    ("kind", "original-media"),
                    ("src", mediaSrc(for: resource)),
                ]),
            ])
        }

        // Resolve cannot relink sub-delimiters encoded as XML entities.
        private func mediaSrc(for resource: MediaResource) -> String {
            resource.url.absoluteString.map { ch in
                "'!$&()*+,;=".contains(ch) ? String(format: "%%%02X", ch.asciiValue ?? 0) : String(ch)
            }.joined()
        }

        private func sourceDurationFrames(for entry: MediaManifestEntry, clip: Clip) -> Int {
            let manifestFrames = max(0, secondsToFrame(seconds: entry.duration, fps: fps))
            return max(manifestFrames, clip.sourceDurationFrames)
        }

        private func emittableClips(of timeline: Timeline) -> [EmittableClip] {
            let visualTrackCount = timeline.tracks.filter { $0.type.isVisual }.count
            var visualOrdinal = 0
            var audioOrdinal = 0
            var clips: [EmittableClip] = []

            for track in timeline.tracks {
                let lane: Int
                let enabled: Bool
                if track.type.isVisual {
                    lane = visualTrackCount - visualOrdinal
                    enabled = !track.hidden
                    visualOrdinal += 1
                } else if track.type == .audio {
                    lane = -(audioOrdinal + 1)
                    enabled = !track.muted
                    audioOrdinal += 1
                } else {
                    continue
                }
                clips += track.clips
                    .filter(isEmittable)
                    .sorted { $0.startFrame < $1.startFrame }
                    .map { EmittableClip(clip: $0, lane: lane, enabled: enabled) }
            }
            return clips
        }

        private func isEmittable(_ clip: Clip) -> Bool {
            guard clip.durationFrames > 0 else { return false }
            // Nest carriers require a resolved compound resource.
            if clip.sourceClipType == .sequence { return nestIndex[clip.mediaRef] != nil }
            switch clip.mediaType {
            case .text:
                return clip.textContent?.isEmpty == false
            case .lottie, .sequence:
                return false
            case .audio, .video, .image:
                return resolver.resolveURL(for: clip.mediaRef) != nil
            }
        }

        private func time(frames: Int) -> String {
            guard frames != 0 else { return "0s" }
            let divisor = gcd(abs(frames), fps)
            let numerator = frames / divisor
            let denominator = fps / divisor
            return denominator == 1 ? "\(numerator)s" : "\(numerator)/\(denominator)s"
        }

        /// Adds frame time to an exact source origin without NTSC drift.
        private func time(frames: Int, from origin: (num: Int, den: Int)) -> String {
            guard origin.num != 0 else { return time(frames: frames) }
            return rationalTime(num: frames * origin.den + origin.num * fps, den: fps * origin.den)
        }

        private func videoFormatName(width: Int, height: Int, fps rawFPS: Double) -> String {
            recognizedVideoFormatName(width: width, height: height, fps: rawFPS)
                ?? "FFVideoFormat\(width)x\(height)p\(formatRateSuffix(forFPS: rawFPS))"
        }

        private func sequenceFormatName(width: Int, height: Int, fps rawFPS: Double) -> String {
            recognizedVideoFormatName(width: width, height: height, fps: rawFPS) ?? "FFVideoFormatRateUndefined"
        }

        private func recognizedVideoFormatName(width: Int, height: Int, fps rawFPS: Double) -> String? {
            let rate = formatRateSuffix(forFPS: rawFPS)
            switch (width, height) {
            case (1280, 720):
                return "FFVideoFormat720p\(rate)"
            case (1920, 1080):
                return "FFVideoFormat1080p\(rate)"
            case (3840, 2160):
                return "FFVideoFormat3840x2160p\(rate)"
            case (4096, 2160):
                return "FFVideoFormat4096x2160p\(rate)"
            default:
                return nil
            }
        }

        private func formatRateSuffix(forFPS rawFPS: Double) -> String {
            let rounded = max(1, Int(rawFPS.rounded()))
            let ntscRate = Double(rounded) * 1000.0 / 1001.0
            if abs(rawFPS - ntscRate) < abs(rawFPS - Double(rounded)) {
                let fps100 = Int((ntscRate * 100.0).rounded())
                return "\(fps100 / 100)\(String(format: "%02d", fps100 % 100))"
            }
            return "\(rounded)"
        }

        private func frameDuration(forFPS rawFPS: Double) -> String {
            let rounded = max(1, Int(rawFPS.rounded()))
            let ntscRate = Double(rounded) * 1000.0 / 1001.0
            if abs(rawFPS - ntscRate) < abs(rawFPS - Double(rounded)) {
                return "1001/\(rounded * 1000)s"
            }
            return "1/\(rounded)s"
        }

        private func colorString(_ color: TextStyle.RGBA) -> String {
            "\(formatNumber(color.r)) \(formatNumber(color.g)) \(formatNumber(color.b)) \(formatNumber(color.a))"
        }

        private func textStyleAttributes(for style: TextStyle) -> [(String, String)] {
            let resolvedFont = style.resolvedFont(size: CGFloat(style.fontSize))
            let family = resolvedFont.familyName ?? fontFamilyFallback(style.fontName)
            let face = fontFace(for: style, resolvedFont: resolvedFont)
            let fontSize = style.fontSize * style.fontScale
            var attrs: [(String, String)] = [
                ("font", family),
                ("fontFace", face),
                ("fontSize", formatNumber(fontSize)),
                ("fontColor", colorString(style.color)),
                ("alignment", style.alignment.rawValue),
            ]
            if style.border.enabled {
                attrs.append(("strokeColor", colorString(style.border.color)))
                attrs.append(("strokeWidth", formatNumber(max(0, style.border.width))))
            }
            return attrs
        }

        private func titleTransformNodes(for transform: Transform) -> [FCPXMLNode] {
            [
                FCPXMLNode(name: "adjust-conform", attributes: [("type", "fit")]),
                FCPXMLNode(name: "adjust-transform", attributes: [
                    ("scale", "1 1"),
                    ("anchor", "0 0"),
                    ("position", positionValue(for: transform)),
                ]),
            ]
        }

        private func positionValue(for transform: Transform, fit: (w: Double, h: Double) = (1, 1)) -> String {
            let unit = Double(seqHeight) / 100.0
            let x = (transform.centerX - 0.5) * Double(seqWidth) / unit / fit.w
            let y = (0.5 - transform.centerY) * Double(seqHeight) / unit / fit.h
            return "\(formatNumber(x)) \(formatNumber(y))"
        }

        /// Returns per-axis conform-fit fractions, or 1×1 without source dimensions.
        private func fitFractions(for clip: Clip) -> (w: Double, h: Double) {
            guard let entry = resolver.entry(for: clip.mediaRef),
                  let sw = entry.sourceWidth, let sh = entry.sourceHeight, sw > 0, sh > 0 else { return (1, 1) }
            let sourceAspect = Double(sw) / Double(sh)
            let frameAspect = Double(seqWidth) / Double(seqHeight)
            return sourceAspect >= frameAspect
                ? (1, frameAspect / sourceAspect)
                : (sourceAspect / frameAspect, 1)
        }

        private func fontFamilyFallback(_ fontName: String) -> String {
            fontName.split(separator: "-", maxSplits: 1).first.map(String.init) ?? fontName
        }

        private func fontFace(for style: TextStyle, resolvedFont: NSFont) -> String {
            let traits = CTFontGetSymbolicTraits(resolvedFont as CTFont)
            let matchesRequestedTraits =
                traits.contains(.traitBold) == style.isBold &&
                traits.contains(.traitItalic) == style.isItalic
            if matchesRequestedTraits,
               let face = resolvedFont.fontDescriptor.object(forKey: .face) as? String {
                return face
            }
            return fontFaceFallback(isBold: style.isBold, isItalic: style.isItalic)
        }

        private func fontFaceFallback(isBold: Bool, isItalic: Bool) -> String {
            switch (isBold, isItalic) {
            case (true, true):
                return "Bold Italic"
            case (true, false):
                return "Bold"
            case (false, true):
                return "Italic"
            case (false, false):
                return "Regular"
            }
        }

        private func formatNumber(_ value: Double) -> String {
            let rounded = value.rounded(toPlaces: 4)
            if rounded == rounded.rounded() { return "\(Int(rounded))" }
            var s = String(format: "%.4f", rounded)
            while s.last == "0" { s.removeLast() }
            if s.last == "." { s.removeLast() }
            return s
        }

        private func gcd(_ a: Int, _ b: Int) -> Int {
            var x = a, y = b
            while y != 0 {
                let r = x % y
                x = y
                y = r
            }
            return max(1, x)
        }

    }
}

private struct FCPXMLNode {
    let name: String
    var attributes: [(String, String)] = []
    var text: String? = nil
    var children: [FCPXMLNode] = []
}

private func renderFCPXML(_ node: FCPXMLNode, indent: Int) -> String {
    let pad = String(repeating: " ", count: indent)
    let attrs = node.attributes.map { " \($0.0)=\"\(escapeFCPXML($0.1))\"" }.joined()
    if let text = node.text {
        return "\(pad)<\(node.name)\(attrs)>\(escapeFCPXML(text))</\(node.name)>"
    }
    guard !node.children.isEmpty else { return "\(pad)<\(node.name)\(attrs)/>" }
    let inner = node.children.map { renderFCPXML($0, indent: indent + 2) }.joined(separator: "\n")
    return "\(pad)<\(node.name)\(attrs)>\n\(inner)\n\(pad)</\(node.name)>"
}

private func escapeFCPXML(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
     .replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;")
     .replacingOccurrences(of: "\"", with: "&quot;")
     .replacingOccurrences(of: "'", with: "&apos;")
}
