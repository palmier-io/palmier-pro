import Foundation

extension ToolExecutor {
    fileprivate struct PlanEditInput: DecodableToolArgs {
        let action: String
        let planId: String?
        let plan: EditPlanDraft?
        let patch: EditPlanPatch?
        let status: String?
        let filterStatus: String?
        let limit: Int?
        let claimIds: [String]?
        let ledgerRevision: String?
        static let allowedKeys: Set<String> = [
            "action", "planId", "plan", "patch", "status", "filterStatus", "limit", "claimIds", "ledgerRevision",
        ]
    }

    fileprivate struct EditPlanDraft: Decodable {
        let planId: String?
        let name: String?
        let goal: String?
        let timelineId: String?
        let sections: [EditPlanSectionDraft]?
        let shots: [EditPlanShotDraft]?
        let notes: String?
        let referenceRecipe: ReferenceRecipe?
        let sourceLedger: SourceClaimLedger?
        let scriptBeats: [ScriptBeat]?
        let narrationIntent: NarrationIntentRequest?
        let narration: NarrationSource?
        let brief: PlanBrief?
        let soundCues: [PlanSoundCue]?
    }

    fileprivate struct EditPlanSectionDraft: Decodable {
        let sectionId: String?
        let title: String?
        let summary: String?
        let startFrame: Int?
        let endFrame: Int?
        let role: String?
        let referenceUse: ReferenceRecipeUse?
        let claimIds: [String]?
        let narrationLink: SceneNarrationLink?
    }

    fileprivate struct EditPlanShotDraft: Decodable {
        let shotId: String?
        let title: String?
        let startFrame: Int?
        let endFrame: Int?
        let trackId: String?
        let mediaRef: String?
        let candidateURL: String?
        let license: String?
        let attribution: String?
        let sourceStartSeconds: Double?
        let sourceEndSeconds: Double?
        let notes: String?
        let requirement: ShotRequirement?
        let rejections: [ShotRejection]?
        let referenceUse: ReferenceRecipeUse?
        let claimIds: [String]?
        let narrationLink: SceneNarrationLink?
        let sourceAudio: PlanSourceAudio?
    }

    fileprivate struct EditPlanPatch: Decodable {
        let name: String?
        let goal: String?
        let sections: [EditPlanSectionDraft]?
        let shots: [EditPlanShotDraft]?
        let notes: String?
        let referenceRecipe: ReferenceRecipe?
        let sourceLedger: SourceClaimLedger?
        let scriptBeats: [ScriptBeat]?
        let narrationIntent: NarrationIntentRequest?
        let narration: NarrationSource?
        let brief: PlanBrief?
        let soundCues: [PlanSoundCue]?
    }

    private static let planObjectKeys: Set<String> = ["planId", "name", "goal", "timelineId", "sections", "shots", "notes", "referenceRecipe", "sourceLedger", "scriptBeats", "narrationIntent", "narration", "brief", "soundCues"]
    private static let planPatchKeys: Set<String> = ["name", "goal", "sections", "shots", "notes", "referenceRecipe", "sourceLedger", "scriptBeats", "narrationIntent", "narration", "brief", "soundCues"]
    private static let sectionObjectKeys: Set<String> = ["sectionId", "title", "summary", "startFrame", "endFrame", "role", "referenceUse", "claimIds", "narrationLink"]
    private static let shotObjectKeys: Set<String> = [
        "shotId", "title", "startFrame", "endFrame", "trackId", "mediaRef",
        "candidateURL", "license", "attribution", "sourceStartSeconds", "sourceEndSeconds", "notes", "requirement", "rejections", "referenceUse", "claimIds", "narrationLink", "sourceAudio",
    ]

