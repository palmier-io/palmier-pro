import Foundation

extension EditorViewModel {

    /// Applies a social-format caption template across all project captions in a single atomic undo transaction.
    @discardableResult
    func applyCaptionTemplate(
        templateId: String,
        format: SocialCaptionFormat? = nil,
        trackIndex: Int? = nil,
        clipIds: [String]? = nil
    ) throws -> CaptionTemplateApplyReceipt {
        guard let preset = CaptionStyles.preset(id: templateId) else {
            throw CaptionTemplateError.unknownTemplate(
                templateId,
                available: CaptionTemplateLibrary.availableIds()
            )
        }

        let template = CaptionTemplateLibrary.template(id: templateId)
        let canonicalId = template?.id ?? preset.id
        let resolvedFormat = format ?? template?.format ?? .all
        let centerY = template?.centerYRatio ?? resolvedFormat.safeCenterYRatio

        let canvasH = max(1, timeline.height)
        let resolved = preset.resolved(canvasHeight: canvasH)

        // Identify target text/caption clips
        var targetClipIds: Set<String> = []
        if let explicit = clipIds, !explicit.isEmpty {
            targetClipIds = Set(explicit)
        } else if let trackIdx = trackIndex {
            guard timeline.tracks.indices.contains(trackIdx) else {
                throw CaptionTemplateError.noCaptionsFound(templateName: template?.displayName ?? preset.displayName)
            }
            let trackClips = timeline.tracks[trackIdx].clips.filter { $0.mediaType == .text }.map(\.id)
            targetClipIds = Set(trackClips)
        } else {
            // Find all caption group text clips or text clips
            let captionClips = timeline.tracks.flatMap(\.clips).filter { $0.mediaType == .text && $0.captionGroupId != nil }
            if !captionClips.isEmpty {
                targetClipIds = Set(captionClips.map(\.id))
            } else {
                let allText = timeline.tracks.flatMap(\.clips).filter { $0.mediaType == .text }
                targetClipIds = Set(allText.map(\.id))
            }
        }

        guard !targetClipIds.isEmpty else {
            throw CaptionTemplateError.noCaptionsFound(templateName: template?.displayName ?? preset.displayName)
        }

        var updatedClipIds: [String] = []
        var affectedTrackIndices: Set<Int> = []

        let actionLabel = "Apply Caption Template '\(template?.displayName ?? preset.displayName)'"
        withTimelineSwap(actionName: actionLabel) {
            for trackIdx in timeline.tracks.indices {
                var trackHasTargetClip = false
                for clipIdx in timeline.tracks[trackIdx].clips.indices {
                    let clip = timeline.tracks[trackIdx].clips[clipIdx]
                    guard targetClipIds.contains(clip.id) else { continue }

                    timeline.tracks[trackIdx].clips[clipIdx].textStyle = resolved.style
                    timeline.tracks[trackIdx].clips[clipIdx].textAnimation = resolved.animation
                    timeline.tracks[trackIdx].clips[clipIdx].transform.centerY = centerY
                    if timeline.tracks[trackIdx].clips[clipIdx].opacity <= 0 {
                        timeline.tracks[trackIdx].clips[clipIdx].opacity = 1.0
                    }

                    updatedClipIds.append(clip.id)
                    affectedTrackIndices.insert(trackIdx)
                    trackHasTargetClip = true
                }
                if trackHasTargetClip && timeline.tracks[trackIdx].hidden {
                    timeline.tracks[trackIdx].hidden = false
                }
            }
        }

        selectedCaptionStyleId = canonicalId

        return CaptionTemplateApplyReceipt(
            templateId: canonicalId,
            templateName: template?.displayName ?? preset.displayName,
            format: resolvedFormat.rawValue,
            formatLabel: template?.formatLabel ?? resolvedFormat.displayName,
            appliedClipCount: updatedClipIds.count,
            updatedClipIds: updatedClipIds,
            trackIndices: affectedTrackIndices.sorted(),
            centerYRatio: centerY,
            undoable: true
        )
    }
}

