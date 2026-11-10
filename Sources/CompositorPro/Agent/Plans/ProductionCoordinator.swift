import Foundation

@MainActor
final class ProductionCoordinator {
    typealias Phase = ProductionRun.Phase
    typealias VisualReview = ProductionRun.VisualReview

    protocol JobHandle: Sendable {
        var id: UUID { get }
        func cancel() async
    }

    struct AnyJobHandle: JobHandle {
        let id: UUID
        private let onCancel: @Sendable () async -> Void

        init(id: UUID = UUID(), onCancel: @escaping @Sendable () async -> Void = {}) {
            self.id = id
            self.onCancel = onCancel
        }

        func cancel() async {
            await onCancel()
        }
    }

    let runId: UUID
    let projectId: String
    let timelineId: String
    let planId: String

    var phase: Phase = .awaitingStoryboardApproval
    var storyboardRevision: String?
    var approvedRevision: String?
    var visualReviews: [VisualReview] = []
    var comment: String = ""
    var terminalReceipt: ProductionRun.TerminalReceipt?

    private(set) var jobHandles: [UUID: any JobHandle] = [:]
    private(set) var currentJobHandle: (any JobHandle)?

    private weak var editor: EditorViewModel?
    private let packageCoordinator: ProjectPackageCoordinator
    private let exportQueue: ExportQueue
    private let toolExecutor: ToolExecutor

    init(
        runId: UUID = UUID(),
        planId: String,
        projectId: String,
        timelineId: String,
        editor: EditorViewModel,
        packageCoordinator: ProjectPackageCoordinator,
        exportQueue: ExportQueue,
        toolExecutor: ToolExecutor
    ) {
        self.runId = runId
        self.planId = planId
        self.projectId = projectId
        self.timelineId = timelineId
        self.editor = editor
        self.packageCoordinator = packageCoordinator
        self.exportQueue = exportQueue
        self.toolExecutor = toolExecutor
    }

    func startProduction() async throws {
        try validatePlanAccessible()
        guard let plan = editor?.editPlan(id: planId) else {
            throw ProductionError.planNotFound
        }
        guard plan.status == .proposed || plan.status == .approved else {
            throw ProductionError.invalidPlanStatus("Plan must be proposed or approved to start production.")
        }
        try await runPrepareStoryboard()
    }

    func resumeProduction() async throws {
        try validatePlanAccessible()
        guard let plan = editor?.editPlan(id: planId) else {
            throw ProductionError.planNotFound
        }
        guard let run = plan.productionRun else {
            throw ProductionError.missingProductionRun
        }
        guard run.phase != .canceled else {
            throw ProductionError.productionCanceled
        }

        phase = run.phase
        storyboardRevision = run.storyboardRevision
        approvedRevision = run.approvedRevision
        visualReviews = run.visualReviews
        comment = run.comment
        // The persisted receipt is the delivered truth: a reopened run must not claim
        // a fresh delivery or resubmit an export.
        terminalReceipt = run.terminalReceipt

        try await executeNextPhase()
    }

    func cancelProduction() async throws {
        try validatePlanAccessible()
        guard let editor else { throw ProductionError.editorNotAvailable }

        if let current = currentJobHandle {
            await current.cancel()
            jobHandles.removeValue(forKey: current.id)
            currentJobHandle = nil
        }

        try editor.cancelProductionReview(planId: planId)
        phase = .canceled
    }

    func status() -> ProductionStatus {
        guard let plan = editor?.editPlan(id: planId) else {
            return ProductionStatus(
                runId: runId.uuidString,
                projectId: projectId,
                timelineId: timelineId,
                planId: planId,
                phase: .canceled,
                storyboardRevision: nil,
                approvedRevision: nil,
                reviewedSceneCount: 0,
                totalScenes: 0,
                comment: "Plan not found",
                currentJobId: nil,
                exportJobId: nil,
                terminalReceipt: nil,
                reviewFindings: [],
                verifiedTimelineRevision: nil
            )
        }

        let run = plan.productionRun
        return ProductionStatus(
            runId: runId.uuidString,
            projectId: projectId,
            timelineId: timelineId,
            planId: planId,
            phase: run?.phase ?? phase,
            storyboardRevision: run?.storyboardRevision ?? storyboardRevision,
            approvedRevision: run?.approvedRevision ?? approvedRevision,
            reviewedSceneCount: run?.visualReviews.count ?? visualReviews.count,
            totalScenes: plan.shots.count,
            comment: run?.comment ?? comment,
            currentJobId: currentJobHandle?.id.uuidString,
            exportJobId: run?.terminalReceipt?.exportJobId ?? run?.exportJobId ?? terminalReceipt?.exportJobId,
            terminalReceipt: run?.terminalReceipt ?? terminalReceipt,
            reviewFindings: run?.reviewFindings ?? [],
            verifiedTimelineRevision: run?.verifiedTimelineRevision
        )
    }

