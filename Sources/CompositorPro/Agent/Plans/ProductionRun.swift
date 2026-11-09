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
                                  "comment": comment, "deliveryVerified": false]
        if let approvedRevision { out["approvedRevision"] = approvedRevision }
        return out
    }
}
