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

/// Exports a Timeline as FCPXML (for DaVinci Resolve / Final Cut Pro). Companion to XMLExporter
/// (XMEML, for Premiere). The document is an `FCPXMLNode` tree (defined at the bottom); `renderFCPXML`
/// owns indentation and escaping. Read `build()` top-down: `<fcpxml>` → `<resources>` (formats +
/// assets + per-clip compound clips) → `<library>/<event>/<project>/<sequence>`. The timeline is one
/// `<gap>` with every clip connected on a lane.
///
/// Encoding facts (reverse-engineered from Resolve round-trips):
/// - Position: unit = 1% of frame height, square, origin at center, +Y up.
/// - Scale: multiplier on the conform-fit size, so we divide the aspect-fit out of width/height.
/// - Rotation: degrees, negated (FCP is counter-clockwise-positive). Flip: negative scale.
/// - Crop: `<adjust-crop>/<trim-rect>`, a percentage of the source per edge.
/// - Retime: a visual clip is a `<ref-clip>` over a compound clip holding the full media; the
///   `<timeMap>` ramps the whole media (output[0, media/speed] → source[0, media]) and `start` windows
///   in along the output axis (= source in-point ÷ speed). A clip-local ramp blacks the tail.
/// - Keyframes: child `<param>/<keyframeAnimation>`; `time` is offset by `start` (the output axis),
///   `value` in the param's own unit. Volume: `<adjust-volume amount>` in dB.
///
/// What transports: clip placement/trims, speed, lane order, enabled state; text + font/face/
/// size/color/alignment; position/scale/rotation/flip (+ position/scale/rotation keyframes);
/// crop; opacity (+ keyframes); static volume.
///
/// What does NOT: keyframed audio volume and audio fades (Resolve drops both itself); text
/// background/border boxes (no FCPXML form); crop keyframes; title rotation/scale; color &
/// effects; Lottie clips.
///
/// Reference: https://developer.apple.com/documentation/professional-video-applications/fcpxml-reference
enum FCPXMLExporter {
    static func export(timeline: Timeline, resolver: MediaResolver,
                       version: FCPXMLVersion = .default, outputURL: URL) throws {
        let xml = Builder(timeline: timeline, resolver: resolver, version: version).build()
        guard let data = xml.data(using: .utf8) else { throw ExportError.xmlEncodingFailed }
        try data.write(to: outputURL)
    }

    private final class Builder {
        private let timeline: Timeline
        private let resolver: MediaResolver
        private let version: FCPXMLVersion
        private let fps: Int
        private let seqWidth: Int
        private let seqHeight: Int
        private let sequenceFormatId = "r1"
        private let titleEffectId = "titleBasic"
        private var resourceIndex: [String: Int] = [:]
        private var resources: [MediaResource] = []
        private var nextTextStyleId = 1
        // A synced A/V pair collapses into one ref-clip; the audio partner is dropped, its volume kept.
        private var linkedAudioForVideo: [String: Clip] = [:]
        private var redundantAudioClipIds: Set<String> = []

        private struct EmittableClip {
            let clip: Clip
            let lane: Int
            let enabled: Bool
        }

        // One asset per resolved source file.
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
        }

        init(timeline: Timeline, resolver: MediaResolver, version: FCPXMLVersion) {
            self.timeline = timeline
            self.resolver = resolver
            self.version = version
            self.fps = max(1, timeline.fps)
            self.seqWidth = timeline.width
            self.seqHeight = timeline.height
        }

        func build() -> String {
            let clips = emittableClips()
            collectResources(from: clips)
            indexLinkedPairs(clips)
            let hasTitles = clips.contains { $0.clip.mediaType == .text }
            let root = FCPXMLNode(name: "fcpxml", attributes: [("version", version.rawValue)], children: [
                resourcesNode(hasTitles: hasTitles),
                libraryNode(clips: clips),
            ])
            return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE fcpxml>\n" + renderFCPXML(root, indent: 0)
        }