    func reviewScene(
        sceneId: String,
        selectionRevision: String,
        coverage: VisualReview.Coverage,
        reviewer: String,
        evidence: String,
        facesRevealed: Bool,
        rightsConfirmed: Bool,
        suspectedDuplicate: Bool
    ) async throws -> StoryboardReport {
        try validatePlanAccessible()
        guard let editor else { throw ProductionError.editorNotAvailable }
        guard let revision = storyboardRevision else {
            throw ProductionError.invalidState("No storyboard revision available for review.")
        }

        let review = VisualReview(
            sceneId: sceneId,
            selectionRevision: selectionRevision,
            coverage: coverage,
            reviewer: reviewer,
            evidence: evidence,
            facesRevealed: facesRevealed,
            rightsConfirmed: rightsConfirmed,
            suspectedDuplicate: suspectedDuplicate
        )
        let report = try await editor.reviewStoryboardScene(
            planId: planId,
            revision: revision,
            review: review
        )
        try validatePlanAccessible()
        storyboardRevision = report.revision
        phase = report.phase
        approvedRevision = report.approvedRevision
        visualReviews = editor.editPlan(id: planId)?.productionRun?.visualReviews ?? []
        return report
    }

    func approveStoryboard(comment: String = "") async throws -> StoryboardReport {
        try validatePlanAccessible()
        guard let editor else { throw ProductionError.editorNotAvailable }
        guard let revision = storyboardRevision else {
            throw ProductionError.invalidState("No storyboard revision available for approval.")
        }
        let report = try await editor.approveStoryboard(
            planId: planId,
            revision: revision,
            comment: comment
        )
        try validatePlanAccessible()
        storyboardRevision = report.revision
        approvedRevision = report.approvedRevision
        self.comment = comment
        phase = report.phase

        try await executeNextPhase()
        return report
    }

    private func executeNextPhase() async throws {
        switch phase {
        case .awaitingStoryboardApproval:
            try await runPrepareStoryboard()
        case .approved:
            try await runApplyPlan()
            try await runFinishAudio()
            try await runExport()
        case .assembling:
            try await runFinishAudio()
            try await runExport()
        case .finishing:
            try await runExport()
        case .reviewing:
            try await runExport()
        case .stale:
            try await runPrepareStoryboard()
        default:
            break
        }
    }

    private func runFinishAudio() async throws {
        guard let editor else { throw ProductionError.editorNotAvailable }
        let audibleClips = editor.timeline.tracks.filter { $0.type == .audio && !$0.muted }.flatMap(\.clips)
        guard !audibleClips.isEmpty else { return }
        if editor.timeline.audioMix != nil { return }
        phase = .finishing
        var roles: [[String: Any]] = []
        for clip in audibleClips {
            let role: String
            if clip.id.hasPrefix("narration") || clip.mediaRef.contains("voice") || clip.mediaRef.contains("narrat") {
                role = "voice"
            } else if clip.mediaRef.contains("music") || clip.mediaRef.contains("bed") {
                role = "music"
            } else if clip.mediaRef.contains("ambien") {
                role = "ambience"
            } else {
                role = "effects"
            }
            roles.append(["clipId": clip.id, "role": role])
        }
        _ = try? await toolExecutor.mixAudio(editor, [
            "roles": roles,
            "targetLUFS": -16.0,
            "truePeakDBTP": -1.0,
        ])
    }

    private func runPrepareStoryboard() async throws {
        guard let editor else { throw ProductionError.editorNotAvailable }
        let report = try await editor.prepareStoryboard(planId: planId)
        try validatePlanAccessible()
        storyboardRevision = report.revision
        phase = report.phase
        approvedRevision = report.approvedRevision
        visualReviews = editor.editPlan(id: planId)?.productionRun?.visualReviews ?? []
    }

    private func runApplyPlan() async throws {
        guard let editor else { throw ProductionError.editorNotAvailable }
        phase = .assembling
        let result = try await toolExecutor.applyPlan(editor, ["planId": planId, "commit": true])
        if result.isError {
            let errorMsg = result.content.compactMap {
                if case .text(let t) = $0 { return t } else { return nil }
            }.joined(separator: " ")
            throw ProductionError.toolError(errorMsg.isEmpty ? "Assembly failed" : errorMsg)
        }
        try validatePlanAccessible()
    }