    func planEdit(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        if let action = args["action"] as? String, Self.storyboardActions.contains(action) {
            return try await storyboardEdit(editor, args)
        }
        try validatePlanObjects(args)
        let input: PlanEditInput = try decodeToolArgs(args, path: "plan_edit")
        if input.action != "review_claims", input.claimIds != nil || input.ledgerRevision != nil {
            throw ToolError("claimIds and ledgerRevision are only valid for review_claims.")
        }
        switch input.action {
        case "create":
            return try await createEditPlan(editor, input: input)
        case "read":
            return try readEditPlans(editor, input: input)
        case "update":
            return try await updateEditPlan(editor, input: input)
        case "status":
            return try changePlanStatus(editor, input: input)
        case "delete":
            return try deleteEditPlan(editor, input: input)
        case "review_claims":
            try rejectPlanEditKeys(input, forbidden: ["plan", "patch", "status", "filterStatus", "limit"], path: "plan_edit action='review_claims'")
            guard let planId = input.planId, let ids = input.claimIds, let revision = input.ledgerRevision else {
                throw ToolError("review_claims requires planId, claimIds, and ledgerRevision from the reviewed plan receipt.")
            }
            let result = try editor.reviewEditPlanClaims(id: planId, claimIds: ids, ledgerRevision: revision)
            guard let plan = editor.editPlan(id: planId) else { throw ToolError("Unknown planId '\(planId)'.") }
            return .ok(Self.jsonString(plan.receipt(includeDetails: true).merging(
                ["noOp": result.updated.isEmpty], uniquingKeysWith: { _, new in new }
            )) ?? "{}")
        case "measure_narration":
            try rejectPlanEditKeys(input, forbidden: ["plan", "patch", "status", "filterStatus", "limit"], path: "plan_edit action='measure_narration'")
            guard let planId = input.planId else { throw ToolError("measure_narration requires planId.") }
            return try await measurePlanNarration(editor, planId: planId)
        case "prepare_narration":
            try rejectPlanEditKeys(input, forbidden: ["plan", "patch", "status", "filterStatus", "limit", "claimIds"], path: "plan_edit action='prepare_narration'")
            guard let planId = input.planId else { throw ToolError("prepare_narration requires planId.") }
            return try await prepareApprovedPlanNarration(editor, planId: planId)
        default:
            throw ToolError("action must be create, read, update, status, delete, review_claims, measure_narration, or prepare_narration.")
        }
    }

    func applyPlan(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: ApplyPlanInput = try decodeToolArgs(args, path: "apply_plan")
        guard let planId = input.planId, !planId.isEmpty else {
            throw ToolError("apply_plan requires planId.")
        }
        let commit = input.commit ?? false
        guard commit || input.preparationId == nil else {
            throw ToolError("preparationId is only valid with commit:true.")
        }
        let request = PlanAssembly.Request(shotIds: input.shotIds, replaceManualEdits: input.replaceManualEdits ?? false)
        do {
            let prepared: EditorViewModel.PreparedPlanAssembly
            if let id = input.preparationId {
                prepared = try editor.preparedAssembly(id: id, planId: planId, request: request)
            } else {
                prepared = try await editor.preparePlanAssembly(planId: planId, request: request, prepare: planAssemblyPreparing)
            }
            try Task.checkCancellation()
            guard self.editor === editor else { throw ToolError("Project binding changed during plan preparation.") }
            if commit {
                let result = try await editor.commitPlanAssembly(prepared)
                return .ok(Self.jsonString(result.receipt) ?? "{}")
            }
            var receipt = prepared.preparation.input.plan.receipt(includeDetails: true)
            receipt.merge(["applied": false, "ready": prepared.preparation.blockers.isEmpty,
                           "blockers": prepared.preparation.blockers, "noOp": true], uniquingKeysWith: { _, new in new })
            if let resolved = prepared.preparation.resolved {
                receipt.merge(resolved.previewReceipt, uniquingKeysWith: { _, new in new })
                receipt["preparationId"] = prepared.id
            }
            return .ok(Self.jsonString(receipt) ?? "{}")
        } catch let error as EditPlanValidationError {
            throw ToolError(error.errorDescription ?? "Invalid plan assembly.")
        }
    }

