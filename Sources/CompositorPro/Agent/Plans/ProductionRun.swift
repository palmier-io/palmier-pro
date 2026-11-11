import Foundation

struct ProductionRun: Codable, Sendable, Equatable {
    enum Phase: String, Codable, Sendable {
        case awaitingStoryboardApproval = "awaiting_storyboard_approval"
        case approved
        case assembling
        case finishing
        case reviewing
        case exporting
        case completed
        case blocked
        case stale
        case canceled
    }

    struct VisualReview: Codable, Sendable, Equatable {
        enum Coverage: String, Codable, Sendable {
            case fullStill = "full_still_inspection"
            case fullSpan = "full_span_playback"
        }

        var sceneId: String
        var selectionRevision: String
        var coverage: Coverage
        var reviewer: String
        var evidence: String
        var facesRevealed: Bool
        var rightsConfirmed: Bool
        var suspectedDuplicate: Bool
    }

    struct Finding: Codable, Sendable, Equatable {
        enum Source: String, Codable, Sendable {
            case editorial
            case structural
            case rendered
        }

        enum Severity: String, Codable, Sendable {
            case info = "info"
            case warning = "warning"
            case error = "error"
        }

        var id: String = UUID().uuidString
        var shotId: String?
        var timelineRevision: String?
        var severity: Severity
        var kind: String
        var message: String
        var fix: String?
        var source: Source

        init(
            id: String = UUID().uuidString,
            shotId: String? = nil,
            timelineRevision: String? = nil,
            severity: Severity,
            kind: String,
            message: String,
            fix: String? = nil,
            source: Source = .editorial
        ) {
            self.id = id
            self.shotId = shotId
            self.timelineRevision = timelineRevision
            self.severity = severity
            self.kind = kind
            self.message = message
            self.fix = fix
            self.source = source
        }

        func validated() throws -> Self {
            var finding = self
            finding.id = try EditPlan.validatedID(id, field: "production finding id")
            finding.kind = try EditPlan.validatedID(kind, field: "production finding kind")
            finding.message = try EditPlan.validatedText(message, field: "production finding message")
            guard !finding.message.isEmpty else {
                throw EditPlanValidationError.invalidText(field: "production finding")
            }
            if let shotId = finding.shotId {
                finding.shotId = try EditPlan.validatedID(shotId, field: "production finding shotId")
            }
            if let timelineRevision = finding.timelineRevision, !ProductionRun.validRevision(timelineRevision) {
                throw EditPlanValidationError.invalidReference("Finding timelineRevision must be a revision digest.")
            }
            if let fix { finding.fix = try EditPlan.validatedID(fix, field: "production finding fix") }
            return finding
        }

        var receipt: [String: Any] {
            var row: [String: Any] = [
                "id": id,
                "severity": severity.rawValue,
                "kind": kind,
                "message": message,
                "source": source.rawValue,
            ]
            if let shotId { row["shotId"] = shotId }
            if let timelineRevision { row["timelineRevision"] = timelineRevision }
            if let fix { row["fix"] = fix }
            return row
        }
    }

    /// One production step with its persisted outcome. The key is the idempotency
    /// key: a step whose key already carries a terminal receipt is never run again.
    struct Step: Codable, Sendable, Equatable {
        enum Kind: String, Codable, Sendable, CaseIterable {
            case assemble, mix, review, export
        }

        enum State: String, Codable, Sendable {
            case pending, running, completed, failed, skipped
        }

        var kind: Kind
        var state: State
        var key: String
        var inputDigest: String?
        var outputDigest: String?
        var error: String?
        var completedAt: Date?

        var isTerminal: Bool { state == .completed || state == .failed || state == .skipped }

        var receipt: [String: Any] {
            var row: [String: Any] = ["kind": kind.rawValue, "state": state.rawValue, "key": key]
            if let inputDigest { row["inputDigest"] = inputDigest }
            if let outputDigest { row["outputDigest"] = outputDigest }
            if let error { row["error"] = error }
            if let completedAt { row["completedAt"] = completedAt.timeIntervalSince1970 }
            return row
        }
    }

