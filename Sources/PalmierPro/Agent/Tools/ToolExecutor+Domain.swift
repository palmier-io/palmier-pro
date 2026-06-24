import AVFoundation
import CoreGraphics
import Foundation

extension ToolExecutor {
    private static let defaultDomain = "malay_wedding"
    private static let classifyMaxClips = 24
    private static let classifyDefaultClips = 16

    // MARK: - get_reference_guidance

    private static let getReferenceGuidanceAllowedKeys: Set<String> = ["domain", "ceremonyType", "momentType"]

    func getReferenceGuidance(_ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.getReferenceGuidanceAllowedKeys, path: "get_reference_guidance")
        let domain = args.string("domain") ?? Self.defaultDomain
        guard let pack = DomainPackStore.load(domain) else {
            throw ToolError("get_reference_guidance: no domain pack for '\(domain)'. Bundled domains: malay_wedding.")
        }

        var payload: [String: Any] = ["domain": pack.domain]
        if let culture = pack.culture { payload["culture"] = culture }
        if let pacing = pack.typicalPacing { payload["typicalPacing"] = pacing }
        if let audio = pack.audioPatterns { payload["audioPatterns"] = audio }

        if let momentType = args.string("momentType") {
            guard let moment = pack.moment(momentType) else {
                throw ToolError("get_reference_guidance: unknown momentType '\(momentType)'. Known: \(pack.momentNames.joined(separator: ", ")).")
            }
            payload["moment"] = Self.momentJSON(momentType, moment)
        } else if let ceremonyType = args.string("ceremonyType") {
            guard let slots = pack.ceremony(ceremonyType) else {
                throw ToolError("get_reference_guidance: unknown ceremonyType '\(ceremonyType)'. Known: \(pack.ceremonyNames.joined(separator: ", ")).")
            }
            payload["ceremonyType"] = ceremonyType.lowercased()
            payload["timeline"] = slots.compactMap { name in pack.moment(name).map { Self.momentJSON(name, $0) } }
            payload["note"] = "Slots are in canonical edit order. Place core slots; include optional when good footage exists; drop filler."
        } else {
            payload["ceremonies"] = pack.ceremonyNames
            payload["moments"] = pack.momentNames.compactMap { name in pack.moment(name).map { Self.momentJSON(name, $0) } }
            payload["note"] = "Pass ceremonyType for an ordered timeline, or momentType for one moment's guidance."
        }

        // How real editors actually sequence shots — available alongside any branch.
        if args.string("momentType") == nil, let ls = pack.learnedSequences {
            payload["learnedSequences"] = Self.learnedJSON(ls)
        }

