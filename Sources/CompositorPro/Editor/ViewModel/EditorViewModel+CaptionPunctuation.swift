import Foundation

extension EditorViewModel {
    enum CaptionPunctuationError: Error {
        case missingClip(String)
        case captionRequired(String)
    }

    @discardableResult
    func cleanCaptionPunctuation(clipIds: [String]) throws(CaptionPunctuationError) -> [String] {
        var targets: [Clip] = []
        var seen: Set<String> = []
        for id in clipIds {
            guard let clip = clipFor(id: id) else { throw .missingClip(id) }
            guard clip.mediaType == .text, clip.captionGroupId != nil else { throw .captionRequired(id) }
            if seen.insert(clip.id).inserted { targets.append(clip) }
        }
        let changedIds = targets.compactMap { clip -> String? in
            let content = clip.textContent.map { CaptionPunctuation.normalized($0) }
            let words = CaptionPunctuation.normalized(clip.wordTimings)
            return content != clip.textContent || words != clip.wordTimings ? clip.id : nil
        }
        guard !changedIds.isEmpty else { return [] }
        undo.perform(L10n.string("Remove Trailing Caption Commas")) {
            commitClipProperties(clipIds: changedIds) { clip in
                clip.textContent = clip.textContent.map { CaptionPunctuation.normalized($0) }
                clip.wordTimings = CaptionPunctuation.normalized(clip.wordTimings)
            }
        }
        return changedIds
    }
}
