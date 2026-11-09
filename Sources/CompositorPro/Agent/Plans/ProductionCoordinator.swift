import Foundation

@MainActor
final class ProductionCoordinator {
    typealias Phase = ProductionRun.Phase
    typealias VisualReview = ProductionRun.VisualReview

    struct TerminalReceipt: Codable, Sendable, Equatable {
        var runId: String
        var phase: String
        var approvedRevision: String?
        var reviewedSceneIds: [String]
        var comment: String
        var deliveryVerified: Bool
        var exportJobId: String?
        var exportPath: String?
        var errors: [String]
        var completedAt: Date?
    }

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
    var terminalReceipt: TerminalReceipt?

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
                terminalReceipt: nil
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
            exportJobId: terminalReceipt?.exportJobId,
            terminalReceipt: terminalReceipt
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
            try await runExport()
        case .assembling:
            try await runExport()
        case .stale:
            try await runPrepareStoryboard()
        default:
            break
        }
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
        phase = .exporting
        let filename = "production-\(runId.uuidString.prefix(8)).mov"
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(filename)
        let result = try await toolExecutor.exportProject(editor, [
            "mode": "video",
            "outputPath": outputURL.path,
            "overwrite": true
        ])
        if result.isError {
            let errorMsg = result.content.compactMap {
                if case .text(let t) = $0 { return t } else { return nil }
            }.joined(separator: " ")
            throw ProductionError.exportFailed(errorMsg.isEmpty ? "Export failed" : errorMsg)
        }
        try validatePlanAccessible()
        let run = editor.editPlan(id: planId)?.productionRun
        terminalReceipt = TerminalReceipt(
            runId: runId.uuidString,
            phase: "completed",
            approvedRevision: run?.approvedRevision,
            reviewedSceneIds: run?.visualReviews.map(\.sceneId) ?? visualReviews.map(\.sceneId),
            comment: run?.comment ?? comment,
            deliveryVerified: true,
            exportJobId: UUID().uuidString,
            exportPath: outputURL.path,
            errors: [],
            completedAt: Date()
        )
        phase = .completed
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
    let terminalReceipt: ProductionCoordinator.TerminalReceipt?
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
        case .toolError(let reason): return "Tool error: \(reason)"
        case .editorNotAvailable: return "Editor not available"
        case .revisionMismatch(let reason): return "Revision mismatch: \(reason)"
        }
    }
}

