import CryptoKit
import Foundation

struct StoryboardCard: Sendable {
    var shot: EditPlanShot
    var narration: String
    var purpose: String
    var claimIds: [String]
    var selectionRevision: String
    var inputId: String?
    var sourceId: String?
    var mediaType: ClipType?
    var blockers: [String]
    var review: ProductionRun.VisualReview?
    var resolvedRange: Range<Int>?
    var beats: [ScriptBeat]

    var receipt: [String: Any] {
        var row: [String: Any] = ["sceneId": shot.id, "title": shot.title, "narration": narration,
                                  "purpose": purpose, "claimIds": claimIds, "startFrame": shot.startFrame,
                                  "endFrame": shot.endFrame, "timing": resolvedRange == nil ? "estimated" : "measured",
                                  "selectionRevision": selectionRevision, "blockers": blockers,
                                  "previewCoverage": "not_checked"]
        row["scriptBeats"] = beats.map { $0.receipt() }
        if let mediaRef = shot.mediaRef { row["mediaRef"] = mediaRef }
        if let resolvedRange {
            row["resolvedTiming"] = ["startFrame": resolvedRange.lowerBound, "endFrame": resolvedRange.upperBound]
        }
        if let inputId { row["inputId"] = inputId }
        if let sourceId { row["sourceId"] = sourceId }
        if let review {
            row["inspection"] = ["coverage": review.coverage.rawValue, "reviewer": review.reviewer,
                                  "evidence": review.evidence, "facesRevealed": review.facesRevealed,
                                  "rightsConfirmed": review.rightsConfirmed, "suspectedDuplicate": review.suspectedDuplicate] as [String: Any]
        }
        if let url = shot.candidateURL { row["candidateURL"] = url }
        if let license = shot.license { row["license"] = license }
        if let attribution = shot.attribution { row["attribution"] = attribution }
        if let start = shot.sourceStartSeconds, let end = shot.sourceEndSeconds {
            row["sourceSpan"] = [start, end]
        }
        return row
    }
}

struct StoryboardReport: Sendable {
    var planId: String
    var revision: String
    var phase: ProductionRun.Phase
    var cards: [StoryboardCard]
    var blockers: [String]
    var uniqueness: VisualUniquenessReport

    var canProduce: Bool { phase == .approved && blockers.isEmpty }

    var receipt: [String: Any] {
        ["planId": planId, "storyboardRevision": revision, "phase": phase.rawValue,
         "canProduce": canProduce, "blockers": blockers, "cards": cards.map(\.receipt),
         "visualIdentity": uniqueness.receipt, "deliveryVerified": false]
    }
}

enum StoryboardResolver {
    private struct Content: Encodable {
        var planId: String
        var timelineId: String
        var fps: Int
        var width: Int
        var height: Int
        var goal: String
        var notes: String
        var sections: [EditPlanSection]
        var shots: [EditPlanShot]
        var script: [ScriptBeat]
        var ledger: SourceClaimLedger?
        var recipe: ReferenceRecipe?
        var language: String?
        var narrationStartFrame: Int?
        var selections: [String]
    }

    private struct Selection: Encodable {
        var mediaRef: String?
        var candidateURL: String?
        var startSeconds: Double?
        var endSeconds: Double?
        var durationFrames: Int
        var license: String?
        var attribution: String?
        var inputId: String?
        var origin: MediaImportOrigin?
        var type: ClipType?
        var duration: Double?
        var width: Int?
        var height: Int?
        var derivative: Bool
    }

