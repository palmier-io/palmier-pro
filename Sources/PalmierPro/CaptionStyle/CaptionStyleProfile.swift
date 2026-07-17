// Reusable caption-style profile: measured filler policy + typography defaults, persisted per project/library/global.
// The resolved profile records where JUDGEMENT is required (caseByCase) rather than pretending to automate it.

import Foundation

/// Fully resolved caption-style profile after all layers merge. Typography fields stay optional
/// (nil = keep the app's caption default); filler lists resolve to concrete arrays.
struct CaptionStyleProfile: Codable, Equatable, Sendable {
    var version: Int
    var fillers: Fillers
    var protectedPhrases: [String]
    var typography: Typography
    var provenance: [String: String]

    struct Fillers: Codable, Equatable, Sendable {
        /// Safe to strip mechanically.
        var removeAlways: [String]
        /// Never strip even though generic rules would.
        var neverRemove: [String]
        /// NEVER auto-remove — surface for agent/human judgement.
        var caseByCase: [String]
        var neverDedupe: NeverDedupe
    }

    struct NeverDedupe: Codable, Equatable, Sendable {
        /// Repeated CJK tokens are grammar (存存钱/试试看), not stutters.
        var cjkReduplication: Bool
        /// Deliberate repetition (太酷了×3) is comic timing.
        var comicRepetition: Bool
    }

    /// nil field = keep the caption generator's own default for that attribute.
    struct Typography: Codable, Equatable, Sendable {
        var fontName: String? = nil
        var fontSize: Double? = nil
        var color: String? = nil
        var outline: Bool? = nil
        var shadow: Bool? = nil
        var position: Position? = nil
        var maxWords: Int? = nil
    }

    /// Normalized 0–1 caption box center.
    struct Position: Codable, Equatable, Sendable {
        var x: Double
        var y: Double
    }

    /// Shipped starting policy. Measured profiles layer on top and override wholesale per provided key.
    static let builtInDefault = CaptionStyleProfile(
        version: 1,
        fillers: Fillers(
            removeAlways: ["呃", "哎", "um", "uh", "er", "ah"],
            neverRemove: ["然后", "oh", "so", "right", "basically"],
            caseByCase: ["啊", "哦", "嗯", "那个", "这个", "like", "就是", "you know"],
            neverDedupe: NeverDedupe(cjkReduplication: true, comicRepetition: true)
        ),
        protectedPhrases: [],
        typography: Typography(),
        provenance: [:]
    )
}

/// A single layer's contribution before merge. Every field is optional so "absent" (inherit) is
/// distinguishable from "provided" (replace). Decoded tolerantly — unknown keys and type
/// mismatches are ignored rather than throwing.
struct CaptionStyleProfilePartial: Equatable {
    var version: Int?
    var removeAlways: [String]?
    var neverRemove: [String]?
    var caseByCase: [String]?
    var cjkReduplication: Bool?
    var comicRepetition: Bool?
    var protectedPhrases: [String]?
    var typography: CaptionStyleProfile.Typography?
    var provenance: [String: String]?

    /// Later layer's provided keys replace earlier wholesale; absent keys inherit.
    /// Typography merges per individual key; provenance unions (later wins).
    func overlaid(by o: CaptionStyleProfilePartial) -> CaptionStyleProfilePartial {
        var r = self
        if let v = o.version { r.version = v }
        if let x = o.removeAlways { r.removeAlways = x }
        if let x = o.neverRemove { r.neverRemove = x }
        if let x = o.caseByCase { r.caseByCase = x }
        if let x = o.cjkReduplication { r.cjkReduplication = x }
        if let x = o.comicRepetition { r.comicRepetition = x }
        if let x = o.protectedPhrases { r.protectedPhrases = x }
        r.typography = Self.overlayTypography(base: r.typography, over: o.typography)
        if let x = o.provenance { r.provenance = (r.provenance ?? [:]).merging(x) { _, new in new } }
        return r
    }

