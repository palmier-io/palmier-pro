import Foundation

struct ReferenceRecipe: Codable, Sendable, Equatable {
    enum Coverage: String, Codable, Sendable, CaseIterable {
        case captions, stills, motion, audio
    }

    struct Cue: Codable, Sendable, Equatable {
        enum Kind: String, Codable, Sendable, CaseIterable {
            case narrativeArc, sceneFamily, typography, geography, evidenceTreatment, pacing, motion, audio
        }

        enum Evidence: String, Codable, Sendable, CaseIterable {
            case observed, inferred, unverified
        }

        var cueId: String
        var kind: Kind
        var evidence: Evidence
        var startSeconds: Double?
        var endSeconds: Double?
        var observation: String
        var editorialRule: String
    }

    var title: String
    var sourceURL: String
    var sourceDurationSeconds: Double?
    var coverage: [Coverage]
    var cues: [Cue]
    var limitations: String

    func validated() throws -> Self {
        var recipe = self
        recipe.title = try EditPlan.validatedName(title)
        recipe.sourceURL = try EditPlan.validatedURL(sourceURL)
        recipe.limitations = try EditPlan.validatedText(limitations, field: "reference limitations")
        guard !recipe.limitations.isEmpty else {
            throw EditPlanValidationError.invalidReference("Reference limitations must state what inspection cannot verify.")
        }
        if let duration = sourceDurationSeconds, !duration.isFinite || duration <= 0 {
            throw EditPlanValidationError.invalidReference("Reference sourceDurationSeconds must be finite and positive.")
        }
        guard !coverage.isEmpty, Set(coverage).count == coverage.count else {
            throw EditPlanValidationError.invalidReference("Reference coverage must be non-empty and unique.")
        }
        guard (1...128).contains(cues.count) else {
            throw EditPlanValidationError.invalidReference("A reference recipe requires 1–128 cues.")
        }
        var ids = Set<String>()
        recipe.cues = try cues.map { original in
            var cue = original
            cue.cueId = try EditPlan.validatedID(cue.cueId, field: "cueId")
            guard ids.insert(cue.cueId).inserted else { throw EditPlanValidationError.duplicateId(cue.cueId) }
            cue.observation = try EditPlan.validatedText(cue.observation, field: "reference observation")
            cue.editorialRule = try EditPlan.validatedText(cue.editorialRule, field: "reference editorialRule")
            guard !cue.observation.isEmpty, !cue.editorialRule.isEmpty else {
                throw EditPlanValidationError.invalidReference("Reference cues need an observation and transferable editorialRule.")
            }
            switch (cue.startSeconds, cue.endSeconds) {
            case (.none, .none):
                guard cue.evidence != .observed else {
                    throw EditPlanValidationError.invalidReference("Observed reference cues require a source timestamp range.")
                }
            case let (.some(start), .some(end)):
                guard start.isFinite, end.isFinite, start >= 0, end > start,
                      sourceDurationSeconds.map({ end <= $0 }) ?? true else {
                    throw EditPlanValidationError.invalidReference("Reference cue timestamps must be finite, ordered, and inside the source duration.")
                }
            default:
                throw EditPlanValidationError.invalidReference("Reference cues require both startSeconds and endSeconds.")
            }
            if cue.evidence == .observed {
                if cue.kind == .motion, !coverage.contains(.motion) {
                    throw EditPlanValidationError.invalidReference("Observed motion requires motion inspection coverage, not captions or stills.")
                }
                if cue.kind == .audio, !coverage.contains(.audio) {
                    throw EditPlanValidationError.invalidReference("Observed audio requires audio inspection coverage, not captions or stills.")
                }
            }
            return cue
        }
        return recipe
    }

    func receipt() -> [String: Any] {
        var result: [String: Any] = [
            "title": title, "sourceURL": sourceURL,
            "coverage": coverage.map(\.rawValue), "limitations": limitations,
            "cues": cues.map { cue in
                var row: [String: Any] = [
                    "cueId": cue.cueId, "kind": cue.kind.rawValue, "evidence": cue.evidence.rawValue,
                    "observation": cue.observation, "editorialRule": cue.editorialRule,
                ]
                if let start = cue.startSeconds { row["startSeconds"] = start }
                if let end = cue.endSeconds { row["endSeconds"] = end }
                return row
            },
        ]
        if let sourceDurationSeconds { result["sourceDurationSeconds"] = sourceDurationSeconds }
        return result
    }
}

struct ReferenceRecipeUse: Codable, Sendable, Equatable {
    var cueIds: [String]
    var rationale: String

    func validated(recipe: ReferenceRecipe?) throws -> Self {
        guard let recipe else {
            throw EditPlanValidationError.invalidReference("referenceUse requires the plan's referenceRecipe.")
        }
        var use = self
        guard !cueIds.isEmpty, cueIds.count <= recipe.cues.count else {
            throw EditPlanValidationError.invalidReference("referenceUse must cite at least one recipe cue.")
        }
        use.cueIds = try cueIds.map { try EditPlan.validatedID($0, field: "referenceUse.cueIds") }
        let known = Set(recipe.cues.map(\.cueId))
        guard Set(use.cueIds).count == use.cueIds.count, use.cueIds.allSatisfy(known.contains) else {
            throw EditPlanValidationError.invalidReference("referenceUse contains duplicate or unknown cueIds.")
        }
        use.rationale = try EditPlan.validatedText(rationale, field: "reference rationale")
        guard !use.rationale.isEmpty else {
            throw EditPlanValidationError.invalidReference("referenceUse requires the chapter or scene's editorial rationale.")
        }
        return use
    }

    func receipt() -> [String: Any] {
        ["cueIds": cueIds, "rationale": rationale]
    }
}