    private func createEditPlan(_ editor: EditorViewModel, input: PlanEditInput) async throws -> ToolResult {
        try rejectPlanEditKeys(input, forbidden: ["planId", "patch", "status", "filterStatus", "limit"], path: "plan_edit action='create'")
        guard let draft = input.plan else { throw ToolError("plan_edit action='create' requires plan.") }
        do {
            let plan = try EditPlan.validatedNew(
                EditPlan(
                    id: draft.planId ?? UUID().uuidString,
                    name: draft.name ?? "",
                    goal: draft.goal ?? "",
                    timelineId: draft.timelineId ?? editor.activeTimelineId,
                    fps: editor.timeline.fps,
                    width: editor.timeline.width,
                    height: editor.timeline.height,
                    sections: try (draft.sections ?? []).map { try Self.planSection($0) },
                    shots: try (draft.shots ?? []).map { try Self.planShot($0) },
                    notes: draft.notes ?? "",
                    referenceRecipe: draft.referenceRecipe,
                    sourceLedger: draft.sourceLedger,
                    scriptBeats: draft.scriptBeats,
                    narrationIntent: draft.narrationIntent.map { NarrationIntent(language: $0.language, startFrame: $0.startFrame) },
                    narration: draft.narration,
                    brief: draft.brief,
                    soundCues: draft.soundCues
                ),
                timelineId: editor.activeTimelineId,
                fps: editor.timeline.fps,
                width: editor.timeline.width,
                height: editor.timeline.height,
                existingCount: editor.editPlans.count
            )
            let prepared = try await editor.preparePlanNarrationChange(plan, intentRequest: draft.narrationIntent)
            guard self.editor === editor else { throw ToolError("Project binding changed during narration preparation.") }
            let receipt = try editor.changeEditPlans(creates: [prepared.plan], actionName: "Add Plan (Agent)",
                                                     narrationValidation: prepared.validation)
            guard let created = receipt.created.first else { throw ToolError("Plan creation produced no change.") }
            return .ok(Self.jsonString(created.receipt(includeDetails: true)) ?? "{}")
        } catch let error as EditPlanValidationError {
            throw ToolError(error.errorDescription ?? "Invalid plan.")
        }
    }

    private func readEditPlans(_ editor: EditorViewModel, input: PlanEditInput) throws -> ToolResult {
        try rejectPlanEditKeys(input, forbidden: ["plan", "patch", "status"], path: "plan_edit action='read'")
        let limit = try validatedPlanLimit(input.limit)
        let filter = try validatedPlanFilterStatus(input.filterStatus)
        if let planId = input.planId {
            guard let plan = editor.editPlan(id: planId) else {
                throw ToolError("Unknown planId '\(planId)'.")
            }
            if let filter, plan.status != filter {
                return .ok(Self.jsonString(["planId": plan.id, "status": plan.status.rawValue, "matchesFilter": false]) ?? "{}")
            }
            return .ok(Self.jsonString(plan.receipt(includeDetails: true)) ?? "{}")
        }
        let filtered: [EditPlan]
        if let filter {
            filtered = editor.editPlans.filter { $0.status == filter }
        } else {
            filtered = editor.editPlans
        }
        let selected = Array(filtered.prefix(limit))
        let truncated = filtered.count > selected.count
        return .ok(Self.jsonString([
            "count": selected.count,
            "total": filtered.count,
            "truncated": truncated,
            "plans": selected.map { $0.receipt(includeDetails: false) },
        ]) ?? "{}")
    }