    private func runExport() async throws {
        guard let editor else { throw ProductionError.editorNotAvailable }
        // A persisted terminal receipt wins: the run already delivered and reopening
        // must not resubmit an export or claim fresh delivery.
        let run = editor.editPlan(id: planId)?.productionRun
        if let receipt = run?.terminalReceipt {
            phase = receipt.phase == "completed" ? .completed : .stale
            terminalReceipt = receipt
            return
        }
        phase = .exporting
        // Reattach to a job submitted by an interrupted attempt before any new
        // submission, so retry after restart never queues the export twice.
        if let jobID = run?.exportJobId {
            try await attachToExport(editor, jobId: jobID)
            return
        }
        let structuralFindings = try runDeterministicChecks(editor: editor)
        try persistFindings(editor, findings: structuralFindings)
        // Every open error finding blocks the export, including editorial ones recorded earlier.
        let openErrors = (editor.editPlan(id: planId)?.productionRun?.reviewFindings ?? [])
            .filter { $0.severity == .error }
        if !openErrors.isEmpty {
            throw ProductionError.exportBlocked(openErrors)
        }
        try await submitAndAwaitExport(editor)
    }

    /// Deterministic delivery checks over the current project: an empty output
    /// timeline and unavailable shot media must surface as error findings before
    /// any export is submitted.
    private func runDeterministicChecks(editor: EditorViewModel) throws -> [ProductionRun.Finding] {
        guard let plan = editor.editPlan(id: planId) else { return [] }
        var findings: [ProductionRun.Finding] = []
        let timeline = editor.timeline

        if timeline.tracks.allSatisfy({ $0.clips.isEmpty }) {
            findings.append(ProductionRun.Finding(
                severity: .error,
                kind: "emptyTimeline",
                message: "The production timeline has no shots to assemble, inspect, or deliver.",
                fix: "create_timeline",
                source: .structural))
        }

        for shot in plan.shots {
            if let mediaRef = shot.mediaRef, editor.mediaAssetsById[mediaRef] == nil || editor.missingMediaRefs.contains(mediaRef) {
                findings.append(ProductionRun.Finding(
                    shotId: shot.id,
                    timelineRevision: storyboardRevision,
                    severity: .error,
                    kind: "missingMedia",
                    message: "Shot '\(shot.id)' ('\(shot.title)') references media '\(mediaRef)' that is not available.",
                    fix: "import_media",
                    source: .structural))
            }
        }

        for cue in plan.soundCues ?? [] {
            if let mediaRef = cue.mediaRef, editor.mediaAssetsById[mediaRef] == nil || editor.missingMediaRefs.contains(mediaRef) {
                findings.append(ProductionRun.Finding(
                    timelineRevision: storyboardRevision,
                    severity: .error,
                    kind: "missingMedia",
                    message: "Sound cue '\(cue.cueId)' ('\(cue.purpose)') references media '\(mediaRef)' that is not available.",
                    fix: "import_media",
                    source: .structural))
            }
        }

        for (trackIdx, track) in timeline.tracks.enumerated() where track.type == .video && !track.hidden {
            let sorted = track.clips.sorted { $0.startFrame < $1.startFrame }
            if let first = sorted.first, first.startFrame > 0 {
                findings.append(ProductionRun.Finding(
                    severity: .error,
                    kind: "blackGap",
                    message: "Black gap of \(first.startFrame) frames at head of video track \(trackIdx).",
                    fix: "get_timeline",
                    source: .structural))
            }
            for (a, b) in zip(sorted, sorted.dropFirst()) where b.startFrame > a.endFrame {
                findings.append(ProductionRun.Finding(
                    severity: .error,
                    kind: "blackGap",
                    message: "Black gap of \(b.startFrame - a.endFrame) frames between clips on video track \(trackIdx).",
                    fix: "get_timeline",
                    source: .structural))
            }
        }

        for (trackIdx, track) in timeline.tracks.enumerated() where track.hidden && !track.clips.isEmpty {
            findings.append(ProductionRun.Finding(
                severity: .error,
                kind: "hiddenTrack",
                message: "Track \(trackIdx) with \(track.clips.count) clip(s) is hidden.",
                fix: "manage_tracks",
                source: .structural))
        }

        if editor.enhancementJobs.values.contains(where: { $0.status == .running || $0.status == .queued }) {
            findings.append(ProductionRun.Finding(
                severity: .error,
                kind: "unfinishedEnhancement",
                message: "Clips on the timeline have unfinished AI enhancement jobs.",
                fix: "get_enhancement_job_status",
                source: .structural))
        }

        let audibleClips = timeline.tracks.filter { $0.type == .audio && !$0.muted }.flatMap(\.clips)
        if audibleClips.contains(where: { $0.volume > 2.0 }) {
            findings.append(ProductionRun.Finding(
                severity: .error,
                kind: "clippedNarration",
                message: "Audio track volume exceeds safe ceiling and risks digital clipping.",
                fix: "mix_audio",
                source: .rendered))
        }

        return findings
    }

