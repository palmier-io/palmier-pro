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
    var inspectionRange: Range<Int>?
    var playbackRange: Range<Int>?
    var fps: Int

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
        if let inspectionRange {
            row["inspectionSourceSpan"] = [Double(inspectionRange.lowerBound) / Double(fps), Double(inspectionRange.upperBound) / Double(fps)]
        }
        if let playbackRange {
            row["playbackSourceFrames"] = [playbackRange.lowerBound, playbackRange.upperBound]
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
    var approvalBlockers: [String]
    var narrationIntent: NarrationIntent?
    var uniqueness: VisualUniquenessReport
    var approvedRevision: String?

    var canApprove: Bool { approvalBlockers.isEmpty }
    var canProduce: Bool { phase == .approved && approvedRevision == revision && blockers.isEmpty }

    var receipt: [String: Any] {
        var row: [String: Any] = ["planId": planId, "storyboardRevision": revision, "phase": phase.rawValue,
         "canApprove": canApprove, "canProduce": canProduce, "approvalBlockers": approvalBlockers,
         "blockers": blockers, "cards": cards.map(\.receipt), "visualIdentity": uniqueness.receipt, "deliveryVerified": false]
        if let narrationIntent { row["narrationIntent"] = narrationIntent.receipt }
        return row
    }
}

