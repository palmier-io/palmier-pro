import AVFoundation
import Foundation

/// Drives one persisted production run to a terminal result.
///
/// The run's state lives on the plan (`ProductionRun`), so this driver holds no
/// duplicate state: it reads the persisted run, performs only the next eligible
/// step, and commits that step's receipt. A reopened project resumes the same
/// run instead of starting a new one, and a step whose key already carries a
/// terminal receipt is never run twice.
@MainActor
final class ProductionCoordinator {
    typealias Phase = ProductionRun.Phase

    private weak var editor: EditorViewModel?
    private var running: [String: Task<Void, Never>] = [:]

    init() {}

    func attach(to editor: EditorViewModel) {
        self.editor = editor
        editor.onMediaReady = { [weak self] in self?.mediaBecameReady() }
    }

    // MARK: - Inspection

    func status(planId: String) -> ProductionStatus {
        guard let editor, let plan = editor.editPlan(id: planId) else {
            return ProductionStatus(planId: planId, phase: .canceled, runId: nil, storyboardRevision: nil,
                                    approvedRevision: nil, reviewedSceneCount: 0, totalScenes: 0, comment: "",
                                    steps: [], reviewFindings: [], verifiedTimelineRevision: nil,
                                    exportedTimelineRevision: nil, exportJobId: nil, exportPath: nil,
                                    terminalReceipt: nil, blockedReason: "Plan not found")
        }
        let run = plan.productionRun
        return ProductionStatus(
            planId: planId,
            phase: run?.phase ?? .awaitingStoryboardApproval,
            runId: run?.id,
            storyboardRevision: run?.storyboardRevision,
            approvedRevision: run?.approvedRevision,
            reviewedSceneCount: run?.visualReviews.count ?? 0,
            totalScenes: plan.shots.count,
            comment: run?.comment ?? "",
            steps: run?.steps ?? [],
            reviewFindings: run?.reviewFindings ?? [],
            verifiedTimelineRevision: run?.verifiedTimelineRevision,
            exportedTimelineRevision: run?.exportedTimelineRevision,
            exportJobId: run?.exportJobId,
            exportPath: run?.exportPath,
            terminalReceipt: run?.terminalReceipt,
            blockedReason: run?.blockedReason
        )
    }

    // MARK: - Lifecycle

    /// Continues an approved production run.
    func produce(planId: String) async throws -> ProductionStatus {
        guard let editor, let plan = editor.editPlan(id: planId) else { throw ProductionError.planNotFound }
        guard plan.status == .proposed || plan.status == .approved else {
            throw ProductionError.invalidPlanStatus("Plan must be proposed or approved to start production.")
        }
        guard let run = plan.productionRun else {
            throw ProductionError.approvalBlocked(
                "Prepare and approve the storyboard before production: prepare_storyboard, review each scene, then approve_storyboard.")
        }
        guard run.approvedRevision != nil else {
            throw ProductionError.approvalBlocked("The current storyboard is not approved.")
        }
        return try await resume(planId: planId)
    }

    /// Continues the run from its persisted step ledger.
    func resume(planId: String) async throws -> ProductionStatus {
        guard let editor, let plan = editor.editPlan(id: planId) else { throw ProductionError.planNotFound }
        guard let run = plan.productionRun else { throw ProductionError.missingProductionRun }
        guard run.phase != .canceled else { throw ProductionError.productionCanceled }
        guard run.approvedRevision != nil else {
            throw ProductionError.approvalBlocked("The current storyboard is not approved.")
        }
        guard !editor.projectPackageCoordinator.isClosing else {
            throw ProductionError.notReady("The project is closing.")
        }
        try await execute(planId: planId)
        return status(planId: planId)
    }

    /// Stops the run. A canceled run never edits the timeline again.
    func cancel(planId: String) throws {
        running[planId]?.cancel()
        running[planId] = nil
        guard let editor else { throw ProductionError.editorNotAvailable }
        try editor.cancelProductionReview(planId: planId)
    }

    /// Stops every in-flight run. Closing or replacing a project must not leave
    /// background work editing its timeline.
    func cancelAll() {
        for task in running.values { task.cancel() }
        running.removeAll()
    }

