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
        let narration: NarrationSource?
    }

    fileprivate struct EditPlanSectionDraft: Decodable {
        let sectionId: String?
        let title: String?
        let summary: String?
        let startFrame: Int?
        let endFrame: Int?
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
        let referenceUse: ReferenceRecipeUse?
        let claimIds: [String]?
        let narrationLink: SceneNarrationLink?
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
        let narration: NarrationSource?
    }

    private static let planObjectKeys: Set<String> = ["planId", "name", "goal", "timelineId", "sections", "shots", "notes", "referenceRecipe", "sourceLedger", "scriptBeats", "narration"]
    private static let planPatchKeys: Set<String> = ["name", "goal", "sections", "shots", "notes", "referenceRecipe", "sourceLedger", "scriptBeats", "narration"]
    private static let sectionObjectKeys: Set<String> = ["sectionId", "title", "summary", "startFrame", "endFrame", "referenceUse", "claimIds", "narrationLink"]
    private static let shotObjectKeys: Set<String> = [
        "shotId", "title", "startFrame", "endFrame", "trackId", "mediaRef",
        "candidateURL", "license", "attribution", "sourceStartSeconds", "sourceEndSeconds", "notes", "referenceUse", "claimIds", "narrationLink",
    ]

    func planEdit(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validatePlanObjects(args)
        let input: PlanEditInput = try decodeToolArgs(args, path: "plan_edit")
        if input.action != "review_claims", input.claimIds != nil || input.ledgerRevision != nil {
            throw ToolError("claimIds and ledgerRevision are only valid for review_claims.")
        }
        switch input.action {
        case "create":
            return try createEditPlan(editor, input: input)
        case "read":
            return try readEditPlans(editor, input: input)
        case "update":
            return try updateEditPlan(editor, input: input)
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
        default:
            throw ToolError("action must be create, read, update, status, delete, review_claims, or measure_narration.")
        }
    }

    func applyPlan(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: ApplyPlanInput = try decodeToolArgs(args, path: "apply_plan")
        guard let planId = input.planId, !planId.isEmpty else {
            throw ToolError("apply_plan requires planId.")
        }
        guard let plan = editor.editPlan(id: planId) else {
            throw ToolError("Unknown planId '\(planId)'.")
        }
        try Task.checkCancellation()
        guard plan.timelineId == editor.activeTimelineId else {
            throw ToolError("Plan '\(plan.id)' belongs to timeline '\(plan.timelineId)'. Switch to that timeline before applying it.")
        }
        if plan.status == .applied {
            return .ok(Self.jsonString(plan.receipt(includeDetails: true).merging(
                ["applied": true, "ready": true, "noOp": true],
                uniquingKeysWith: { _, new in new }
            )) ?? "{}")
        }
        guard plan.status == .approved || plan.status == .ready else {
            throw ToolError("Only an approved or ready plan can be applied. Mark it approved first.")
        }
        try Task.checkCancellation()
        guard plan.fps == editor.timeline.fps,
              plan.width == editor.timeline.width,
              plan.height == editor.timeline.height else {
            throw ToolError("Plan '\(plan.id)' no longer matches the timeline geometry. Revise the plan before applying it.")
        }
        var blockers = readinessBlockers(plan: plan, editor: editor)
        if plan.scriptBeats != nil, blockers.isEmpty {
            do { try await verifyPlanNarration(editor, plan: plan) }
            catch is CancellationError { throw CancellationError() }
            catch { blockers.append((error as? ToolError)?.message ?? error.localizedDescription) }
        }
        let commit = input.commit ?? false
        if commit {
            guard blockers.isEmpty else {
                throw ToolError("Plan '\(plan.id)' is not ready: \(blockers.joined(separator: " "))")
            }
            let entries = try assemblyEntries(plan: plan, editor: editor)
            let clipIDsBefore = Set(editor.timeline.tracks.flatMap(\.clips).map(\.id))
            do {
                try editor.undo.perform("Apply Plan (Agent)") {
                    if plan.status == .approved {
                        _ = try editor.changeEditPlanStatus(
                            id: plan.id, to: .ready,
                            actionName: "Apply Plan (Agent)", permitReserved: true
                        )
                    }
                    let result = try addClips(editor, ["entries": entries])
                    guard !result.isError else {
                        throw ToolError(result.content.compactMap { block in
                            if case .text(let text) = block { return text }
                            return nil
                        }.joined(separator: " "))
                    }
                    _ = try editor.changeEditPlanStatus(
                        id: plan.id, to: .applied,
                        actionName: "Apply Plan (Agent)", permitReserved: true
                    )
                }
                let applied = editor.editPlan(id: plan.id) ?? plan
                let addedClipIDs = editor.timeline.tracks.flatMap(\.clips).map(\.id).filter { !clipIDsBefore.contains($0) }
                return .ok(Self.jsonString(applied.receipt(includeDetails: true).merging(
                    ["applied": true, "ready": true, "noOp": false, "addedClipIds": addedClipIDs],
                    uniquingKeysWith: { _, new in new }
                )) ?? "{}")
            } catch let error as EditPlanValidationError {
                throw ToolError(error.errorDescription ?? "Invalid plan status change.")
            }
        }
        return .ok(Self.jsonString(plan.receipt(includeDetails: true).merging(
            ["applied": false, "ready": blockers.isEmpty, "blockers": blockers, "noOp": true],
            uniquingKeysWith: { _, new in new }
        )) ?? "{}")
    }

    private func createEditPlan(_ editor: EditorViewModel, input: PlanEditInput) throws -> ToolResult {
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
                    narration: draft.narration
                ),
                timelineId: editor.activeTimelineId,
                fps: editor.timeline.fps,
                width: editor.timeline.width,
                height: editor.timeline.height,
                existingCount: editor.editPlans.count
            )
            let receipt = try editor.changeEditPlans(creates: [plan], actionName: "Add Plan (Agent)")
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

    private func updateEditPlan(_ editor: EditorViewModel, input: PlanEditInput) throws -> ToolResult {
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
        try EditPlan.ensureGlobalIDs([candidate])
        guard candidate.name != current.name || candidate.goal != current.goal
                || candidate.notes != current.notes
                || candidate.sections != current.sections
                || candidate.shots != current.shots
                || candidate.referenceRecipe != current.referenceRecipe
                || candidate.sourceLedger != current.sourceLedger
                || candidate.scriptBeats != current.scriptBeats
                || candidate.narration != current.narration else {
            return .ok(Self.jsonString(current.receipt(includeDetails: true).merging(
                ["noOp": true],
                uniquingKeysWith: { _, new in new }
            )) ?? "{}")
        }
        do {
            let receipt = try editor.changeEditPlans(updates: [candidate], actionName: "Change Plan (Agent)")
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
            referenceUse: draft.referenceUse,
            claimIds: draft.claimIds,
            narrationLink: draft.narrationLink
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
        }
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
            try validatePlanValue(narration, allowed: ["mediaRef", "language", "startFrame"], path: "\(path).narration")
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

    private func assemblyEntries(plan: EditPlan, editor: EditorViewModel) throws -> [[String: Any]] {
        let shots = try plan.resolvedShots()
        let allOmitTracks = shots.allSatisfy { $0.trackId == nil }
        var entries = try shots.map { shot in
            guard let mediaRef = shot.mediaRef,
                  let asset = editor.mediaAssetsById[mediaRef] else {
                throw ToolError("Shot '\(shot.id)' has no ready mediaRef.")
            }
            var entry: [String: Any] = ["mediaRef": mediaRef, "startFrame": shot.startFrame]
            if let sourceStart = shot.sourceStartSeconds, let sourceEnd = shot.sourceEndSeconds {
                entry["source"] = [sourceStart, sourceEnd]
            } else {
                entry["endFrame"] = shot.endFrame
            }
            if !allOmitTracks {
                let trackId = shot.trackId ?? editor.timeline.tracks.first(where: { asset.type.isCompatible(with: $0.type) })?.id
                guard let trackId,
                      let trackIndex = editor.timeline.tracks.firstIndex(where: { $0.id == trackId }) else {
                    throw ToolError("Shot '\(shot.id)' has no compatible destination track.")
                }
                entry["trackIndex"] = trackIndex
            }
            return entry
        }
        if let narration = plan.narration, let timing = plan.narrationTiming {
            let duration = try timing.duration.frame(fps: plan.fps, rounding: .roundTowardZero)
            guard duration > 0, narration.startFrame <= maxFrameArg - duration else { throw ToolError("Narration duration exceeds timeline bounds.") }
            var entry: [String: Any] = ["mediaRef": narration.mediaRef, "startFrame": narration.startFrame,
                                        "endFrame": narration.startFrame + duration]
            if !allOmitTracks {
                guard let index = editor.timeline.tracks.firstIndex(where: { $0.type == .audio }) else {
                    throw ToolError("Plan narration requires a compatible audio track when shot tracks are explicit.")
                }
                entry["trackIndex"] = index
            }
            entries.append(entry)
        }
        return entries
    }

    private func readinessBlockers(plan: EditPlan, editor: EditorViewModel) -> [String] {
        var blockers: [String] = []
        for claimId in plan.unresolvedClaimIDs {
            blockers.append("Claim '\(claimId)' is unresolved; review its supporting evidence before assembly.")
        }
        let timeline = editor.timeline
        if plan.scriptBeats != nil, plan.narrationTiming == nil || plan.narrationTiming?.unresolvedBeatIds.isEmpty == false {
            blockers.append("Narration alignment is unresolved; measure the current script and audio before assembly.")
        }
        let shots: [EditPlanShot]
        do {
            shots = try plan.resolvedShots()
            for section in plan.sections {
                if let link = section.narrationLink { _ = try plan.resolvedNarrationRange(link) }
            }
        } catch {
            blockers.append(error.localizedDescription)
            return blockers
        }
        if plan.shots.isEmpty {
            blockers.append("The plan has no shots to validate.")
        }
        let tracks = Set(timeline.tracks.map(\.id))
        for shot in shots {
            try? Task.checkCancellation()
            if let trackId = shot.trackId, !tracks.contains(trackId) {
                blockers.append("Shot '\(shot.id)' names unknown trackId '\(trackId)'.")
            }
            if let mediaRef = shot.mediaRef {
                guard let asset = editor.mediaAssetsById[mediaRef] else {
                    blockers.append("Shot '\(shot.id)' names unknown mediaRef '\(mediaRef)'.")
                    continue
                }
                if editor.missingMediaRefs.contains(mediaRef) || editor.unprocessableMediaRefs.contains(mediaRef) {
                    blockers.append("Shot '\(shot.id)' points at media '\(mediaRef)' that is missing or unreadable.")
                }
                switch asset.generationStatus {
                case .none:
                    break
                case .failed(let message):
                    blockers.append("Shot '\(shot.id)' points at failed media '\(mediaRef)': \(message)")
                default:
                    blockers.append("Shot '\(shot.id)' points at media '\(mediaRef)' that is still \(asset.generationStatus.serialized).")
                }
                if let trackId = shot.trackId,
                   let track = timeline.tracks.first(where: { $0.id == trackId }),
                   !asset.type.isCompatible(with: track.type) {
                    blockers.append("Shot '\(shot.id)' media type '\(asset.type.rawValue)' is incompatible with track '\(trackId)'.")
                }
                if let sourceStart = shot.sourceStartSeconds, let sourceEnd = shot.sourceEndSeconds {
                    if asset.resolvedDuration > 0, sourceEnd > asset.resolvedDuration + 0.001 {
                        blockers.append("Shot '\(shot.id)' selects source audio/video past the end of '\(mediaRef)'.")
                    }
                    let sourceFrames = secondsToFrame(seconds: sourceEnd, fps: timeline.fps)
                        - secondsToFrame(seconds: sourceStart, fps: timeline.fps)
                    if sourceFrames != shot.endFrame - shot.startFrame {
                        blockers.append("Shot '\(shot.id)' source span is \(sourceFrames) frames but its timeline range is \(shot.endFrame - shot.startFrame) frames.")
                    }
                }
            } else if let candidateURL = shot.candidateURL {
                blockers.append("Shot '\(shot.id)' has candidate '\(candidateURL)' that has not been imported yet. Import it with import_media, then attach its mediaRef.")
            } else {
                blockers.append("Shot '\(shot.id)' has no mediaRef and no candidateURL.")
            }
        }
        return blockers
    }
}

private struct ApplyPlanInput: DecodableToolArgs {
    let planId: String?
    let commit: Bool?
    static let allowedKeys: Set<String> = ["planId", "commit"]
}