enum StoryboardResolver {
    private struct Content: Encodable {
        var intent: StoryboardIntent
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
        var inspectionFrames: [Int]?
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
        var approvalBlockers: [String] = []
        var occurrences: [VisualOccurrence] = []
        for shot in plan.shots {
            try Task.checkCancellation()
            _ = try EditPlan.validatedShot(shot)
            let entry = shot.mediaRef.flatMap { entries[$0] }
            let derivative = entry?.generationInput != nil || entry?.type == .lottie
            var blockers: [String] = []
            var derivedBlockers = Set<String>()
            var linked: [ScriptBeat] = []
            var resolvedRange: Range<Int>?
            if let link = shot.narrationLink, let first = indices[link.firstBeatId], let last = indices[link.lastBeatId], first <= last {
                linked = Array(beats[first...last])
                if plan.narrationTiming != nil {
                    do { resolvedRange = try plan.resolvedNarrationRange(link) }
                    catch {
                        blockers.append("narration_timing_unresolved")
                        derivedBlockers.insert("narration_timing_unresolved")
                    }
                }
            } else { blockers.append("missing_scene_narration_link") }
            var playbackShot = shot
            if let resolvedRange {
                playbackShot.startFrame = resolvedRange.lowerBound
                playbackShot.endFrame = resolvedRange.upperBound
            }
            var inspectionRange: Range<Int>?
            var playbackRange: Range<Int>?
            if let entry {
                do {
                    inspectionRange = try PlanSourceRange.inspection(shot: shot, fps: plan.fps, type: entry.type, duration: entry.duration)
                } catch let error as PlanSourceRangeError { blockers.append(error.blocker) }
                do {
                    playbackRange = try PlanSourceRange.playback(shot: shot, fps: plan.fps, type: entry.type, duration: entry.duration)
                } catch let error as PlanSourceRangeError { blockers.append(error.blocker) }
                if resolvedRange != nil {
                    do {
                        playbackRange = try PlanSourceRange.playback(shot: playbackShot, fps: plan.fps, type: entry.type, duration: entry.duration)
                    } catch let error as PlanSourceRangeError {
                        playbackRange = nil
                        if !blockers.contains(error.blocker) { derivedBlockers.insert(error.blocker) }
                        blockers.append(error.blocker)
                    }
                }
            }
            let selection = Selection(mediaRef: shot.mediaRef, candidateURL: shot.candidateURL,
                                      startSeconds: shot.sourceStartSeconds, endSeconds: shot.sourceEndSeconds,
                                      durationFrames: shot.endFrame - shot.startFrame, license: shot.license,
                                      attribution: shot.attribution, inputId: entry?.inputIdentity?.inputId,
                                      origin: entry?.importInput?.origin, type: entry?.type,
                                      duration: entry?.duration, width: entry?.sourceWidth,
                                       height: entry?.sourceHeight, derivative: derivative,
                                       inspectionFrames: inspectionRange.map { [$0.lowerBound, $0.upperBound] })
            let selectionRevision = try digest(selection)
            if entry == nil { blockers.append("missing_selected_media") }
            if let entry {
                if unavailable.contains(entry.id) || entry.generationStatus != nil { blockers.append("media_not_ready") }
                if entry.inputIdentity?.isValid != true { blockers.append("unresolved_input_identity") }
                if ![ClipType.image, .video, .lottie].contains(entry.type) { blockers.append("unsupported_storyboard_visual") }
                if derivative { blockers.append("unresolved_derivative_lineage") }
                occurrences.append(VisualOccurrence(mediaRef: entry.id, clipIds: [shot.id],
                    lane: [plan.timelineId, shot.trackId ?? "storyboard"], startFrame: playbackShot.startFrame, endFrame: playbackShot.endFrame,
                    sourceStart: Double(playbackRange?.lowerBound ?? 0),
                    sourceEnd: Double(playbackRange?.upperBound ?? 0),
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
            let claims = Set((shot.claimIds ?? []) + linked.flatMap { $0.claimIds ?? [] }).sorted()
            approvalBlockers += blockers.filter { !derivedBlockers.contains($0) }.map { "\(shot.id):\($0)" }
            cards.append(StoryboardCard(shot: shot, narration: linked.map(\.narrationText).joined(separator: "\n\n"),
                purpose: linked.map(\.purpose).joined(separator: "\n"), claimIds: claims,
                selectionRevision: selectionRevision, inputId: entry?.inputIdentity?.inputId,
                sourceId: entry?.importInput?.origin?.sourceId, mediaType: entry?.type, blockers: blockers,
                review: review, resolvedRange: resolvedRange, beats: linked,
                inspectionRange: inspectionRange, playbackRange: playbackRange, fps: plan.fps))
        }
        let content = Content(intent: plan.storyboardIntent, selections: cards.map(\.selectionRevision))
        let revision = try digest(content)
        let uniqueness = try await VisualUniqueness.audit(occurrences: occurrences, manifest: manifest)
        var blockers = cards.flatMap { card in card.blockers.map { "\(card.shot.id):\($0)" } }
        if cards.isEmpty { approvalBlockers.append("empty_storyboard") }
        if beats.isEmpty { approvalBlockers.append("missing_script") }
        approvalBlockers += plan.unresolvedClaimIDs.map { "unresolved_claim:\($0)" }
        if !uniqueness.conflicts.isEmpty { approvalBlockers.append("repeated_visual_sources") }
        if !uniqueness.unresolved.isEmpty { approvalBlockers.append("unresolved_visual_identity") }
        if let intent = plan.narrationIntent {
            do { try await intent.verifyAvailableNarrator() }
            catch is CancellationError { throw CancellationError() }
            catch { approvalBlockers.append("unavailable_narrator_intent") }
            if case .recording(let recording) = intent.narrator,
               entries[recording.mediaRef]?.inputIdentity != recording.identity
                || unavailable.contains(recording.mediaRef) || entries[recording.mediaRef]?.generationStatus != nil
                || entries[recording.mediaRef]?.type != .audio {
                approvalBlockers.append("unavailable_recording_narrator")
            }
        } else { approvalBlockers.append("missing_narration_intent") }
        for blocker in approvalBlockers where !blockers.contains(blocker) { blockers.append(blocker) }
        blockers += plan.narrationProductionBlockers(entries: entries, unavailable: unavailable)
        let run = plan.productionRun
        let phase: ProductionRun.Phase = run.map {
            $0.phase == .canceled ? .canceled : ($0.storyboardRevision == revision ? $0.phase : .stale)
        } ?? .awaitingStoryboardApproval
        try Task.checkCancellation()
        return StoryboardReport(planId: plan.id, revision: revision, phase: phase, cards: cards,
                                blockers: blockers, approvalBlockers: approvalBlockers, narrationIntent: plan.narrationIntent,
                                uniqueness: uniqueness, approvedRevision: run?.approvedRevision)
    }

    private static func digest(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
}
