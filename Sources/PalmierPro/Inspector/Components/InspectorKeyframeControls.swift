import SwiftUI

struct InspectorKeyframePropertyControl: View {
    let clips: [Clip]
    let property: AnimatableProperty

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            KeyframePropertyValueFields(
                clips: clips,
                property: property,
                style: .inspector
            )
            InspectorKeyframeControls(
                clipId: clips.count == 1 ? clips[0].id : nil,
                property: property
            )
        }
    }
}

struct InspectorKeyframeControls: View {
    let clipId: String?
    let property: AnimatableProperty

    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        if let clipId {
            controls(clipId: clipId)
        } else {
            Color.clear.frame(width: KeyframeControlStrip.width)
        }
    }

    private func controls(clipId: String) -> some View {
        let frame = editor.activeFrame
        let clip = editor.clipFor(id: clipId)
        let inRange = clip?.contains(timelineFrame: frame) == true
        let frames = clip?.keyframeFrames(for: property) ?? []
        let previous = frames.filter { $0 < frame }.max()
        let next = frames.filter { $0 > frame }.min()
        return KeyframeControlStrip(
            previousAction: previous.map { target in
                { editor.seekToFrame(target) }
            },
            keyframeAction: inRange
                ? {
                editor.toggleKeyframe(
                    clipId: clipId,
                    property: property,
                    at: frame
                )
            }
                : nil,
            nextAction: next.map { target in
                { editor.seekToFrame(target) }
            },
            isOnKeyframe: frames.contains(frame),
            hasKeyframes: clip?.hasActiveKeyframes(for: property) == true,
            unavailableKeyframeHelp: L10n.string("Move playhead inside the clip")
        )
    }
}
