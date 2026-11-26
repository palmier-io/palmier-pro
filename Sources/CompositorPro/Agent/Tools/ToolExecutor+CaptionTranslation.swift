import Foundation

extension ToolExecutor {
    private struct CaptionTranslationInput: DecodableToolArgs {
        let action: String?
        let targetLanguage: String?
        let jobId: String?
        let planId: String?
        let captionStyle: String?
        let beats: [CaptionTranslationInputBeat]?
        let customTranslations: [String: String]?
        let segmentId: String?
        let translatedText: String?
        let startFrame: Int?
        let endFrame: Int?
        let isApproved: Bool?
        let approveAll: Bool?
        let trackIndex: Int?
        let trackName: String?

        static let allowedKeys: Set<String> = [
            "action", "targetLanguage", "jobId", "planId", "captionStyle",
            "beats", "customTranslations", "segmentId", "translatedText",
            "startFrame", "endFrame", "isApproved", "approveAll",
            "trackIndex", "trackName",
        ]
    }

    /// Handles the translate_captions tool: script beats → multilingual captions → review → timeline.
    func translateCaptions(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: CaptionTranslationInput = try decodeToolArgs(args, path: "translate_captions")
        guard let rawAction = input.action, let action = CaptionTranslationAction(rawValue: rawAction) else {
            let valid = ["translate", "read", "review", "approve_all", "apply"].joined(separator: ", ")
            throw ToolError("translate_captions requires a valid action: \(valid).")
        }

        switch action {
        case .translate:
            guard let targetLang = input.targetLanguage?.trimmingCharacters(in: .whitespacesAndNewlines), !targetLang.isEmpty else {
                throw ToolError("translate_captions translate action requires a non-empty targetLanguage (e.g. 'es', 'fr', 'de', 'ja').")
            }
            do {
                let job = try await editor.translateCaptions(
                    targetLanguage: targetLang,
                    planId: input.planId,
                    beats: input.beats,
                    captionStyle: input.captionStyle,
                    customTranslations: input.customTranslations
                )
                let data = try JSONEncoder().encode(job)
                return .ok(String(decoding: data, as: UTF8.self))
            } catch let err as CaptionTranslationError {
                throw ToolError(err.localizedDescription)
            }

        case .read:
            guard let jobId = input.jobId, !jobId.isEmpty else {
                throw ToolError("translate_captions read action requires jobId.")
            }
            guard let job = editor.captionTranslationJobs[jobId] else {
                throw ToolError("Caption translation job '\(jobId)' not found.")
            }
            let data = try JSONEncoder().encode(job)
            return .ok(String(decoding: data, as: UTF8.self))

        case .review:
            guard let jobId = input.jobId, !jobId.isEmpty else {
                throw ToolError("translate_captions review action requires jobId.")
            }
            if input.approveAll == true {
                do {
                    let job = try editor.approveAllTranslatedCaptionSegments(jobId: jobId)
                    let data = try JSONEncoder().encode(job)
                    return .ok(String(decoding: data, as: UTF8.self))
                } catch let err as CaptionTranslationError {
                    throw ToolError(err.localizedDescription)
                }
            }
            guard let segId = input.segmentId, !segId.isEmpty else {
                throw ToolError("translate_captions review action requires segmentId or approveAll: true.")
            }
            do {
                let job = try editor.reviewTranslatedCaptionSegment(
                    jobId: jobId,
                    segmentId: segId,
                    translatedText: input.translatedText,
                    startFrame: input.startFrame,
                    endFrame: input.endFrame,
                    isApproved: input.isApproved
                )
                let data = try JSONEncoder().encode(job)
                return .ok(String(decoding: data, as: UTF8.self))
            } catch let err as CaptionTranslationError {
                throw ToolError(err.localizedDescription)
            }

        case .approveAll:
            guard let jobId = input.jobId, !jobId.isEmpty else {
                throw ToolError("translate_captions approve_all action requires jobId.")
            }
            do {
                let job = try editor.approveAllTranslatedCaptionSegments(jobId: jobId)
                let data = try JSONEncoder().encode(job)
                return .ok(String(decoding: data, as: UTF8.self))
            } catch let err as CaptionTranslationError {
                throw ToolError(err.localizedDescription)
            }

        case .apply:
            guard let jobId = input.jobId, !jobId.isEmpty else {
                throw ToolError("translate_captions apply action requires jobId.")
            }
            do {
                let receipt = try editor.applyTranslatedCaptions(
                    jobId: jobId,
                    trackIndex: input.trackIndex,
                    trackName: input.trackName
                )
                let data = try JSONEncoder().encode(receipt)
                return .ok(String(decoding: data, as: UTF8.self))
            } catch let err as CaptionTranslationError {
                throw ToolError(err.localizedDescription)
            }
        }
    }
}

