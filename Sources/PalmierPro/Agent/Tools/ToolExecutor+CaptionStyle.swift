// caption_style tool — returns the resolved caption-style profile, its provenance, and the layer
// origins that produced it, so agents can read the measured filler policy and decide caseByCase themselves.

import Foundation

extension ToolExecutor {
    func captionStyle(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: [], path: "caption_style")
        let resolved = CaptionStyleStore.resolve(projectPackageURL: editor.projectURL)
        guard let json = Self.jsonString(Self.captionStylePayload(resolved)) else {
            return .error("caption_style: could not serialize the resolved profile.")
        }
        return .ok(json)
    }

    private static func captionStylePayload(_ resolved: CaptionStyleStore.Resolved) -> [String: Any] {
        let profile = resolved.profile

        var typography: [String: Any] = [:]
        if let v = profile.typography.fontName { typography["fontName"] = v }
        if let v = profile.typography.fontSize { typography["fontSize"] = v }
        if let v = profile.typography.color { typography["color"] = v }
        if let v = profile.typography.outline { typography["outline"] = v }
        if let v = profile.typography.shadow { typography["shadow"] = v }
        if let v = profile.typography.position { typography["position"] = ["x": v.x, "y": v.y] }
        if let v = profile.typography.maxWords { typography["maxWords"] = v }

        var payload: [String: Any] = [
            "version": profile.version,
            "fillers": [
                "removeAlways": profile.fillers.removeAlways,
                "neverRemove": profile.fillers.neverRemove,
                "caseByCase": profile.fillers.caseByCase,
                "neverDedupe": [
                    "cjkReduplication": profile.fillers.neverDedupe.cjkReduplication,
                    "comicRepetition": profile.fillers.neverDedupe.comicRepetition,
                ],
            ],
            "protectedPhrases": profile.protectedPhrases,
            "typography": typography,
            "provenance": profile.provenance,
            "layers": resolved.origins.map { origin in
                ["scope": origin.scope.rawValue, "path": origin.path, "status": origin.status.rawValue]
            },
            "semantics": [
                "removeAlways": "Safe to strip mechanically.",
                "neverRemove": "Never strip even though generic rules would.",
                "caseByCase": "NEVER auto-remove — stop and surface for judgement; decide per occurrence via update_text/remove_words.",
                "neverDedupe": "Repeated CJK tokens and deliberate comic repetition are not stutters — never dedupe them.",
                "protectedPhrases": "Never touched by any filler or dedup pass.",
            ],
        ]
        if !resolved.warnings.isEmpty { payload["warnings"] = resolved.warnings }
        return payload
    }
}