    private func updateEditPlan(_ editor: EditorViewModel, input: PlanEditInput) async throws -> ToolResult {
        try rejectPlanEditKeys(input, forbidden: ["plan", "status", "filterStatus", "limit"], path: "plan_edit action='update'")
        guard let planId = input.planId, !planId.isEmpty else {
            throw ToolError("plan_edit action='update' requires planId.")
        }
        guard let current = editor.editPlan(id: planId) else {
            throw ToolError("Unknown planId '\(planId)'.")
        }
        guard let patch = input.patch else {
            throw ToolError("plan_edit action='update' requires patch.")
        }
        guard current.status == .proposed || current.status == .approved else {
            throw ToolError("Only proposed or approved plans can be updated. Create a new plan instead.")
        }
        var candidate = current
        if let name = patch.name { candidate.name = name }
        if let goal = patch.goal { candidate.goal = goal }
        if let notes = patch.notes { candidate.notes = notes }
        if let recipe = patch.referenceRecipe { candidate.referenceRecipe = recipe }
        if let ledger = patch.sourceLedger { candidate.sourceLedger = ledger }
        if let beats = patch.scriptBeats { candidate.scriptBeats = beats }
        if let narration = patch.narration { candidate.narration = narration }
        if let brief = patch.brief { candidate.brief = brief }
        if let cues = patch.soundCues { candidate.soundCues = cues }
        if let sections = patch.sections {
            candidate.sections = try sections.enumerated().map { index, draft in
                try Self.planSection(draft, path: "patch.sections[\(index)]")
            }
        }
        if let shots = patch.shots {
            candidate.shots = try shots.enumerated().map { index, draft in
                try Self.planShot(draft, path: "patch.shots[\(index)]")
            }
        }
        var narrationValidation: PlanNarrationChangeValidation?
        if patch.narrationIntent != nil || patch.narration != nil {
            let prepared = try await editor.preparePlanNarrationChange(candidate, intentRequest: patch.narrationIntent)
            guard self.editor === editor else { throw ToolError("Project binding changed during narration preparation.") }
            candidate = prepared.plan
            narrationValidation = prepared.validation
        }
        try EditPlan.ensureGlobalIDs([candidate])
        guard candidate.name != current.name || candidate.goal != current.goal
                || candidate.notes != current.notes
                || candidate.sections != current.sections
                || candidate.shots != current.shots
                || candidate.referenceRecipe != current.referenceRecipe
                || candidate.sourceLedger != current.sourceLedger
                || candidate.scriptBeats != current.scriptBeats
                || candidate.narrationIntent != current.narrationIntent
                || candidate.narration != current.narration
                || candidate.brief != current.brief
                || candidate.soundCues != current.soundCues else {
            return .ok(Self.jsonString(current.receipt(includeDetails: true).merging(
                ["noOp": true],
                uniquingKeysWith: { _, new in new }
            )) ?? "{}")
        }
        do {
            let receipt = try editor.changeEditPlans(updates: [candidate], actionName: "Change Plan (Agent)",
                                                     narrationValidation: narrationValidation)
            guard let updated = receipt.updated.first else {
                return .ok(Self.jsonString(current.receipt(includeDetails: true).merging(
                    ["noOp": true], uniquingKeysWith: { _, new in new }
                )) ?? "{}")
            }
            let oldReviewed = Set((current.sourceLedger?.claims ?? []).filter { $0.status == .reviewed }.map(\.claimId))
            let invalidated = (updated.sourceLedger?.claims ?? []).filter { oldReviewed.contains($0.claimId) && $0.status == .unresolved }.map(\.claimId)
            return .ok(Self.jsonString(updated.receipt(includeDetails: true).merging(
                ["invalidatedClaimIds": invalidated, "claimDependents": updated.claimDependents(Set(invalidated))],
                uniquingKeysWith: { _, new in new }
            )) ?? "{}")
        } catch let error as EditPlanValidationError {
            throw ToolError(error.errorDescription ?? "Invalid plan update.")
        }
    }

    private func changePlanStatus(_ editor: EditorViewModel, input: PlanEditInput) throws -> ToolResult {
        try rejectPlanEditKeys(input, forbidden: ["plan", "patch", "filterStatus", "limit"], path: "plan_edit action='status'")
        guard let planId = input.planId, !planId.isEmpty else {
            throw ToolError("plan_edit action='status' requires planId.")
        }
        guard let rawStatus = input.status, let status = EditPlanStatus(rawValue: rawStatus) else {
            throw ToolError("status must be proposed, approved, ready, applied, or superseded.")
        }
        do {
            let before = try editor.editPlan(id: planId).map(\.status)
            let plan = try editor.changeEditPlanStatus(
                id: planId, to: status,
                actionName: "Change Plan Status (Agent)", permitReserved: false
            )
            return .ok(Self.jsonString(plan.receipt(includeDetails: true).merging(
                ["noOp": before == plan.status],
                uniquingKeysWith: { _, new in new }
            )) ?? "{}")
        } catch let error as EditPlanValidationError {
            throw ToolError(error.errorDescription ?? "Invalid plan status change.")
        }
    }