    /// Records the structural findings on the run. Editorial findings recorded earlier
    /// are kept: a structural pass replaces only its own findings.
    private func persistFindings(_ editor: EditorViewModel, findings: [ProductionRun.Finding]) throws {
        guard var plan = editor.editPlan(id: planId), var run = plan.productionRun else { return }
        try run.replaceFindings(findings, source: .structural)
        // The timeline is only verified while no error finding is open.
        let hasOpenError = run.reviewFindings.contains { $0.severity == .error }
        run.verifiedTimelineRevision = hasOpenError ? nil : storyboardRevision
        try run.validate()
        plan.productionRun = run
        try editor.commitProductionRun(run, plan: plan, actionName: "Production Quality Check")
    }

    /// Waits for a previously submitted export and persists the terminal receipt.
    private func attachToExport(_ editor: EditorViewModel, jobId: String) async throws {
        let listed = try await toolExecutor.manageExports(editor, ["action": "list"])
        let payload = try Self.jsonPayload(listed)
        let rows = (payload["exports"] as? [[String: Any]]) ?? []
        let row = rows.first { ($0["jobId"] as? String) == jobId }
        guard let status = row?["status"] as? String else {
            // Job gone from this project's queue (closed and reopened): resubmit.
            try await submitAndAwaitExport(editor)
            return
        }
        if status == "failed" || status == "canceled" {
            try persistTerminal(editor, terminalStatus: status, jobId: jobId,
                                error: (row?["error"] as? String).map { [$0] } ?? ["Export \(status)."])
            return
        }
        try await awaitExport(editor, jobId: jobId)
    }

    private func submitAndAwaitExport(_ editor: EditorViewModel) async throws {
        try Task.checkCancellation()
        let filename = "production-\(runId.uuidString.prefix(8)).mp4"
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(filename)
        let result = try await toolExecutor.exportProject(editor, [
            "mode": "video",
            "outputPath": outputURL.path,
            "overwrite": true,
        ])
        if result.isError {
            let errorMessage = Self.errorText(of: result)
            throw ProductionError.exportFailed(errorMessage.isEmpty ? "Export failed" : errorMessage)
        }
        let payload = try Self.jsonPayload(result)
        guard let jobID = payload["jobId"] as? String else {
            throw ProductionError.exportFailed("Export submission returned no jobId.")
        }
        // Persist the job id before waiting so an interruption, close, or crash
        // resumes by attaching, not by queueing the export again.
        try persistExportState(editor, jobId: jobID, path: outputURL.path)
        do {
            try await awaitExport(editor, jobId: jobID)
        }
    }

    private func awaitExport(_ editor: EditorViewModel, jobId: String) async throws {
        currentJobHandle = AnyJobHandle { _ = try? await self.toolExecutor.manageExports(editor, ["action": "cancel", "jobId": jobId]) }
        defer { currentJobHandle = nil }
        let waited = try await toolExecutor.manageExports(editor, ["action": "wait", "jobId": jobId])
        let payload = try Self.jsonPayload(waited)
        let status = (payload["status"] as? String) ?? "failed"
        switch status {
        case "completed":
            try persistTerminal(editor, terminalStatus: status, jobId: jobId)
        case "canceled":
            phase = .canceled
            throw CancellationError()
        default:
            let error = (payload["error"] as? String).map { [$0] } ?? ["Export \(status)."]
            try persistTerminal(editor, terminalStatus: status, jobId: jobId, error: error)
        }
    }

