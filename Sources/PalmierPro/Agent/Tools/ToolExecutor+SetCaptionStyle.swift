// set_caption_style tool — the WRITE path for the caption-style profile. Captures a measured project
// policy (filler lists, protected phrases, typography defaults incl. segmentation) into one layer's
// file so it persists and can be reused across projects. Validates against the caption_style read shape,
// then read-modify-writes just that layer, preserving hand-edited keys.

import Foundation

extension ToolExecutor {
    private static let setCaptionStyleAllowedKeys: Set<String> = [
        "scope", "typography", "fillers", "protectedPhrases", "provenance",
    ]

    func setCaptionStyle(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.setCaptionStyleAllowedKeys, path: "set_caption_style")

        let scope = try Self.parseCaptionStyleScope(args.string("scope"))
        guard let url = CaptionStyleStore.url(for: scope, projectPackageURL: editor.projectURL) else {
            throw ToolError(CaptionStyleStore.WriteError.unwritableScope(scope).localizedDescription)
        }

        var provided: [String: Any] = [:]
        if let raw = args["typography"] {
            provided["typography"] = try Self.validatedTypography(raw)
        }
        if let raw = args["fillers"] {
            provided["fillers"] = try Self.validatedFillers(raw)
        }
        if args.keys.contains("protectedPhrases") {
            provided["protectedPhrases"] = try Self.validatedStringList(args["protectedPhrases"], path: "set_caption_style.protectedPhrases")
        }
        if let raw = args["provenance"] {
            provided["provenance"] = try Self.validatedProvenance(raw)
        }
        guard !provided.isEmpty else {
            throw ToolError("set_caption_style: nothing to write. Provide at least one of typography, fillers, protectedPhrases, provenance.")
        }

        let written: [String: Any]
        do {
            written = try CaptionStyleStore.writeLayer(provided, at: url)
        } catch {
            return .error(error.localizedDescription)
        }

