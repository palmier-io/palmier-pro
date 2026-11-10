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

    var id: String = UUID().uuidString
    var phase: Phase = .awaitingStoryboardApproval
    var storyboardRevision: String
    var approvedRevision: String?
    var visualReviews: [VisualReview] = []
    var comment: String = ""
    var exportJobId: String?
    var exportPath: String?
    var terminalReceipt: TerminalReceipt?

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

    func validate() throws {
        let isPastApproval = phase != .awaitingStoryboardApproval && phase != .stale && phase != .canceled
        guard UUID(uuidString: id) != nil, Self.validRevision(storyboardRevision),
              approvedRevision.map(Self.validRevision) ?? true,
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
        for review in visualReviews {
            _ = try EditPlan.validatedID(review.sceneId, field: "sceneId")
            guard Self.validRevision(review.selectionRevision),
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
                                  "deliveryVerified": terminalReceipt?.deliveryVerified ?? false]
        if let approvedRevision { out["approvedRevision"] = approvedRevision }
        if let exportJobId { out["exportJobId"] = exportJobId }
        if let exportPath { out["exportPath"] = exportPath }
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
        if !receipt.errors.isEmpty { out["errors"] = receipt.errors }
        return out
    }
}