        guard let json = Self.jsonString(payload) else {
            throw ToolError("get_reference_guidance: failed to encode result.")
        }
        return .ok(json)
    }

    private static func momentJSON(_ name: String, _ m: DomainPack.Moment) -> [String: Any] {
        var out: [String: Any] = [
            "momentType": name,
            "category": m.category,
            "importance": m.importance,
            "audioPolicy": m.audioPolicy,
            "preferredShots": m.preferredShots,
            "avoidQualities": m.avoidQualities,
            "cues": m.classificationCues,
        ]
        if let dur = m.typicalDurationSec { out["typicalDurationSec"] = dur }
        return out
    }

    private static func learnedJSON(_ ls: DomainPack.LearnedSequences) -> [String: Any] {
        func pairs(_ list: [DomainPack.MomentFraction]) -> [[String: Any]] {
            list.map { ["moment": $0.moment, "fraction": $0.fraction] }
        }
        var out: [String: Any] = [:]
        if let v = ls.videosAnalyzed { out["videosAnalyzed"] = v }
        if let o = ls.openingMoments { out["openingMoments"] = pairs(o) }
        if let n = ls.commonNext { out["commonNext"] = n.mapValues(pairs) }
        if let note = ls.note { out["note"] = note }
        return out
    }

    // MARK: - classify_moments

    private static let classifyMomentsAllowedKeys: Set<String> = ["domain", "ceremonyType", "mediaRefs", "maxClips"]

    func classifyMoments(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.classifyMomentsAllowedKeys, path: "classify_moments")
        let domain = args.string("domain") ?? Self.defaultDomain
        let pack = DomainPackStore.load(domain)

        // Resolve the target video assets.
        let assets: [MediaAsset]
        let explicit = args.stringArray("mediaRefs")
        if !explicit.isEmpty {
            assets = try explicit.map { try asset($0, editor: editor) }
        } else {
            assets = editor.mediaAssets.filter { $0.type == .video }
        }
        let videos = assets.filter { $0.type == .video }
        guard !videos.isEmpty else {
            throw ToolError("classify_moments: no video assets to classify.")
        }
        let limit = min(max(args.int("maxClips") ?? Self.classifyDefaultClips, 1), Self.classifyMaxClips)
        let batch = Array(videos.prefix(limit))

        // Candidate moments the agent should choose from.
        let ceremonyType = args.string("ceremonyType")
        let candidateNames: [String]
        if let pack, let ct = ceremonyType, let slots = pack.ceremony(ct) {
            candidateNames = slots
        } else if let pack {
            candidateNames = pack.momentNames
        } else {
            candidateNames = []
        }
        let candidates: [[String: Any]] = candidateNames.compactMap { name in
            pack?.moment(name).map { ["momentType": name, "cues": $0.classificationCues, "importance": $0.importance] }
        }

        // Sample one representative (midpoint) frame per clip.
        var imageBlocks: [ToolResult.Block] = []
        var clipMeta: [[String: Any]] = []
        for (index, asset) in batch.enumerated() {
            var meta: [String: Any] = [
                "index": index,
                "mediaRef": asset.id,
                "name": asset.name,
                "durationSeconds": (asset.duration * 100).rounded() / 100,
                "filenameSequenceHint": Self.filenameSequenceHint(asset.name),
            ]
            if let tag = asset.momentTag { meta["existingTag"] = tag.momentType }
            if FileManager.default.fileExists(atPath: asset.url.path),
               let jpeg = await Self.sampleMidpointJPEG(url: asset.url, duration: asset.duration) {
                imageBlocks.append(.image(base64: jpeg.base64EncodedString(), mediaType: "image/jpeg"))
                meta["frame"] = "image #\(imageBlocks.count)"
            } else {
                meta["frame"] = "unavailable"
            }
            clipMeta.append(meta)
        }

        var payload: [String: Any] = [
            "domain": domain,
            "clips": clipMeta,
            "candidateMoments": candidates,
            "instructions": "Each clip's representative frame is the image at its 'frame' index, in order. Decide each clip's momentType from the frame + filenameSequenceHint + cues, then call tag_moments with the assignments. Use inspect_media on any clip you can't confidently place.",
        ]
        if let ceremonyType { payload["ceremonyType"] = ceremonyType.lowercased() }
        if batch.count < videos.count {
            payload["truncated"] = ["shown": batch.count, "total": videos.count, "note": "Pass mediaRefs or raise maxClips to classify the rest."]
        }

        guard let json = Self.jsonString(payload) else {
            throw ToolError("classify_moments: failed to encode result.")
        }
        return ToolResult(content: imageBlocks + [.text(json)], isError: false)
    }

    // MARK: - tag_moments

    private static let tagMomentsAllowedKeys: Set<String> = ["tags"]
    private static let tagEntryAllowedKeys: Set<String> = ["mediaRef", "momentType", "ceremonyType", "confidence"]

    func tagMoments(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.tagMomentsAllowedKeys, path: "tag_moments")
        guard let rawTags = args["tags"] as? [[String: Any]], !rawTags.isEmpty else {
            throw ToolError("tag_moments: 'tags' must be a non-empty array.")
        }
        let pack = DomainPackStore.load(Self.defaultDomain)

        var applied: [[String: Any]] = []
        for (i, entry) in rawTags.enumerated() {
            try validateUnknownKeys(entry, allowed: Self.tagEntryAllowedKeys, path: "tags[\(i)]")
            let mediaRef = try entry.requireString("mediaRef")
            let momentType = try entry.requireString("momentType")
            if let pack, pack.moment(momentType) == nil {
                throw ToolError("tag_moments: unknown momentType '\(momentType)' in tags[\(i)]. Known: \(pack.momentNames.joined(separator: ", ")).")
            }
            let asset = try asset(mediaRef, editor: editor)
            let tag = MomentTag(
                momentType: momentType,
                ceremonyType: entry.string("ceremonyType"),
                confidence: min(max(entry.double("confidence") ?? 1.0, 0), 1),
                source: "agent"
            )
            asset.momentTag = tag
            if let idx = editor.mediaManifest.entries.firstIndex(where: { $0.id == asset.id }) {
                editor.mediaManifest.entries[idx].momentTag = tag
            }
            applied.append(["mediaRef": asset.id, "momentType": momentType, "confidence": tag.confidence])
        }

        guard let json = Self.jsonString(["tagged": applied.count, "tags": applied]) else {
            throw ToolError("tag_moments: failed to encode result.")
        }
        return .ok(json)
    }

    // MARK: - Helpers

    /// Reports digit groups in a filename so the agent can infer shoot order (e.g. "C0023" -> ["0023"]).
    static func filenameSequenceHint(_ name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        var groups: [String] = []
        var current = ""
        for ch in stem {
            if ch.isNumber { current.append(ch) }
            else if !current.isEmpty { groups.append(current); current = "" }
        }
        if !current.isEmpty { groups.append(current) }
        return groups.isEmpty ? "none" : groups.joined(separator: ",")
    }

    private static func sampleMidpointJPEG(url: URL, duration: Double) async -> Data? {
        await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 384, height: 384)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            let mid = CMTime(seconds: max(duration, 0) / 2, preferredTimescale: 600)
            guard let cg = try? await generator.image(at: mid).image else { return nil }
            return ImageEncoder.encodeJPEG(cg, quality: 0.6)
        }.value
    }
}