    /// Persists the export job id on the plan's production run so resumption can
    /// attach to the live job.
    private func persistExportState(_ editor: EditorViewModel, jobId: String, path: String) throws {
        guard var plan = editor.editPlan(id: planId), var run = plan.productionRun else { return }
        guard let persistedID = UUID(uuidString: jobId) else {
            throw ProductionError.exportFailed("Export receipt jobId is not a UUID: \(jobId)")
        }
        run.exportJobId = persistedID.uuidString
        run.exportPath = path
        try run.validate()
        plan.productionRun = run
        try editor.commitProductionRun(run, plan: plan, actionName: "Production Export Queued")
    }

    /// Persists the terminal receipt; awaited export state may have moved the plan.
    private func persistTerminal(
        _ editor: EditorViewModel,
        terminalStatus: String,
        jobId: String,
        error: [String]? = nil
    ) throws {
        guard var plan = editor.editPlan(id: planId), var run = plan.productionRun else {
            throw ProductionError.planNotFound
        }
        let delivered = terminalStatus == "completed"
        let receipt = ProductionRun.TerminalReceipt(
            runId: runId.uuidString,
            phase: terminalStatus,
            approvedRevision: run.approvedRevision,
            reviewedSceneIds: run.visualReviews.map(\.sceneId),
            comment: run.comment,
            deliveryVerified: delivered,
            exportJobId: (UUID(uuidString: jobId)?.uuidString ?? jobId),
            exportPath: run.exportPath,
            errors: error ?? [],
            completedAt: Date()
        )
        run.terminalReceipt = receipt
        // The run's phase keeps its approval invariant (past-approval phases
        // carry approvedRevision; canceled/stale must not); the receipt's phase
        // field records the terminal export outcome.
        run.phase = delivered ? .completed : run.phase
        try run.validate()
        plan.productionRun = run
        try editor.commitProductionRun(run, plan: plan, actionName: "Production Delivery Recorded")
        phase = delivered ? .completed : .stale
        terminalReceipt = receipt
    }

    private static func jsonPayload(_ result: ToolResult) throws -> [String: Any] {
        let text = result.content.compactMap {
            if case .text(let t) = $0 { return t } else { return nil }
        }.joined(separator: " ")
        guard let data = text.data(using: .utf8),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProductionError.toolError("Production step returned unreadable JSON.")
        }
        return payload
    }

    private static func errorText(of result: ToolResult) -> String {
        result.content.compactMap {
            if case .text(let t) = $0 { return t } else { return nil }
        }.joined(separator: " ")
    }

    private func validatePlanAccessible() throws {
        guard editor?.editPlan(id: planId) != nil else {
            throw ProductionError.planNotFound
        }
    }
}

struct ProductionStatus: Sendable {
    let runId: String
    let projectId: String
    let timelineId: String
    let planId: String
    let phase: ProductionRun.Phase
    let storyboardRevision: String?
    let approvedRevision: String?
    let reviewedSceneCount: Int
    let totalScenes: Int
    let comment: String
    let currentJobId: String?
    let exportJobId: String?
    let terminalReceipt: ProductionRun.TerminalReceipt?
    let reviewFindings: [ProductionRun.Finding]
    let verifiedTimelineRevision: String?
}

enum ProductionError: LocalizedError, Equatable {
    case planNotFound
    case timelineMismatch
    case jobNotFound
    case missingProductionRun
    case productionCanceled
    case notReady(String)
    case invalidPlanStatus(String)
    case invalidState(String)
    case approvalBlocked(String)
    case exportFailed(String)
    case exportBlocked([ProductionRun.Finding])
    case toolError(String)
    case editorNotAvailable
    case revisionMismatch(String)

    var errorDescription: String? {
        switch self {
        case .planNotFound: return "Plan not found"
        case .timelineMismatch: return "Timeline mismatch"
        case .jobNotFound: return "Job not found"
        case .missingProductionRun: return "No production run exists for this plan"
        case .productionCanceled: return "Production run was canceled"
        case .notReady(let reason): return "Production not ready: \(reason)"
        case .invalidPlanStatus(let reason): return "Invalid plan status: \(reason)"
        case .invalidState(let reason): return "Invalid state: \(reason)"
        case .approvalBlocked(let reason): return "Approval blocked: \(reason)"
        case .exportFailed(let reason): return "Export failed: \(reason)"
        case .exportBlocked(let findings):
            return "Export blocked by quality findings: \(findings.map { "\($0.severity.rawValue)/\($0.kind): \($0.message)" }.joined(separator: "; "))"
        case .toolError(let reason): return "Tool error: \(reason)"
        case .editorNotAvailable: return "Editor not available"
        case .revisionMismatch(let reason): return "Revision mismatch: \(reason)"
        }
    }
}