    /// Media the run needs became available; a run waiting on footage continues.
    func mediaBecameReady() {
        guard let editor else { return }
        for plan in editor.editPlans {
            guard let run = plan.productionRun, run.phase == .blocked,
                  run.blockedReason?.hasPrefix("Waiting for media") == true else { continue }
            let planId = plan.id
            guard running[planId] == nil else { continue }
            running[planId] = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await self.resume(planId: planId)
                self.running[planId] = nil
            }
        }
    }

    /// Awaits the automatic resumes started by a media event.
    func awaitPendingResumes() async {
        for task in running.values { await task.value }
    }

    // MARK: - Steps

    private func execute(planId: String) async throws {
        // A blocked step stops the run: the next step waits for its dependency
        // instead of running on incomplete work. A resumed run re-enters here,
        // and each step's idempotency key skips the work it already finished.
        guard try await runAssemblyStep(planId: planId) else { return }
        guard try await runMixStep(planId: planId) else { return }
        try await runReviewStep(planId: planId)
        try await runExportStep(planId: planId)
    }

    private func runAssemblyStep(planId: String) async throws -> Bool {
        guard let editor, let plan = editor.editPlan(id: planId), plan.productionRun != nil else {
            throw ProductionError.missingProductionRun
        }
        try Task.checkCancellation()
        let key = "assemble:" + (try ProductionRevision.assemblyInputs(plan))
        if let step = editor.editPlan(id: planId)?.productionRun?.step(for: .assemble),
           step.state == .completed, step.key == key {
            // A completed assembly still resumes when newly-ready media arrives:
            // assemble any shots whose footage just became available.
            let pending = Self.pendingMedia(editor: editor, plan: plan)
            if pending.isEmpty { return true }
        }
        let pending = Self.pendingMedia(editor: editor, plan: plan)
        let readyShotIds = plan.shots.compactMap { shot -> String? in
            guard let ref = shot.mediaRef,
                  let asset = editor.mediaAssetsById[ref],
                  asset.generationStatus == .none else { return nil }
            return shot.id
        }
        // Media that is actively being imported/generated: wait for its terminal result
        // instead of assembling incomplete bytes.
        if !pending.isEmpty {
            let reason = "Waiting for media: \(pending.joined(separator: ", "))."
            try updateRun(planId: planId) { run in
                run.phase = .blocked
                run.blockedReason = reason
                run.record(.init(kind: .assemble, state: .pending, key: key, error: reason))
            }
            return false
        }
        // No ready shots and nothing arriving: let preparation report the missing/unknown
        // media as a validation blocker rather than a generic wait.
        if readyShotIds.isEmpty {
            try updateRun(planId: planId) { run in
                run.phase = .assembling
                run.blockedReason = nil
            }
        }
        try updateRun(planId: planId) { run in
            run.phase = .assembling
            run.blockedReason = nil
        }
        // Assemble only the shots whose media is ready, so each video/image lands on
        // the timeline as soon as it is retrieved instead of waiting for every item.
        let prepared: EditorViewModel.PreparedPlanAssembly
        do {
            prepared = try await editor.preparePlanAssembly(
                planId: planId,
                request: .init(shotIds: readyShotIds)
            )
        } catch let error as EditPlanValidationError {
            let reason = error.errorDescription ?? "The plan cannot be assembled."
            try updateRun(planId: planId) { run in
                run.phase = .blocked
                run.blockedReason = reason
                run.record(.init(kind: .assemble, state: .failed, key: key, error: reason))
            }
            return false
        }
        guard prepared.preparation.blockers.isEmpty else {
            let reason = prepared.preparation.blockers.joined(separator: " ")
            let findings = prepared.preparation.blockers.map {
                ProductionRun.Finding(severity: .error, kind: "assemblyBlocked", message: $0,
                                      fix: "apply_plan", source: .structural)
            }
            try persistFindings(planId: planId, findings: findings, source: .structural, digest: nil)
            try updateRun(planId: planId) { run in
                run.phase = .blocked
                run.blockedReason = reason
                run.record(.init(kind: .assemble, state: .failed, key: key, error: reason))
            }
            return false
        }
        let receipt = try await editor.commitPlanAssembly(prepared)
        let digest = receipt.resolved.state.revision
        let stillPending = Self.pendingMedia(editor: editor, plan: plan)
        try updateRun(planId: planId) { run in
            run.record(.init(kind: .assemble, state: stillPending.isEmpty ? .completed : .pending, key: key,
                             outputDigest: digest,
                             completedAt: stillPending.isEmpty ? Date() : nil))
            if stillPending.isEmpty {
                run.phase = .assembling
                run.blockedReason = nil
            } else {
                run.phase = .blocked
                run.blockedReason = "Waiting for media: \(stillPending.joined(separator: ", "))."
            }
        }
        return stillPending.isEmpty
    }

    /// Sources the plan needs that are still being prepared.
    private static func pendingMedia(editor: EditorViewModel, plan: EditPlan) -> [String] {
        var refs: [String] = []
        for ref in plan.shots.compactMap(\.mediaRef) + (plan.soundCues ?? []).compactMap(\.mediaRef) {
            guard !refs.contains(ref) else { continue }
            if let asset = editor.mediaAssetsById[ref], asset.generationStatus != .none {
                refs.append(ref)
            }
        }
        return refs
    }

    private func runMixStep(planId: String) async throws -> Bool {
        guard let editor, let plan = editor.editPlan(id: planId) else { throw ProductionError.planNotFound }
        let audible = editor.timeline.tracks.filter { $0.type == .audio && !$0.muted }.flatMap(\.clips)
        guard !audible.isEmpty else {
            try updateRun(planId: planId) { run in
                run.record(.init(kind: .mix, state: .skipped, key: "mix:none",
                                 error: "No audible clips to mix.", completedAt: Date()))
            }
            return true
        }
        if editor.timeline.audioMix != nil {
            try updateRun(planId: planId) { run in
                run.record(.init(kind: .mix, state: .skipped, key: "mix:existing",
                                 outputDigest: editor.timeline.audioMix?.outputRevision, completedAt: Date()))
            }
            return true
        }
        let roles = Self.roles(for: audible, plan: plan)
        guard roles.unmapped.isEmpty else {
            let reason = "Audio clips \(roles.unmapped.joined(separator: ", ")) have no declared role."
            try updateRun(planId: planId) { run in
                run.phase = .blocked
                run.blockedReason = reason
                run.record(.init(kind: .mix, state: .failed, key: "mix:undeclaredRoles",
                                 error: reason, completedAt: Date()))
            }
            return false
        }
        let target = plan.brief?.deliveryTarget ?? AudioDeliveryTarget(integratedLUFS: -16, truePeakDBTP: -1)
        let key = "mix:" + (try ProductionRevision.digest(MixInputs(
            roles: roles.assignments.map { "\($0.clipId):\($0.role.rawValue)" },
            target: target.integratedLUFS, peak: target.truePeakDBTP, tolerance: target.toleranceLU)))
        if let step = editor.editPlan(id: planId)?.productionRun?.step(for: .mix),
           step.state == .completed, step.key == key {
            return true
        }
        do {
            let receipt = try await editor.mixAudio(request: .init(
                roles: roles.assignments, target: target, ducking: .default,
                bedFadeFrames: max(1, editor.timeline.fps / 2)))
            try updateRun(planId: planId) { run in
                run.record(.init(kind: .mix, state: receipt.changed ? .completed : .skipped,
                                 key: key, outputDigest: receipt.state.outputRevision, completedAt: Date()))
            }
        } catch {
            let message = (error as? AudioFinishingError)?.reason ?? error.localizedDescription
            try updateRun(planId: planId) { run in
                run.phase = .blocked
                run.blockedReason = "Mixing failed: \(message)"
                run.record(.init(kind: .mix, state: .failed, key: key, error: message, completedAt: Date()))
            }
            return false
        }
        return true
    }

    private struct MixInputs: Encodable {
        let roles: [String]
        let target: Double
        let peak: Double
        let tolerance: Double
    }

    /// Audio roles come from the plan's declared cues and narration, never from
    /// clip names. A clip without a declared role is reported, never guessed.
    private static func roles(for clips: [Clip], plan: EditPlan) -> (assignments: [AudioRoleAssignment], unmapped: [String]) {
        var byRef: [String: AudioRole] = [:]
        if let narration = plan.narration { byRef[narration.mediaRef] = .voice }
        if case .recording(let recording) = plan.narrationIntent?.narrator { byRef[recording.mediaRef] = .voice }
        for cue in plan.soundCues ?? [] {
            guard let ref = cue.mediaRef else { continue }
            switch cue.role {
            case .voice: byRef[ref] = .voice
            case .music: byRef[ref] = .music
            case .ambience: byRef[ref] = .ambience
            case .sfx: byRef[ref] = .effects
            }
        }
        var assignments: [AudioRoleAssignment] = []
        var unmapped: [String] = []
        for clip in clips {
            guard let role = byRef[clip.mediaRef] else {
                unmapped.append(clip.id)
                continue
            }
            assignments.append(.init(clipId: clip.id, role: role))
        }
        return (assignments, unmapped)
    }

    private func runReviewStep(planId: String) async throws {
        guard let editor else { throw ProductionError.editorNotAvailable }
        let snapshot = editor.timeline
        let digest = try await ProductionRevision.make(
            timeline: snapshot, timelines: editor.timelines, urls: editor.mediaResolver.expectedURLMap())
        try Task.checkCancellation()
        if let step = editor.editPlan(id: planId)?.productionRun?.step(for: .review),
           step.state == .completed, step.outputDigest == digest {
            return
        }
        let key = "review:" + digest
        try updateRun(planId: planId) { run in
            run.phase = .reviewing
            run.blockedReason = nil
        }
        let structural = Self.structuralFindings(editor: editor, planId: planId, timelineRevision: digest)
        let frameCount = min(snapshot.totalFrames, 60 * max(1, snapshot.fps))
        var renderedFindings: [ProductionRun.Finding] = []
        if frameCount > 0 {
            do {
                let rendered = try await TimelineRenderer.render(
                    timeline: snapshot, resolver: editor.mediaResolver.snapshot(),
                    resolveTimeline: editor.timelineResolver(), missingMediaRefs: editor.missingMediaRefs,
                    startFrame: 0, frameCount: frameCount, shortSide: 720,
                    preset: AVAssetExportPresetHighestQuality)
                defer { Task { await TimelineRenderer.removeTemporaryRender(rendered) } }
                do {
                    let review = try await RenderedTimelineReview.inspect(
                        url: rendered, frameCount: frameCount, fps: snapshot.fps)
                    if review.clippedSamples > 0 {
                        renderedFindings.append(.init(severity: .error, kind: "clippedAudio",
                                                     message: "The rendered mix clipped \(review.clippedSamples) samples.",
                                                     fix: "mix_audio", source: .rendered))
                    }
                    if snapshot.totalFrames > frameCount {
                        renderedFindings.append(.init(severity: .warning, kind: "partialRenderReview",
                                                     message: "The rendered review covered the first \(frameCount) of \(snapshot.totalFrames) frames.",
                                                     fix: "review_timeline", source: .rendered))
                    }
                } catch {
                    renderedFindings.append(.init(
                        severity: .error, kind: "inspectionFailed",
                        message: "Inspecting the rendered draft failed: \(error.localizedDescription)",
                        fix: "review_timeline", source: .rendered))
                }
            } catch {
                renderedFindings.append(.init(
                    severity: .error, kind: "renderFailed",
                    message: "Rendering the draft failed: \(error.localizedDescription)",
                    fix: "get_timeline", source: .rendered))
            }
        }
        try persistFindings(planId: planId, findings: structural, source: .structural, digest: digest)
        try persistFindings(planId: planId, findings: renderedFindings, source: .rendered, digest: digest)
        try updateRun(planId: planId) { run in
            run.record(.init(kind: .review, state: .completed, key: key, outputDigest: digest,
                             completedAt: Date()))
        }
    }

    private func runExportStep(planId: String) async throws {
        guard let editor, let plan = editor.editPlan(id: planId), let run = plan.productionRun else {
            throw ProductionError.planNotFound
        }
        if run.terminalReceipt != nil { return }
        let snapshot = editor.timeline
        let digest = try await ProductionRevision.make(
            timeline: snapshot, timelines: editor.timelines, urls: editor.mediaResolver.expectedURLMap())
        let key = "export:" + digest
        let exportedFrames = snapshot.totalFrames
        let exportedFPS = max(1, snapshot.fps)
        let openErrors = run.reviewFindings.filter { $0.severity == .error }
        guard openErrors.isEmpty else {
            let reason = "Delivery refused by open review findings: "
                + openErrors.map { "\($0.kind): \($0.message)" }.joined(separator: "; ")
            try updateRun(planId: planId) { run in
                run.phase = .blocked
                run.blockedReason = reason
                run.record(.init(kind: .export, state: .failed, key: key, inputDigest: digest, error: reason))
            }
            return
        }
        guard run.verifiedTimelineRevision == digest else {
            let reason = "The timeline changed after review; review the current cut before delivery."
            try updateRun(planId: planId) { run in
                run.phase = .blocked
                run.blockedReason = reason
                run.record(.init(kind: .export, state: .failed, key: key, inputDigest: digest, error: reason))
            }
            return
        }
        try updateRun(planId: planId) { run in
            run.phase = .exporting
            run.blockedReason = nil
        }
        if let jobID = run.exportJobId, let uuid = UUID(uuidString: jobID) {
            guard let job = editor.exportQueue.jobs(for: editor.exportQueueProjectID)
                .first(where: { $0.id == uuid }) else {
                // The submitted job is gone. Resubmitting would risk a second
                // delivery, so the run blocks until a person asks for a new export.
                let reason = "The submitted export job is no longer available; export again explicitly to deliver."
                try updateRun(planId: planId) { run in
                    run.phase = .blocked
                    run.blockedReason = reason
                    run.record(.init(kind: .export, state: .failed, key: key, inputDigest: digest, error: reason))
                }
                return
            }
            guard run.exportedTimelineRevision == nil || run.exportedTimelineRevision == digest else {
                // The submitted export was rendered from a different revision.
                let reason = "The submitted export was rendered from an earlier revision; export again to deliver the reviewed cut."
                try updateRun(planId: planId) { run in
                    run.phase = .blocked
                    run.blockedReason = reason
                    run.record(.init(kind: .export, state: .failed, key: key, inputDigest: digest, error: reason))
                }
                return
            }
            try await finalizeExport(planId: planId, job: job, digest: digest, key: key,
                                     exportedFrames: exportedFrames, exportedFPS: exportedFPS)
            return
        }
        let outputURL = try Self.deliveryURL(runId: run.id)
        let submission = try await VideoExportJob.submit(
            editor: editor, queue: editor.exportQueue,
            request: .init(timeline: snapshot, format: .h264, resolution: .matchTimeline,
                            fcpxmlTarget: .default, outputURL: outputURL, source: .agent))
        // Persist the job id before waiting so an interruption, close, or crash
        // resumes by attaching, never by queueing a second export.
        try updateRun(planId: planId) { run in
            run.exportJobId = submission.jobID.uuidString
            run.exportPath = outputURL.path
            run.exportedTimelineRevision = digest
            run.exportedFrames = exportedFrames
            run.record(.init(kind: .export, state: .running, key: key, inputDigest: digest))
        }
        let job = try await editor.exportQueue.waitForCompletion(submission.jobID)
        try await finalizeExport(planId: planId, job: job, digest: digest, key: key,
                                 exportedFrames: exportedFrames, exportedFPS: exportedFPS)
    }

    private func finalizeExport(
        planId: String, job: ExportJob, digest: String, key: String, exportedFrames: Int, exportedFPS: Int
    ) async throws {
        switch job.status {
        case .completed:
            let delivered = FileManager.default.fileExists(atPath: job.outputURL.path)
            // The certificate binds to the delivered bytes: the exported file must
            // exist and cover exactly the reviewed runtime.
            let expectedSeconds = Double(exportedFrames) / Double(exportedFPS)
            let exportedSeconds = delivered ? await Self.exportedDuration(job.outputURL) : nil
            let durationMatches = exportedSeconds.map { abs($0 - expectedSeconds) <= 1.0 / Double(exportedFPS) } ?? false
            let certified = delivered && durationMatches
            var errors: [String] = []
            if !delivered { errors.append("The exported file is missing.") }
            if delivered, !durationMatches {
                errors.append("The exported file does not cover the reviewed runtime.")
            }
            let receipt = ProductionRun.TerminalReceipt(
                runId: job.id.uuidString, phase: "completed", approvedRevision: nil, reviewedSceneIds: [],
                comment: "", deliveryVerified: certified, exportJobId: job.id.uuidString,
                exportPath: job.outputURL.path, errors: errors,
                completedAt: Date(), verifiedTimelineRevision: digest, exportedTimelineRevision: digest)
            try updateRun(planId: planId) { run in
                run.terminalReceipt = receipt
                run.phase = certified ? .completed : .stale
                if !certified { run.approvedRevision = nil }
                run.record(.init(kind: .export, state: certified ? .completed : .failed, key: key,
                                 inputDigest: digest, outputDigest: digest,
                                 error: certified ? nil : errors.joined(separator: " "), completedAt: Date()))
            }
        case .canceled:
            try updateRun(planId: planId) { run in
                run.phase = .canceled
                run.approvedRevision = nil
                run.record(.init(kind: .export, state: .failed, key: key, inputDigest: digest,
                                 error: "Export canceled.", completedAt: Date()))
            }
        default:
            let message = job.error ?? "Export \(job.status.rawValue)."
            try updateRun(planId: planId) { run in
                // A failed delivery needs approval again before it is retried.
                run.phase = .stale
                run.approvedRevision = nil
                run.record(.init(kind: .export, state: .failed, key: key, inputDigest: digest,
                                 error: message, completedAt: Date()))
            }
        }
    }

    // MARK: - Findings and state

    private static func structuralFindings(
        editor: EditorViewModel, planId: String, timelineRevision: String
    ) -> [ProductionRun.Finding] {
        guard let plan = editor.editPlan(id: planId) else { return [] }
        var findings: [ProductionRun.Finding] = []
        let timeline = editor.timeline
        if timeline.tracks.allSatisfy({ $0.clips.isEmpty }) {
            findings.append(.init(severity: .error, kind: "emptyTimeline",
                                  message: "The production timeline has no shots to assemble, inspect, or deliver.",
                                  fix: "create_timeline", source: .structural))
        }
        for shot in plan.shots {
            if let ref = shot.mediaRef, editor.mediaAssetsById[ref] == nil || editor.missingMediaRefs.contains(ref) {
                findings.append(.init(shotId: shot.id, timelineRevision: timelineRevision, severity: .error,
                                      kind: "missingMedia",
                                      message: "Shot '\(shot.id)' ('\(shot.title)') references media '\(ref)' that is not available.",
                                      fix: "import_media", source: .structural))
            }
        }
        for cue in plan.soundCues ?? [] {
            if let ref = cue.mediaRef, editor.mediaAssetsById[ref] == nil || editor.missingMediaRefs.contains(ref) {
                findings.append(.init(timelineRevision: timelineRevision, severity: .error, kind: "missingMedia",
                                      message: "Sound cue '\(cue.cueId)' ('\(cue.purpose)') references media '\(ref)' that is not available.",
                                      fix: "import_media", source: .structural))
            }
        }
        for (index, track) in timeline.tracks.enumerated() where track.type == .video && !track.hidden {
            let sorted = track.clips.sorted { $0.startFrame < $1.startFrame }
            if let first = sorted.first, first.startFrame > 0 {
                findings.append(.init(timelineRevision: timelineRevision, severity: .error, kind: "blackGap",
                                      message: "Black gap of \(first.startFrame) frames at the head of video track \(index).",
                                      fix: "get_timeline", source: .structural))
            }
            for (a, b) in zip(sorted, sorted.dropFirst()) where b.startFrame > a.endFrame {
                findings.append(.init(timelineRevision: timelineRevision, severity: .error, kind: "blackGap",
                                      message: "Black gap of \(b.startFrame - a.endFrame) frames on video track \(index).",
                                      fix: "get_timeline", source: .structural))
            }
        }
        for (index, track) in timeline.tracks.enumerated() where track.hidden && !track.clips.isEmpty {
            findings.append(.init(timelineRevision: timelineRevision, severity: .error, kind: "hiddenTrack",
                                  message: "Track \(index) with \(track.clips.count) clip(s) is hidden.",
                                  fix: "manage_tracks", source: .structural))
        }
        if editor.enhancementJobs.values.contains(where: { $0.status == .running || $0.status == .queued }) {
            findings.append(.init(timelineRevision: timelineRevision, severity: .error, kind: "unfinishedEnhancement",
                                  message: "Clips on the timeline have unfinished AI enhancement jobs.",
                                  fix: "get_enhancement_job_status", source: .structural))
        }
        return findings
    }

    private func persistFindings(
        planId: String, findings: [ProductionRun.Finding],
        source: ProductionRun.Finding.Source, digest: String?
    ) throws {
        guard let editor, let plan = editor.editPlan(id: planId), var run = plan.productionRun else {
            throw ProductionError.planNotFound
        }
        try run.replaceFindings(findings, source: source)
        if let digest {
            run.verifiedTimelineRevision = run.reviewFindings.contains(where: { $0.severity == .error }) ? nil : digest
        }
        try run.validate()
        try editor.commitProductionRunMetadata(run, plan: plan)
    }

    private func updateRun(planId: String, _ change: (inout ProductionRun) -> Void) throws {
        guard let editor, let plan = editor.editPlan(id: planId), var run = plan.productionRun else {
            throw ProductionError.planNotFound
        }
        change(&run)
        try run.validate()
        try editor.commitProductionRunMetadata(run, plan: plan)
    }

    /// Duration of the delivered file, read off the encoded output.
    @concurrent
    private static func exportedDuration(_ url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        return try? await asset.load(.duration).seconds
    }

    private static func deliveryURL(runId: String) throws -> URL {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            throw ProductionError.exportFailed("Downloads folder not found.")
        }
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let base = "production-\(runId.prefix(8))"
        var candidate = downloads.appendingPathComponent("\(base).mp4")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = downloads.appendingPathComponent("\(base) \(index).mp4")
            index += 1
        }
        return candidate
    }
}

