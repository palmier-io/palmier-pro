import Foundation

/// One entry in the command palette and the keyboard map.
struct AppCommand: Identifiable, Sendable, Equatable {
    enum ID: String, CaseIterable, Sendable {
        case fitTimeline
        case zoomSelection
        case toggleRipple
        case toggleLinkedSelection
        case splitAtPlayhead
        case addMarker
        case togglePlayback
        case clearSelection
        case nudgeKeyframesLeft
        case nudgeKeyframesRight
        case removeKeyframes
    }

    let id: ID
    let titleKey: String
    let shortcut: String
    let systemImage: String
}

@MainActor
enum CommandRegistry {
    static let commands: [AppCommand] = [
        .init(id: .fitTimeline, titleKey: "Zoom Timeline to Fit", shortcut: "⌘0", systemImage: "arrow.left.and.right"),
        .init(id: .zoomSelection, titleKey: "Zoom to Selection", shortcut: "⇧⌘9", systemImage: "arrow.left.and.right.square"),
        .init(id: .toggleRipple, titleKey: "Toggle Ripple Editing", shortcut: "", systemImage: "arrow.triangle.2.circlepath"),
        .init(id: .toggleLinkedSelection, titleKey: "Toggle Linked Selection", shortcut: "", systemImage: "link"),
        .init(id: .splitAtPlayhead, titleKey: "Split at Playhead", shortcut: "⌘K", systemImage: "square.split.2x1"),
        .init(id: .addMarker, titleKey: "Add Marker", shortcut: "M", systemImage: "flag"),
        .init(id: .togglePlayback, titleKey: "Play/Pause", shortcut: "Space", systemImage: "playpause"),
        .init(id: .clearSelection, titleKey: "Deselect All", shortcut: "Esc", systemImage: "xmark.circle"),
        .init(id: .nudgeKeyframesLeft, titleKey: "Nudge Keyframes Left", shortcut: "⌥←", systemImage: "diamond.arrow.left"),
        .init(id: .nudgeKeyframesRight, titleKey: "Nudge Keyframes Right", shortcut: "⌥→", systemImage: "diamond.arrow.right"),
        .init(id: .removeKeyframes, titleKey: "Remove Keyframes at Playhead", shortcut: "", systemImage: "diamond.slash"),
    ]

    /// Case- and diacritic-insensitive search over titles and ids.
    static func matches(_ query: String) -> [AppCommand] {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return commands }
        return commands.filter {
            $0.titleKey.range(of: key, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || $0.id.rawValue.range(of: key, options: [.caseInsensitive]) != nil
        }
    }

    static func perform(_ id: AppCommand.ID, editor: EditorViewModel) {
        switch id {
        case .fitTimeline: editor.zoomToFitTimeline()
        case .zoomSelection: editor.zoomToSelection()
        case .toggleRipple: editor.rippleEditingEnabled.toggle()
        case .toggleLinkedSelection: editor.linkedSelectionEnabled.toggle()
        case .splitAtPlayhead: editor.splitAtPlayhead()
        case .addMarker: _ = editor.addTimelineMarkerAtSelection()
        case .togglePlayback: editor.togglePlayback()
        case .clearSelection: editor.clearTimelineSelection()
        case .nudgeKeyframesLeft: _ = editor.nudgeSelectedKeyframes(at: editor.activeFrame, by: -1)
        case .nudgeKeyframesRight: _ = editor.nudgeSelectedKeyframes(at: editor.activeFrame, by: 1)
        case .removeKeyframes: _ = editor.removeSelectedKeyframes(at: editor.activeFrame)
        }
    }
}
