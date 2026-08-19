import SwiftUI

struct TimelineKeyframeLaneHeaderControl: View {
    let editor: EditorViewModel
    let trackId: String
    let property: AnimatableProperty

    private var target: Clip? {
        editor.keyframeLaneTarget(trackId: trackId, property: property)
    }

    var body: some View {
        let clip = target
        HStack(spacing: AppTheme.Spacing.xxs) {
            Text(L10n.string(key: property.displayName))
                .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)
            Spacer(minLength: AppTheme.Spacing.xxs)
            KeyframePropertyValueFields(
                clips: clip.map { [$0] } ?? [],
                property: property,
                style: .timeline
            )
            .disabled(clip == nil)
            .opacity(clip == nil ? AppTheme.Opacity.strong : AppTheme.Opacity.opaque)
            keyframeControls(for: clip)
        }
        .padding(.leading, AppTheme.ComponentSize.timelineTrackHeaderReorderLeadingInset)
        .padding(.trailing, AppTheme.Spacing.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Background.baseColor)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.Border.subtleColor)
                .frame(height: AppTheme.BorderWidth.thin)
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(AppTheme.Accent.timecodeColor)
                .frame(width: AppTheme.ComponentSize.timelineTrackHeaderColorStripWidth)
        }
        .environment(editor)
    }

    private func keyframeControls(for clip: Clip?) -> some View {
        let frame = editor.activeFrame
        let navigation = editor.keyframeLaneNavigationTargets(
            trackId: trackId,
            property: property,
            around: frame
        )
        let onKeyframe = clip.map {
            editor.hasKeyframe(clipId: $0.id, property: property, at: frame)
        } ?? false
        return KeyframeControlStrip(
            previousAction: navigation.previous.map { destination in
                { navigate(to: destination) }
            },
            keyframeAction: clip.map { clip in
                {
                    editor.toggleKeyframe(
                        clipId: clip.id,
                        property: property,
                        at: frame
                    )
                }
            },
            nextAction: navigation.next.map { destination in
                { navigate(to: destination) }
            },
            isOnKeyframe: onKeyframe,
            hasKeyframes: clip?.hasActiveKeyframes(for: property) == true,
            unavailableKeyframeHelp: L10n.string("Move playhead inside the clip")
        )
    }

    private func navigate(to destination: KeyframeLaneNavigationTarget) {
        editor.selectedGap = nil
        editor.selectedClipIds = [destination.clipId]
        editor.seekToFrame(destination.frame)
    }
}