    @concurrent
    static func resolve(plan: EditPlan, manifest: MediaManifest, unavailable: Set<String> = []) async throws -> StoryboardReport {
        try Task.checkCancellation()
        try EditPlan.validatedGeometry(fps: plan.fps, width: plan.width, height: plan.height)
        var entries: [String: MediaManifestEntry] = [:]
        for entry in manifest.entries {
            guard entries.updateValue(entry, forKey: entry.id) == nil else {
                throw EditPlanValidationError.duplicateId(entry.id)
            }
        }
        let beats = plan.scriptBeats ?? []
        guard Set(beats.map(\.beatId)).count == beats.count else { throw EditPlanValidationError.invalidReference("Duplicate script beat IDs.") }
        let indices = Dictionary(uniqueKeysWithValues: beats.enumerated().map { ($0.element.beatId, $0.offset) })
        var cards: [StoryboardCard] = []
        var occurrences: [VisualOccurrence] = []
        for shot in plan.shots {
            try Task.checkCancellation()
            _ = try EditPlan.validatedShot(shot)
            let entry = shot.mediaRef.flatMap { entries[$0] }
            let derivative = entry?.generationInput != nil || entry?.type == .lottie
            let selection = Selection(mediaRef: shot.mediaRef, candidateURL: shot.candidateURL,
                                      startSeconds: shot.sourceStartSeconds, endSeconds: shot.sourceEndSeconds,
                                      durationFrames: shot.endFrame - shot.startFrame, license: shot.license,
                                      attribution: shot.attribution, inputId: entry?.inputIdentity?.inputId,
                                      origin: entry?.importInput?.origin, type: entry?.type,
                                      duration: entry?.duration, width: entry?.sourceWidth,
                                      height: entry?.sourceHeight, derivative: derivative)
            let selectionRevision = try digest(selection)
            var blockers: [String] = []
            if entry == nil { blockers.append("missing_selected_media") }
            if let entry {
                if unavailable.contains(entry.id) || entry.generationStatus != nil { blockers.append("media_not_ready") }
                if entry.inputIdentity?.isValid != true { blockers.append("unresolved_input_identity") }
                if ![ClipType.image, .video, .lottie].contains(entry.type) { blockers.append("unsupported_storyboard_visual") }
                if derivative { blockers.append("unresolved_derivative_lineage") }
                if entry.type != .image {
                    if !entry.duration.isFinite || entry.duration <= 0 { blockers.append("unresolved_source_duration") }
                    let end = shot.sourceEndSeconds ?? Double(shot.endFrame - shot.startFrame) / Double(plan.fps)
                    if end > entry.duration { blockers.append("source_span_out_of_bounds") }
                }
                occurrences.append(VisualOccurrence(mediaRef: entry.id, clipIds: [shot.id],
                    lane: [plan.timelineId, shot.trackId ?? "storyboard"], startFrame: shot.startFrame, endFrame: shot.endFrame,
                    sourceStart: shot.sourceStartSeconds ?? 0,
                    sourceEnd: shot.sourceEndSeconds ?? Double(shot.endFrame - shot.startFrame) / Double(plan.fps),
                    isImage: entry.type == .image))
            }
            if shot.license?.isEmpty != false || shot.attribution?.isEmpty != false { blockers.append("unresolved_rights") }
            let review = plan.productionRun?.visualReviews.first { $0.sceneId == shot.id && $0.selectionRevision == selectionRevision }
            if let review {
                if review.facesRevealed { blockers.append("revealed_faces") }
                if !review.rightsConfirmed { blockers.append("unresolved_rights_review") }
                if review.suspectedDuplicate { blockers.append("suspected_duplicate") }
                let expected: ProductionRun.VisualReview.Coverage = entry?.type == .image ? .fullStill : .fullSpan
                if review.coverage != expected { blockers.append("incomplete_visual_inspection") }
            } else {
                blockers.append("unresolved_face_and_similarity_inspection")
            }
            var linked: [ScriptBeat] = []
            var resolvedRange: Range<Int>?
            if let link = shot.narrationLink, let first = indices[link.firstBeatId], let last = indices[link.lastBeatId], first <= last {
                linked = Array(beats[first...last])
                if plan.narrationTiming != nil {
                    do { resolvedRange = try plan.resolvedNarrationRange(link) }
                    catch { blockers.append("narration_timing_unresolved") }
                }
            } else { blockers.append("missing_scene_narration_link") }
            let claims = Set((shot.claimIds ?? []) + linked.flatMap { $0.claimIds ?? [] }).sorted()
            cards.append(StoryboardCard(shot: shot, narration: linked.map(\.narrationText).joined(separator: "\n\n"),
                purpose: linked.map(\.purpose).joined(separator: "\n"), claimIds: claims,
                selectionRevision: selectionRevision, inputId: entry?.inputIdentity?.inputId,
                sourceId: entry?.importInput?.origin?.sourceId, mediaType: entry?.type, blockers: blockers,
                review: review, resolvedRange: resolvedRange, beats: linked))
        }
        let content = Content(planId: plan.id, timelineId: plan.timelineId, fps: plan.fps, width: plan.width,
                              height: plan.height, goal: plan.goal, notes: plan.notes, sections: plan.sections,
                              shots: plan.shots, script: beats, ledger: plan.sourceLedger, recipe: plan.referenceRecipe,
                              language: plan.narration?.language, narrationStartFrame: plan.narration?.startFrame,
                              selections: cards.map(\.selectionRevision))
        let revision = try digest(content)
        let uniqueness = try await VisualUniqueness.audit(occurrences: occurrences, manifest: manifest)
        var blockers = cards.flatMap { card in card.blockers.map { "\(card.shot.id):\($0)" } }
        if cards.isEmpty { blockers.append("empty_storyboard") }
        if beats.isEmpty { blockers.append("missing_script") }
        blockers += plan.unresolvedClaimIDs.map { "unresolved_claim:\($0)" }
        if !uniqueness.conflicts.isEmpty { blockers.append("repeated_visual_sources") }
        if !uniqueness.unresolved.isEmpty { blockers.append("unresolved_visual_identity") }
        let run = plan.productionRun
        let phase: ProductionRun.Phase = run.map {
            $0.phase == .canceled ? .canceled : ($0.storyboardRevision == revision ? $0.phase : .stale)
        } ?? .awaitingStoryboardApproval
        try Task.checkCancellation()
        return StoryboardReport(planId: plan.id, revision: revision, phase: phase, cards: cards,
                                blockers: blockers, uniqueness: uniqueness)
    }

    private static func digest(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
}