    private static func overlayTypography(
        base: CaptionStyleProfile.Typography?,
        over: CaptionStyleProfile.Typography?
    ) -> CaptionStyleProfile.Typography? {
        guard let over else { return base }
        guard let base else { return over }
        return CaptionStyleProfile.Typography(
            fontName: over.fontName ?? base.fontName,
            fontSize: over.fontSize ?? base.fontSize,
            color: over.color ?? base.color,
            outline: over.outline ?? base.outline,
            shadow: over.shadow ?? base.shadow,
            position: over.position ?? base.position,
            maxWords: over.maxWords ?? base.maxWords
        )
    }

    func resolved() -> CaptionStyleProfile {
        CaptionStyleProfile(
            version: version ?? 1,
            fillers: CaptionStyleProfile.Fillers(
                removeAlways: removeAlways ?? [],
                neverRemove: neverRemove ?? [],
                caseByCase: caseByCase ?? [],
                neverDedupe: CaptionStyleProfile.NeverDedupe(
                    cjkReduplication: cjkReduplication ?? true,
                    comicRepetition: comicRepetition ?? true
                )
            ),
            protectedPhrases: protectedPhrases ?? [],
            typography: typography ?? CaptionStyleProfile.Typography(),
            provenance: provenance ?? [:]
        )
    }

    /// Seed a partial from a concrete profile so the built-in default can be the base of the overlay chain.
    init(from profile: CaptionStyleProfile) {
        version = profile.version
        removeAlways = profile.fillers.removeAlways
        neverRemove = profile.fillers.neverRemove
        caseByCase = profile.fillers.caseByCase
        cjkReduplication = profile.fillers.neverDedupe.cjkReduplication
        comicRepetition = profile.fillers.neverDedupe.comicRepetition
        protectedPhrases = profile.protectedPhrases
        typography = profile.typography
        provenance = profile.provenance
    }

    init() {}

    /// Tolerant decode from a parsed JSON object. Missing sections/keys stay nil; wrong types are ignored.
    init(jsonObject obj: [String: Any]) {
        version = obj.csInt("version")
        if let fillers = obj["fillers"] as? [String: Any] {
            removeAlways = fillers.csStringArrayIfPresent("removeAlways")
            neverRemove = fillers.csStringArrayIfPresent("neverRemove")
            caseByCase = fillers.csStringArrayIfPresent("caseByCase")
            if let dedupe = fillers["neverDedupe"] as? [String: Any] {
                cjkReduplication = dedupe.csBool("cjkReduplication")
                comicRepetition = dedupe.csBool("comicRepetition")
            }
        }
        protectedPhrases = obj.csStringArrayIfPresent("protectedPhrases")
        if let typo = obj["typography"] as? [String: Any] {
            var position: CaptionStyleProfile.Position?
            if let p = typo["position"] as? [String: Any], let x = p.csDouble("x"), let y = p.csDouble("y") {
                position = CaptionStyleProfile.Position(x: x, y: y)
            }
            typography = CaptionStyleProfile.Typography(
                fontName: typo.csString("fontName"),
                fontSize: typo.csDouble("fontSize"),
                color: typo.csString("color"),
                outline: typo.csBool("outline"),
                shadow: typo.csBool("shadow"),
                position: position,
                maxWords: typo.csInt("maxWords")
            )
        }
        if let prov = obj["provenance"] as? [String: Any] {
            provenance = prov.compactMapValues { $0 as? String }
        }
    }
}

// Tolerant accessors — return nil when absent or the wrong type, distinguishing absent from empty.
private extension Dictionary where Key == String, Value == Any {
    func csString(_ key: String) -> String? {
        guard let v = self[key] as? String, !v.isEmpty else { return nil }
        return v
    }
    func csInt(_ key: String) -> Int? {
        if let v = self[key] as? Int { return v }
        if let v = self[key] as? NSNumber { return v.intValue }
        return nil
    }
    func csDouble(_ key: String) -> Double? {
        if let v = self[key] as? Double { return v }
        if let v = self[key] as? Int { return Double(v) }
        if let v = self[key] as? NSNumber { return v.doubleValue }
        return nil
    }
    func csBool(_ key: String) -> Bool? {
        if let v = self[key] as? Bool { return v }
        if let v = self[key] as? NSNumber { return v.boolValue }
        return nil
    }
    func csStringArrayIfPresent(_ key: String) -> [String]? {
        guard let raw = self[key] else { return nil }
        guard let arr = raw as? [Any] else { return nil }
        return arr.compactMap { $0 as? String }
    }
}