        // Video + audio with matching linkGroup, source, timing, and enabled state are a synced pair
        private func indexLinkedPairs(_ clips: [EmittableClip]) {
            var byGroup: [String: (videos: [EmittableClip], audios: [EmittableClip])] = [:]
            for item in clips {
                guard let group = item.clip.linkGroupId else { continue }
                switch item.clip.mediaType {
                case .video, .image: byGroup[group, default: ([], [])].videos.append(item)
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
            return FCPXMLNode(name: "resources", children: children)
        }

        private func compoundClipNode(for resource: MediaResource) -> FCPXMLNode? {
            guard let compoundId = resource.compoundId else { return nil }
            let dur = time(frames: resource.durationFrames)
            // <asset-clip> carries both streams so the outer ref-clip can deliver audio; <clip>/<video>
            // is video-only. Outer srcEnable gates what actually plays.
            let innerClip: FCPXMLNode
            if resource.hasAudio {
                innerClip = FCPXMLNode(name: "asset-clip", attributes: [
                    ("ref", resource.assetId),
                    ("name", resource.entry.name),
                    ("duration", dur),
                    ("start", "0s"),
                    ("offset", "0s"),
                    ("format", resource.formatId ?? sequenceFormatId),
                ])
            } else {
                let video = FCPXMLNode(name: "video", attributes: [
                    ("ref", resource.assetId),
                    ("duration", dur),
                    ("start", "0s"),
                    ("offset", "0s"),
                ])
                innerClip = FCPXMLNode(name: "clip", attributes: [
                    ("name", resource.entry.name),
                    ("duration", dur),
                    ("start", "0s"),
                    ("offset", "0s"),
                    ("format", resource.formatId ?? sequenceFormatId),
                ], children: [video])
            }
            let sequence = FCPXMLNode(name: "sequence", attributes: [
                ("format", resource.formatId ?? sequenceFormatId),
                ("duration", dur),
                ("tcStart", "0s"),
                ("tcFormat", "NDF"),
            ], children: [FCPXMLNode(name: "spine", children: [innerClip])])
            return FCPXMLNode(name: "media", attributes: [
                ("id", compoundId),
                ("name", resource.entry.name),
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

            return FCPXMLNode(name: "project", attributes: [("name", "Timeline Export")], children: [
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
                    case .audio, .video, .image:
                        return assetClipNode(for: item)
                    case .lottie:
                        return nil
                    }
                }
        }

        private func assetClipNode(for item: EmittableClip) -> FCPXMLNode? {
            let clip = item.clip
            guard let i = resourceIndex[clip.mediaRef] else { return nil }
            let resource = resources[i]

            // Video/image → <ref-clip>. A linked audio partner rides along (srcEnable omitted = both
            // streams, its volume carried here); otherwise pin to video so the source's audio stays out.
            if clip.mediaType != .audio, let compoundId = resource.compoundId {
                let linkedAudio = linkedAudioForVideo[clip.id]
                var attrs: [(String, String)] = [
                    ("ref", compoundId),
                    ("name", resolver.displayName(for: clip.mediaRef)),
                    ("lane", "\(item.lane)"),
                    ("offset", time(frames: clip.startFrame)),
                    ("start", clipStart(for: clip)),
                    ("duration", time(frames: clip.durationFrames)),
                    ("enabled", item.enabled ? "1" : "0"),
                ]
                if linkedAudio == nil { attrs.append(("srcEnable", "video")) }
                return FCPXMLNode(name: "ref-clip", attributes: attrs, children: [
                    timeMapNode(for: clip, mediaFrames: resource.durationFrames),
                    FCPXMLNode(name: "adjust-conform", attributes: [("type", "fit")]),
                    cropNode(for: clip),
                    transformNode(for: clip),
                    blendNode(for: clip),
                    linkedAudio.flatMap(volumeNode),
                ].compactMap { $0 })
            }

            // Audio against an A/V source must go through the compound too
            if clip.mediaType == .audio, let compoundId = resource.compoundId {
                let attrs: [(String, String)] = [
                    ("ref", compoundId),
                    ("name", resolver.displayName(for: clip.mediaRef)),
                    ("lane", "\(item.lane)"),
                    ("offset", time(frames: clip.startFrame)),
                    ("start", clipStart(for: clip)),
                    ("duration", time(frames: clip.durationFrames)),
                    ("enabled", item.enabled ? "1" : "0"),
                    ("srcEnable", "audio"),
                ]
                return FCPXMLNode(name: "ref-clip", attributes: attrs, children: [
                    timeMapNode(for: clip, mediaFrames: resource.durationFrames),
                    volumeNode(for: clip),
                ].compactMap { $0 })
            }

            let attrs: [(String, String)] = [
                ("ref", resource.assetId),
                ("name", resolver.displayName(for: clip.mediaRef)),
                ("lane", "\(item.lane)"),
                ("offset", time(frames: clip.startFrame)),
                ("start", clipStart(for: clip)),
                ("duration", time(frames: clip.durationFrames)),
                ("enabled", item.enabled ? "1" : "0"),
            ]
            return FCPXMLNode(
                name: "asset-clip",
                attributes: attrs,
                children: [
                    timeMapNode(for: clip, mediaFrames: resource.durationFrames),
                    volumeNode(for: clip),
                ].compactMap { $0 }
            )
        }

        private func titleNode(for item: EmittableClip) -> FCPXMLNode? {
            let clip = item.clip
            guard let content = clip.textContent, !content.isEmpty else { return nil }
            let style = clip.textStyle ?? TextStyle()
            let styleId = "textStyle\(nextTextStyleId)"
            nextTextStyleId += 1

            var textNodes: [FCPXMLNode] = [
                FCPXMLNode(name: "text", children: [
                    FCPXMLNode(name: "text-style", attributes: [("ref", styleId)], text: content),
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

        /// Position + scale + rotation (static or keyframed) for a video/image clip.
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

            var attrs: [(String, String)] = [("scale", base)]
            if rotated || !rotFrames.isEmpty { attrs.append(("rotation", formatNumber(-t.rotation))) }
            attrs.append(("anchor", "0 0"))
            attrs.append(("position", positionValue(for: t)))

            var params: [FCPXMLNode] = []
            if !scaleFrames.isEmpty {
                params.append(keyframeParam(name: "scale", base: base, clip: clip,
                                            property: .scale, frames: scaleFrames) {
                    let s = clip.sizeAt(frame: $0)
                    return self.scaleValue(width: s.width, height: s.height, for: clip)
                })
            }
            if !posFrames.isEmpty {
                params.append(keyframeParam(name: "position", base: positionValue(for: t), clip: clip,
                                            property: .position, frames: posFrames) {
                    self.positionValue(for: clip.transformAt(frame: $0))
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

        /// Divide the aspect-fit out of our frame-fraction width/height so only user scaling remains.
        private func scaleValue(width: Double, height: Double, for clip: Clip) -> String {
            var sx = width, sy = height
            if let entry = resolver.entry(for: clip.mediaRef),
               let sw = entry.sourceWidth, let sh = entry.sourceHeight, sw > 0, sh > 0 {
                let sourceAspect = Double(sw) / Double(sh)
                let frameAspect = Double(seqWidth) / Double(seqHeight)
                let fitW = sourceAspect >= frameAspect ? 1.0 : sourceAspect / frameAspect
                let fitH = sourceAspect >= frameAspect ? frameAspect / sourceAspect : 1.0
                sx = width / fitW
                sy = height / fitH
            }
            if clip.transform.flipHorizontal { sx = -sx }
            if clip.transform.flipVertical { sy = -sy }
            return "\(formatNumber(sx)) \(formatNumber(sy))"
        }

        /// A keyframed `<param>`: time is in the clip's output axis, value uses the param's own unit.
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

        /// A retimed clip's keyframes live in the timeMap's output axis, so `time` is offset by the clip's
        /// `start` (= clipStart): `start + (f − startFrame)/fps`. Without it the animation lands before the
        /// content and plays compressed. Unspeeded clips have no timeMap origin, so they stay clip-relative.
        private func keyframeTime(_ f: Int, clip: Clip) -> String {
            guard abs(clip.speed - 1.0) > 0.001 else { return time(frames: f - clip.startFrame) }
            let (p, q) = rationalSpeed(clip.speed)
            let num = clip.trimStartFrame * q + (f - clip.startFrame) * p
            return rationalTime(num: num, den: fps * p)
        }

        private func cropNode(for clip: Clip) -> FCPXMLNode? {
            let c = clip.crop
            guard !c.isIdentity else { return nil }
            return FCPXMLNode(name: "adjust-crop", attributes: [("mode", "trim")], children: [
                FCPXMLNode(name: "trim-rect", attributes: [
                    ("top", formatNumber(c.top * 100)),
                    ("right", formatNumber(c.right * 100)),
                    ("bottom", formatNumber(c.bottom * 100)),
                    ("left", formatNumber(c.left * 100)),
                ]),
            ])
        }

        private func volumeNode(for clip: Clip) -> FCPXMLNode? {
            // Keyframed audio volume has no FCPXML form Resolve round-trips (its own export drops it),
            // so export the static level only.
            guard abs(clip.volume - 1.0) > 0.0005 else { return nil }
            return FCPXMLNode(name: "adjust-volume", attributes: [("amount", formatNumber(decibels(clip.volume)))])
        }

        private func decibels(_ linear: Double) -> Double {
            linear > 0 ? 20.0 * log10(linear) : -96.0
        }

        /// Source in-point in the post-retime output axis Resolve expects (source ÷ speed); the raw
        /// source frame when unspeeded.
        private func clipStart(for clip: Clip) -> String {
            guard abs(clip.speed - 1.0) > 0.001 else { return time(frames: clip.trimStartFrame) }
            let (p, q) = rationalSpeed(clip.speed)
            return rationalTime(num: clip.trimStartFrame * q, den: fps * p)
        }

        /// Resolve ramps the WHOLE media (`output[0, media/speed] → source[0, media]`) and windows in via
        /// `start`/`duration`. A ramp that stops at the clip edge leaves no tail mapping → black last frames.
        private func timeMapNode(for clip: Clip, mediaFrames: Int) -> FCPXMLNode? {
            guard abs(clip.speed - 1.0) > 0.001, mediaFrames > 0 else { return nil }
            let (p, q) = rationalSpeed(clip.speed)
            return FCPXMLNode(name: "timeMap", attributes: [("frameSampling", "floor")], children: [
                FCPXMLNode(name: "timept", attributes: [("time", "0s"), ("value", "0s"), ("interp", "linear")]),
                FCPXMLNode(name: "timept", attributes: [
                    ("time", rationalTime(num: mediaFrames * q, den: fps * p)),  // media / speed
                    ("value", time(frames: mediaFrames)),                        // full media
                    ("interp", "linear"),
                ]),
            ])
        }

        /// Speed as a small-denominator fraction, so the timeMap slope is exact and `start` maps back to
        /// the original source frame. Speeds are user values (1.25, 1.24, 2.0, 0.5…).
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
                // Audio clip → audio stream; video clip → audio too if the source file carries it.
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
                resources.append(MediaResource(
                    mediaRef: c.mediaRefs.first ?? c.entry.id,
                    assetId: "asset\(id)",
                    formatId: c.hasVideo ? "r\(id + 1)" : nil,
                    compoundId: c.hasVideo ? "media\(id)" : nil,
                    entry: c.entry,
                    url: c.url,
                    durationFrames: c.duration,
                    hasVideo: c.hasVideo,
                    hasAudio: c.hasAudio
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

        private func assetNode(for resource: MediaResource) -> FCPXMLNode {
            var attrs: [(String, String)] = [
                ("id", resource.assetId),
                ("name", resource.entry.name),
                ("start", "0s"),
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
                // We don't probe channels/rate; 2ch/48k is FCP's default and doesn't affect relinking.
                attrs.append(("hasAudio", "1"))
                attrs.append(("audioSources", "1"))
                attrs.append(("audioChannels", "2"))
                attrs.append(("audioRate", "48000"))
            }
            return FCPXMLNode(name: "asset", attributes: attrs, children: [
                FCPXMLNode(name: "media-rep", attributes: [
                    ("kind", "original-media"),
                    ("src", resource.url.absoluteString),
                ]),
            ])
        }

        private func sourceDurationFrames(for entry: MediaManifestEntry, clip: Clip) -> Int {
            let manifestFrames = max(0, secondsToFrame(seconds: entry.duration, fps: fps))
            return max(manifestFrames, clip.sourceDurationFrames)
        }

        private func emittableClips() -> [EmittableClip] {
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
            switch clip.mediaType {
            case .text:
                return clip.textContent?.isEmpty == false
            case .lottie:
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
            return [
                ("font", family),
                ("fontFace", face),
                ("fontSize", formatNumber(fontSize)),
                ("fontColor", colorString(style.color)),
                ("alignment", style.alignment.rawValue),
            ]
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

        private func positionValue(for transform: Transform) -> String {
            let unit = Double(seqHeight) / 100.0
            let x = (transform.centerX - 0.5) * Double(seqWidth) / unit
            let y = (0.5 - transform.centerY) * Double(seqHeight) / unit
            return "\(formatNumber(x)) \(formatNumber(y))"
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