    private func deleteEditPlan(_ editor: EditorViewModel, input: PlanEditInput) throws -> ToolResult {
        try rejectPlanEditKeys(input, forbidden: ["plan", "patch", "status", "filterStatus", "limit"], path: "plan_edit action='delete'")
        guard let planId = input.planId, !planId.isEmpty else {
            throw ToolError("plan_edit action='delete' requires planId.")
        }
        do {
            let receipt = try editor.changeEditPlans(deleteIds: [planId], actionName: "Delete Plan (Agent)")
            guard receipt.deletedIds == [planId] else { throw ToolError("Plan deletion produced no change.") }
            return .ok(Self.jsonString(["deletedPlanId": planId]) ?? "{}")
        } catch let error as EditPlanValidationError {
            throw ToolError(error.errorDescription ?? "Invalid plan deletion.")
        }
    }

    private func rejectPlanEditKeys(_ input: PlanEditInput, forbidden: [String], path: String) throws {
        var present: [String] = []
        if input.planId != nil, forbidden.contains("planId") { present.append("planId") }
        if input.plan != nil, forbidden.contains("plan") { present.append("plan") }
        if input.patch != nil, forbidden.contains("patch") { present.append("patch") }
        if input.status != nil, forbidden.contains("status") { present.append("status") }
        if input.filterStatus != nil, forbidden.contains("filterStatus") { present.append("filterStatus") }
        if input.limit != nil, forbidden.contains("limit") { present.append("limit") }
        guard present.isEmpty else {
            throw ToolError("\(path) does not accept \(present.sorted().joined(separator: ", ")).")
        }
    }

    private func validatedPlanLimit(_ limit: Int?) throws -> Int {
        let value = limit ?? 20
        guard (1...100).contains(value) else {
            throw ToolError("limit must be 1–100 (got \(value)).")
        }
        return value
    }

    private func validatedPlanFilterStatus(_ rawValue: String?) throws -> EditPlanStatus? {
        guard let rawValue else { return nil }
        guard let status = EditPlanStatus(rawValue: rawValue) else {
            throw ToolError("filterStatus must be proposed, approved, ready, applied, or superseded.")
        }
        return status
    }

    private nonisolated static func planSection(_ draft: EditPlanSectionDraft, path: String = "plan.sections") throws -> EditPlanSection {
        guard let title = draft.title else { throw ToolError("\(path) requires title.") }
        guard let start = draft.startFrame, let end = draft.endFrame else {
            throw ToolError("\(path) requires startFrame and endFrame.")
        }
        return EditPlanSection(
            id: draft.sectionId ?? UUID().uuidString,
            title: title,
            summary: draft.summary ?? "",
            startFrame: start,
            endFrame: end,
            role: draft.role.flatMap(SectionRole.init(rawValue:)),
            referenceUse: draft.referenceUse,
            claimIds: draft.claimIds,
            narrationLink: draft.narrationLink
        )
    }

    private nonisolated static func planShot(_ draft: EditPlanShotDraft, path: String = "plan.shots") throws -> EditPlanShot {
        guard let title = draft.title else { throw ToolError("\(path) requires title.") }
        guard let start = draft.startFrame, let end = draft.endFrame else {
            throw ToolError("\(path) requires startFrame and endFrame.")
        }
        return EditPlanShot(
            id: draft.shotId ?? UUID().uuidString,
            title: title,
            startFrame: start,
            endFrame: end,
            trackId: draft.trackId,
            mediaRef: draft.mediaRef,
            candidateURL: draft.candidateURL,
            license: draft.license,
            attribution: draft.attribution,
            sourceStartSeconds: draft.sourceStartSeconds,
            sourceEndSeconds: draft.sourceEndSeconds,
            notes: draft.notes ?? "",
            requirement: draft.requirement,
            rejections: draft.rejections ?? [],
            referenceUse: draft.referenceUse,
            claimIds: draft.claimIds,
            narrationLink: draft.narrationLink,
            sourceAudio: draft.sourceAudio
        )
    }