    var id: String = UUID().uuidString
    var phase: Phase = .awaitingStoryboardApproval
    var storyboardRevision: String
    var approvedRevision: String?
    var visualReviews: [VisualReview] = []
    var comment: String = ""
    var exportJobId: String?
    var exportPath: String?
    var terminalReceipt: TerminalReceipt?
    var reviewFindings: [Finding] = []
    /// Digest of the timeline revision that was rendered and reviewed.
    var verifiedTimelineRevision: String?
    /// Digest of the timeline revision the delivered export was rendered from.
    var exportedTimelineRevision: String?
    /// Frames the delivered export was rendered from. Delivery is certified
    /// against these frames, not against whatever the timeline holds later.
    var exportedFrames: Int?
    /// Dependency that stopped the run, if any. The run resumes from this point.
    var blockedReason: String?
    var steps: [Step] = []

    func step(for kind: Step.Kind) -> Step? {
        steps.first { $0.kind == kind }
    }

    mutating func record(_ step: Step) {
        steps.removeAll { $0.kind == step.kind }
        steps.append(step)
        steps.sort { $0.kind.rawValue < $1.kind.rawValue }
    }

    mutating func replaceFindings(_ findings: [Finding], source: Finding.Source) throws {
        let normalized = try findings.map { try $0.validated() }
        guard normalized.allSatisfy({ $0.source == source }) else {
            throw EditPlanValidationError.invalidReference("A review may replace only its own findings.")
        }
        let next = reviewFindings.filter { $0.source != source } + normalized
        guard Set(next.map(\.id)).count == next.count else {
            throw EditPlanValidationError.invalidReference("Production finding IDs must be unique.")
        }
        reviewFindings = next
        if next.contains(where: { $0.severity == .error }) { verifiedTimelineRevision = nil }
    }

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
        /// Timeline revision that was rendered and reviewed before delivery.
        var verifiedTimelineRevision: String?
        /// Timeline revision the delivered export was rendered from.
        var exportedTimelineRevision: String?
    }

    func validate() throws {
        let isPastApproval = phase != .awaitingStoryboardApproval && phase != .stale && phase != .canceled
        guard UUID(uuidString: id) != nil, ProductionRun.validRevision(storyboardRevision),
              approvedRevision.map(ProductionRun.validRevision) ?? true,
              isPastApproval == (approvedRevision != nil),
              approvedRevision == nil || approvedRevision == storyboardRevision,
              visualReviews.count <= EditPlanLimits.maximumShots,
              Set(visualReviews.map(\.sceneId)).count == visualReviews.count else {
            throw EditPlanValidationError.invalidReference("Invalid production review state.")
        }
        _ = try EditPlan.validatedText(comment, field: "storyboard comment")
        if let exportPath {
            _ = try EditPlan.validatedText(exportPath, field: "production export path")
        }
        if let receipt = terminalReceipt {
            guard UUID(uuidString: receipt.runId) != nil,
                  receipt.phase == "completed" || receipt.phase == "failed",
                  !receipt.deliveryVerified || receipt.phase == "completed",
                  receipt.deliveryVerified || !receipt.errors.isEmpty else {
                throw EditPlanValidationError.invalidReference("Invalid production terminal receipt.")
            }
        }
        guard reviewFindings.count <= 1_024, Set(reviewFindings.map(\.id)).count == reviewFindings.count else {
            throw EditPlanValidationError.invalidReference("Production review stores at most 1,024 uniquely identified findings.")
        }
        for finding in reviewFindings {
            _ = try finding.validated()
        }
        if let verifiedTimelineRevision, !ProductionRun.validRevision(verifiedTimelineRevision) {
            throw EditPlanValidationError.invalidReference("verifiedTimelineRevision must be a revision digest.")
        }
        if let exportedTimelineRevision, !ProductionRun.validRevision(exportedTimelineRevision) {
            throw EditPlanValidationError.invalidReference("exportedTimelineRevision must be a revision digest.")
        }
        if let exportedFrames, exportedFrames < 0 {
            throw EditPlanValidationError.invalidReference("exportedFrames cannot be negative.")
        }
        guard verifiedTimelineRevision == nil || !reviewFindings.contains(where: { $0.severity == .error }) else {
            throw EditPlanValidationError.invalidReference("Unresolved error findings prevent verification.")
        }
        guard steps.count <= ProductionRun.Step.Kind.allCases.count,
              Set(steps.map(\.kind)).count == steps.count else {
            throw EditPlanValidationError.invalidReference("Production stores one outcome per step.")
        }
        for step in steps {
            _ = try EditPlan.validatedID(step.key, field: "production step key")
            if let inputDigest = step.inputDigest {
                guard ProductionRun.validRevision(inputDigest) else {
                    throw EditPlanValidationError.invalidReference("Production step input digest must be a revision digest.")
                }
            }
            if let outputDigest = step.outputDigest {
                guard ProductionRun.validRevision(outputDigest) else {
                    throw EditPlanValidationError.invalidReference("Production step output digest must be a revision digest.")
                }
            }
            if let error = step.error {
                _ = try EditPlan.validatedText(error, field: "production step error")
            }
        }
        if let blockedReason {
            _ = try EditPlan.validatedText(blockedReason, field: "production blocked reason")
        }
        for review in visualReviews {
            _ = try EditPlan.validatedID(review.sceneId, field: "sceneId")
            guard ProductionRun.validRevision(review.selectionRevision),
                  !(try EditPlan.validatedName(review.reviewer)).isEmpty,
                  !(try EditPlan.validatedText(review.evidence, field: "visual review evidence")).isEmpty else {
                throw EditPlanValidationError.invalidReference("Visual review needs selection revision, reviewer, and inspection evidence.")
            }
        }
    }

    static func validRevision(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    var receipt: [String: Any] {
        var out: [String: Any] = ["runId": id, "phase": phase.rawValue,
                                  "storyboardRevision": storyboardRevision,
                                  "reviewedSceneIds": visualReviews.map(\.sceneId),
                                  "comment": comment,
                                  "reviewFindings": reviewFindings.map(\.receipt),
                                  "steps": steps.map(\.receipt),
                                  "deliveryVerified": terminalReceipt?.deliveryVerified ?? false]
        if let approvedRevision { out["approvedRevision"] = approvedRevision }
        if let exportJobId { out["exportJobId"] = exportJobId }
        if let exportPath { out["exportPath"] = exportPath }
        if let verifiedTimelineRevision { out["verifiedTimelineRevision"] = verifiedTimelineRevision }
        if let exportedTimelineRevision { out["exportedTimelineRevision"] = exportedTimelineRevision }
        if let blockedReason { out["blockedReason"] = blockedReason }
        if let terminalReceipt { out["terminalReceipt"] = Self.receipt(of: terminalReceipt) }
        return out
    }

    static func receipt(of receipt: ProductionRun.TerminalReceipt) -> [String: Any] {
        var out: [String: Any] = [
            "runId": receipt.runId, "phase": receipt.phase,
            "reviewedSceneIds": receipt.reviewedSceneIds,
            "comment": receipt.comment, "deliveryVerified": receipt.deliveryVerified,
        ]
        if let exportJobId = receipt.exportJobId { out["exportJobId"] = exportJobId }
        if let exportPath = receipt.exportPath { out["exportPath"] = exportPath }
        if let verified = receipt.verifiedTimelineRevision { out["verifiedTimelineRevision"] = verified }
        if let exported = receipt.exportedTimelineRevision { out["exportedTimelineRevision"] = exported }
        if !receipt.errors.isEmpty { out["errors"] = receipt.errors }
        return out
    }
}
