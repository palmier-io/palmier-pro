import CoreGraphics
import Foundation

extension EditorViewModel {
    struct TextStyleReceipt {
        var clipIds: [String]
        var styledCount: Int
        /// Clips that could not be styled, with why.
        var skipped: [String]
    }

    enum TextStyleError: Error, Equatable, CustomStringConvertible {
        case noClips
        case notText(String)
        case unknownClip(String)

        var description: String {
            switch self {
            case .noClips: "No clips to style."
            case .notText(let id): "'\(id)' is not a text clip."
            case .unknownClip(let id): "No clip '\(id)'."
            }
        }
    }

    /// Restyles text clips as one undoable step.
    ///
    /// One `commitClipProperties` call covers the whole selection, so a caption track restyled as a
    /// unit is a single step rather than one per cue. `position` is applied only when asked:
    /// repositioning text someone has already placed is a separate decision.
    func applyTextStyle(
        clipIds: [String],
        style: TextStyle,
        position: CGPoint?
    ) throws -> TextStyleReceipt {
        guard !clipIds.isEmpty else { throw TextStyleError.noClips }

        var resolved: [String] = []
        var skipped: [String] = []
        for id in clipIds {
            guard let clip = clipFor(id: id) else {
                skipped.append("\(id): no such clip.")
                continue
            }
            guard clip.mediaType == .text else {
                skipped.append("\(id): not a text clip.")
                continue
            }
            resolved.append(id)
        }
        guard !resolved.isEmpty else { throw TextStyleError.noClips }

        let before = resolved.compactMap { clipFor(id: $0) }
        commitClipProperties(clipIds: resolved, actionName: "Apply Text Style") { clip in
            clip.textStyle = style
            if let position {
                clip.transform = Transform(
                    centerX: position.x, centerY: position.y,
                    width: clip.transform.width, height: clip.transform.height
                )
            }
        }
        // A commit that changed nothing must not leave an undo entry behind.
        let after = resolved.compactMap { clipFor(id: $0) }
        let styled = zip(before, after).reduce(into: 0) { count, pair in
            if pair.0.textStyle != pair.1.textStyle
                || (position != nil && pair.0.transform.centerY != pair.1.transform.centerY) {
                count += 1
            }
        }
        return TextStyleReceipt(clipIds: resolved, styledCount: styled, skipped: skipped)
    }
}