    private func validatePlanObjects(_ args: [String: Any]) throws {
        try validateUnknownKeys(args, allowed: PlanEditInput.allowedKeys, path: "plan_edit")
        if let plan = args["plan"] as? [String: Any] {
            try validatePlanValue(plan, allowed: Self.planObjectKeys, path: "plan")
            if let sections = plan["sections"] {
                try validatePlanArray(sections, allowed: Self.sectionObjectKeys, singular: "section", path: "plan.sections")
            }
            if let shots = plan["shots"] {
                try validatePlanArray(shots, allowed: Self.shotObjectKeys, singular: "shot", path: "plan.shots")
            }
            try validatePlanBrief(plan["brief"], path: "plan.brief")
            try validatePlanSoundCues(plan["soundCues"], path: "plan.soundCues")
            try validateReferenceRecipe(plan["referenceRecipe"], path: "plan.referenceRecipe")
            try validateSourceLedger(plan["sourceLedger"], path: "plan.sourceLedger")
            try validateNarrationObjects(plan, path: "plan")
        }
        if let patch = args["patch"] as? [String: Any] {
            try validatePlanValue(patch, allowed: Self.planPatchKeys, path: "patch")
            if let sections = patch["sections"] {
                try validatePlanArray(sections, allowed: Self.sectionObjectKeys, singular: "section", path: "patch.sections")
            }
            if let shots = patch["shots"] {
                try validatePlanArray(shots, allowed: Self.shotObjectKeys, singular: "shot", path: "patch.shots")
            }
            try validatePlanBrief(patch["brief"], path: "patch.brief")
            try validatePlanSoundCues(patch["soundCues"], path: "patch.soundCues")
            try validateReferenceRecipe(patch["referenceRecipe"], path: "patch.referenceRecipe")
            try validateSourceLedger(patch["sourceLedger"], path: "patch.sourceLedger")
            try validateNarrationObjects(patch, path: "patch")
        }
    }

    private func validatePlanValue(_ value: Any, allowed: Set<String>, path: String) throws {
        guard let object = value as? [String: Any] else {
            throw ToolError("\(path) must be an object.")
        }
        try validateUnknownKeys(object, allowed: allowed, path: path)
    }

    private func validatePlanArray(_ value: Any, allowed: Set<String>, singular: String, path: String) throws {
        guard let items = value as? [Any] else {
            throw ToolError("\(path) must be an array of \(singular) objects.")
        }
        for (index, item) in items.enumerated() {
            try validatePlanValue(item, allowed: allowed, path: "\(path)[\(index)]")
            if let use = (item as? [String: Any])?["referenceUse"] {
                try validatePlanValue(use, allowed: ["cueIds", "rationale"], path: "\(path)[\(index)].referenceUse")
            }
            if let link = (item as? [String: Any])?["narrationLink"] {
                try validatePlanValue(link, allowed: ["firstBeatId", "lastBeatId", "minimumHoldSeconds"], path: "\(path)[\(index)].narrationLink")
            }
            if let requirement = (item as? [String: Any])?["requirement"],
               singular == "shot" {
                try validatePlanValue(requirement, allowed: ["narrativePurpose", "subject", "action", "location", "shotSize", "motion", "sourceTypes", "exclusions", "targetDurationSeconds", "handleSeconds"], path: "\(path)[\(index)].requirement")
            }
            if singular == "shot", let rejections = (item as? [String: Any])?["rejections"] {
                try validatePlanRejections(rejections, path: "\(path)[\(index)].rejections")
            }
        }
    }