        let resolved = CaptionStyleStore.resolve(projectPackageURL: editor.projectURL)
        let payload: [String: Any] = [
            "scope": scope.rawValue,
            "path": url.path,
            "wrote": Array(provided.keys).sorted(),
            "layer": written,
            "resolved": Self.resolvedProfileSummary(resolved.profile),
            "note": "Wrote the \(scope.rawValue) caption-style layer. This is how measured project policy gets captured for reuse — layers still merge global → library → project at read time.",
        ]
        return .ok(Self.jsonString(payload) ?? "{}")
    }

    // MARK: - Scope

    static func parseCaptionStyleScope(_ raw: String?) throws -> CaptionStyleStore.Scope {
        guard let raw else { return .library }
        switch raw {
        case "global": return .global
        case "library": return .library
        case "project": return .project
        default:
            throw ToolError("set_caption_style.scope: expected 'global', 'library', or 'project' (got '\(raw)').")
        }
    }

    // MARK: - Validation (mirrors the caption_style read shape)

    private static func validatedTypography(_ raw: Any) throws -> [String: Any] {
        guard let obj = raw as? [String: Any] else {
            throw ToolError("set_caption_style.typography: expected an object.")
        }
        let allowed: Set<String> = ["fontName", "fontSize", "color", "outline", "shadow", "position", "maxWords", "segmentation", "punctuation"]
        let unknown = Set(obj.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw ToolError("set_caption_style.typography: unknown field(s) '\(unknown.sorted().joined(separator: "', '"))'. Allowed: \(allowed.sorted().joined(separator: ", ")).")
        }
        var out: [String: Any] = [:]
        if let v = obj["fontName"] { out["fontName"] = try requireNonEmptyString(v, path: "set_caption_style.typography.fontName") }
        if let v = obj["color"] { out["color"] = try requireNonEmptyString(v, path: "set_caption_style.typography.color") }
        if let v = obj["fontSize"] { out["fontSize"] = try requireNumber(v, path: "set_caption_style.typography.fontSize", range: 12...300) }
        if let v = obj["outline"] { out["outline"] = try requireBool(v, path: "set_caption_style.typography.outline") }
        if let v = obj["shadow"] { out["shadow"] = try requireBool(v, path: "set_caption_style.typography.shadow") }
        if let v = obj["maxWords"] {
            let n = try requireNumber(v, path: "set_caption_style.typography.maxWords", range: 1...100)
            out["maxWords"] = Int(n)
        }
        if let v = obj["segmentation"] {
            let s = try requireNonEmptyString(v, path: "set_caption_style.typography.segmentation")
            guard CaptionBuilder.Segmentation(rawValue: s) != nil else {
                throw ToolError("set_caption_style.typography.segmentation: expected \(CaptionBuilder.Segmentation.allCases.map(\.rawValue).joined(separator: " or ")) (got '\(s)').")
            }
            out["segmentation"] = s
        }
        if let v = obj["punctuation"] {
            let s = try requireNonEmptyString(v, path: "set_caption_style.typography.punctuation")
            guard CaptionText.PunctuationPolicy(rawValue: s) != nil else {
                throw ToolError("set_caption_style.typography.punctuation: expected stripCJK, strip, or keep (got '\(s)').")
            }
            out["punctuation"] = s
        }
        if let v = obj["position"] {
            guard let p = v as? [String: Any] else {
                throw ToolError("set_caption_style.typography.position: expected an object with x and y.")
            }
            let pUnknown = Set(p.keys).subtracting(["x", "y"])
            guard pUnknown.isEmpty else {
                throw ToolError("set_caption_style.typography.position: unknown field(s) '\(pUnknown.sorted().joined(separator: "', '"))'. Allowed: x, y.")
            }
            let x = try requireNumber(p["x"] as Any, path: "set_caption_style.typography.position.x", range: 0...1)
            let y = try requireNumber(p["y"] as Any, path: "set_caption_style.typography.position.y", range: 0...1)
            out["position"] = ["x": x, "y": y]
        }
        return out
    }

    private static func validatedFillers(_ raw: Any) throws -> [String: Any] {
        guard let obj = raw as? [String: Any] else {
            throw ToolError("set_caption_style.fillers: expected an object.")
        }
        let allowed: Set<String> = ["removeAlways", "neverRemove", "caseByCase", "neverDedupe"]
        let unknown = Set(obj.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw ToolError("set_caption_style.fillers: unknown field(s) '\(unknown.sorted().joined(separator: "', '"))'. Allowed: \(allowed.sorted().joined(separator: ", ")).")
        }
        var out: [String: Any] = [:]
        for key in ["removeAlways", "neverRemove", "caseByCase"] where obj.keys.contains(key) {
            out[key] = try validatedStringList(obj[key], path: "set_caption_style.fillers.\(key)")
        }
        if let dedupe = obj["neverDedupe"] {
            guard let d = dedupe as? [String: Any] else {
                throw ToolError("set_caption_style.fillers.neverDedupe: expected an object.")
            }
            let dUnknown = Set(d.keys).subtracting(["cjkReduplication", "comicRepetition"])
            guard dUnknown.isEmpty else {
                throw ToolError("set_caption_style.fillers.neverDedupe: unknown field(s) '\(dUnknown.sorted().joined(separator: "', '"))'. Allowed: cjkReduplication, comicRepetition.")
            }
            var dOut: [String: Any] = [:]
            if let v = d["cjkReduplication"] { dOut["cjkReduplication"] = try requireBool(v, path: "set_caption_style.fillers.neverDedupe.cjkReduplication") }
            if let v = d["comicRepetition"] { dOut["comicRepetition"] = try requireBool(v, path: "set_caption_style.fillers.neverDedupe.comicRepetition") }
            out["neverDedupe"] = dOut
        }
        return out
    }

    private static func validatedProvenance(_ raw: Any) throws -> [String: Any] {
        guard let obj = raw as? [String: Any] else {
            throw ToolError("set_caption_style.provenance: expected an object of string values.")
        }
        var out: [String: Any] = [:]
        for (k, v) in obj {
            out[k] = try requireNonEmptyString(v, path: "set_caption_style.provenance.\(k)")
        }
        return out
    }

    static func validatedStringList(_ raw: Any?, path: String) throws -> [String] {
        guard let arr = raw as? [Any] else {
            throw ToolError("\(path): expected an array of strings.")
        }
        var out: [String] = []
        for item in arr {
            guard let s = item as? String else {
                throw ToolError("\(path): every element must be a string.")
            }
            out.append(s)
        }
        return out
    }

    private static func requireNonEmptyString(_ raw: Any, path: String) throws -> String {
        guard let s = raw as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError("\(path): expected a non-empty string.")
        }
        return s
    }

    private static func requireBool(_ raw: Any, path: String) throws -> Bool {
        if let b = raw as? Bool { return b }
        if let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        throw ToolError("\(path): expected a boolean.")
    }

    private static func requireNumber(_ raw: Any, path: String, range: ClosedRange<Double>) throws -> Double {
        let value: Double
        if let d = raw as? Double { value = d }
        else if let i = raw as? Int { value = Double(i) }
        else if let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { value = n.doubleValue }
        else { throw ToolError("\(path): expected a number.") }
        guard value.isFinite, range.contains(value) else {
            throw ToolError("\(path): must be between \(Self.trimNumber(range.lowerBound)) and \(Self.trimNumber(range.upperBound)) (got \(Self.trimNumber(value))).")
        }
        return value
    }

    private static func trimNumber(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }

    /// Compact view of the resolved profile so the caller sees what its write produced after layering.
    static func resolvedProfileSummary(_ profile: CaptionStyleProfile) -> [String: Any] {
        var typography: [String: Any] = [:]
        if let v = profile.typography.fontName { typography["fontName"] = v }
        if let v = profile.typography.fontSize { typography["fontSize"] = v }
        if let v = profile.typography.color { typography["color"] = v }
        if let v = profile.typography.outline { typography["outline"] = v }
        if let v = profile.typography.shadow { typography["shadow"] = v }
        if let v = profile.typography.position { typography["position"] = ["x": v.x, "y": v.y] }
        if let v = profile.typography.maxWords { typography["maxWords"] = v }
        if let v = profile.typography.segmentation { typography["segmentation"] = v }
        return [
            "fillers": [
                "removeAlways": profile.fillers.removeAlways,
                "neverRemove": profile.fillers.neverRemove,
                "caseByCase": profile.fillers.caseByCase,
            ],
            "protectedPhrases": profile.protectedPhrases,
            "typography": typography,
            "lintDismissals": profile.lintDismissals,
        ]
    }
}