struct ProductionStatus: Sendable {
    let planId: String
    let phase: ProductionRun.Phase
    let runId: String?
    let storyboardRevision: String?
    let approvedRevision: String?
    let reviewedSceneCount: Int
    let totalScenes: Int
    let comment: String
    let steps: [ProductionRun.Step]
    let reviewFindings: [ProductionRun.Finding]
    let verifiedTimelineRevision: String?
    let exportedTimelineRevision: String?
    let exportJobId: String?
    let exportPath: String?
    let terminalReceipt: ProductionRun.TerminalReceipt?
    let blockedReason: String?

    var receipt: [String: Any] {
        var row: [String: Any] = [
            "planId": planId, "phase": phase.rawValue, "reviewedSceneCount": reviewedSceneCount,
            "totalScenes": totalScenes, "comment": comment,
            "steps": steps.map(\.receipt),
            "reviewFindings": reviewFindings.map(\.receipt),
            "deliveryVerified": terminalReceipt?.deliveryVerified ?? false,
        ]
        if let runId { row["runId"] = runId }
        if let storyboardRevision { row["storyboardRevision"] = storyboardRevision }
        if let approvedRevision { row["approvedRevision"] = approvedRevision }
        if let verifiedTimelineRevision { row["verifiedTimelineRevision"] = verifiedTimelineRevision }
        if let exportedTimelineRevision { row["exportedTimelineRevision"] = exportedTimelineRevision }
        if let exportJobId { row["exportJobId"] = exportJobId }
        if let exportPath { row["exportPath"] = exportPath }
        if let blockedReason { row["blockedReason"] = blockedReason }
        if let terminalReceipt { row["terminalReceipt"] = ProductionRun.receipt(of: terminalReceipt) }
        return row
    }
}

enum ProductionError: LocalizedError, Equatable, Sendable {
    case planNotFound
    case missingProductionRun
    case productionCanceled
    case notReady(String)
    case invalidPlanStatus(String)
    case invalidState(String)
    case approvalBlocked(String)
    case exportFailed(String)
    case exportBlocked([ProductionRun.Finding])
    case editorNotAvailable

    var errorDescription: String? {
        switch self {
        case .planNotFound: return "Plan not found"
        case .missingProductionRun: return "No production run exists for this plan"
        case .productionCanceled: return "Production run was canceled"
        case .notReady(let reason): return "Production not ready: \(reason)"
        case .invalidPlanStatus(let reason): return "Invalid plan status: \(reason)"
        case .invalidState(let reason): return "Invalid state: \(reason)"
        case .approvalBlocked(let reason): return "Approval blocked: \(reason)"
        case .exportFailed(let reason): return "Export failed: \(reason)"
        case .exportBlocked(let findings):
            return "Export blocked by quality findings: \(findings.map { "\($0.severity.rawValue)/\($0.kind): \($0.message)" }.joined(separator: "; "))"
        case .editorNotAvailable: return "Editor not available"
        }
    }
}