    private func validatePlanRejections(_ value: Any, path: String) throws {
        guard let items = value as? [Any] else {
            throw ToolError("\(path) must be an array of shot rejection objects.")
        }
        for (index, item) in items.enumerated() {
            try validatePlanValue(item, allowed: ["candidateRef", "reason", "evidence"], path: "\(path)[\(index)]")
        }
    }

    private func validatePlanBrief(_ value: Any?, path: String) throws {
        guard let value else { return }
        try validatePlanValue(value, allowed: ["audience", "durationSeconds", "aspectFormat", "tone", "language", "realism", "deliveryConstraints", "deliveryTarget", "inferredChoices"], path: path)
        if let target = (value as? [String: Any])?["deliveryTarget"] {
            try validatePlanValue(target, allowed: ["integratedLUFS", "truePeakDBTP", "toleranceLU"], path: "\(path).deliveryTarget")
        }
    }

    private func validatePlanSoundCues(_ value: Any?, path: String) throws {
        guard let value else { return }
        try validatePlanArray(value, allowed: ["cueId", "role", "purpose", "anchorBeatId", "anchorFrame", "durationSeconds", "notes", "mediaRef", "trackId"], singular: "sound cue", path: path)
    }

    private func validateReferenceRecipe(_ value: Any?, path: String) throws {
        guard let value else { return }
        try validatePlanValue(value, allowed: ["title", "sourceURL", "sourceDurationSeconds", "coverage", "cues", "limitations"], path: path)
        if let cues = (value as? [String: Any])?["cues"] {
            try validatePlanArray(cues, allowed: ["cueId", "kind", "evidence", "startSeconds", "endSeconds", "observation", "editorialRule"], singular: "cue", path: "\(path).cues")
        }
    }

    private func validateNarrationObjects(_ object: [String: Any], path: String) throws {
        if let beats = object["scriptBeats"] {
            try validatePlanArray(beats, allowed: ["beatId", "text", "spokenText", "purpose", "claimIds"], singular: "beat", path: "\(path).scriptBeats")
        }
        if let narration = object["narration"] {
            try validatePlanValue(narration, allowed: ["mediaRef"], path: "\(path).narration")
        }
        if let intent = object["narrationIntent"] {
            try validatePlanValue(intent, allowed: ["language", "startFrame", "narrator"], path: "\(path).narrationIntent")
            if let narrator = (intent as? [String: Any])?["narrator"] {
                try validatePlanValue(narrator, allowed: ["kind", "mediaRef", "engine", "voiceIdentifier", "rate", "pitch"],
                                      path: "\(path).narrationIntent.narrator")
            }
        }
    }

    private func validateSourceLedger(_ value: Any?, path: String) throws {
        guard let value else { return }
        try validatePlanValue(value, allowed: ["sources", "claims"], path: path)
        if let sources = (value as? [String: Any])?["sources"] {
            try validatePlanArray(sources, allowed: ["sourceId", "title", "url", "documentReference", "author", "publicationDate", "accessedDate"], singular: "source", path: "\(path).sources")
        }
        if let claims = (value as? [String: Any])?["claims"] as? [Any] {
            for (index, claim) in claims.enumerated() {
                let claimPath = "\(path).claims[\(index)]"
                try validatePlanValue(claim, allowed: ["claimId", "kind", "statement", "value", "unit", "evidence", "status"], path: claimPath)
                if let evidence = (claim as? [String: Any])?["evidence"] {
                    try validatePlanArray(evidence, allowed: ["sourceId", "passage"], singular: "evidence", path: "\(claimPath).evidence")
                }
            }
        }
    }

}

private struct ApplyPlanInput: DecodableToolArgs {
    let planId: String?
    let commit: Bool?
    let preparationId: String?
    let shotIds: [String]?
    let replaceManualEdits: Bool?
    static let allowedKeys: Set<String> = ["planId", "commit", "preparationId", "shotIds", "replaceManualEdits"]
}
