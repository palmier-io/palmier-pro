import SwiftUI

/// Track stack in paint order (top-most first) with visibility, mute, and reorder controls.
struct LayersTabView: View {
    @Environment(EditorViewModel.self) private var editor

    private var orderedIndices: [Int] { Array(editor.timeline.tracks.indices.reversed()) }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: AppTheme.Spacing.xxs) {
                ForEach(orderedIndices, id: \.self) { index in
                    row(index)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xs)
        }
    }

    private func row(_ index: Int) -> some View {
        let track = editor.timeline.tracks[index]
        let name = (track.name?.isEmpty == false ? track.name : nil) ?? defaultName(track.type)
        return HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: icon(track.type))
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.sm)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: name)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(track.hidden ? AppTheme.Text.mutedColor : AppTheme.Text.primaryColor)
                    .lineLimit(1)
                Text(verbatim: "\(track.clips.count) clips")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            Spacer(minLength: AppTheme.Spacing.xs)
            iconToggle(
                track.hidden ? "eye.slash" : "eye",
                isOn: !track.hidden,
                help: track.hidden ? L10n.string("Show Track") : L10n.string("Hide Track")
            ) { editor.toggleTrackHidden(trackIndex: index) }
            if track.type == .audio {
                iconToggle(
                    track.muted ? "speaker.slash" : "speaker.wave.2",
                    isOn: !track.muted,
                    help: track.muted ? L10n.string("Unmute Track") : L10n.string("Mute Track")
                ) { editor.toggleTrackMute(trackIndex: index) }
            }
            HStack(spacing: 2) {
                iconButton("chevron.up", help: L10n.string("Move Track Up"),
                           disabled: index >= editor.timeline.tracks.count - 1) {
                    editor.reorderTrackLive(id: track.id, to: index + 1)
                }
                iconButton("chevron.down", help: L10n.string("Move Track Down"), disabled: index == 0) {
                    editor.reorderTrackLive(id: track.id, to: index - 1)
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(AppTheme.Background.raisedColor.opacity(AppTheme.Opacity.subtle))
        )
        .contentShape(Rectangle())
        .onTapGesture { selectTrackClips(index) }
    }

    private func selectTrackClips(_ index: Int) {
        guard editor.timeline.tracks.indices.contains(index) else { return }
        editor.selectedClipIds = Set(editor.timeline.tracks[index].clips.map(\.id))
    }

    private func iconToggle(_ systemImage: String, isOn: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(isOn ? AppTheme.Text.secondaryColor : AppTheme.Text.mutedColor)
                .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(L10n.string(key: help))
    }

    private func iconButton(_ systemImage: String, help: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                .foregroundStyle(disabled ? AppTheme.Text.mutedColor : AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(L10n.string(key: help))
    }

    private func icon(_ type: ClipType) -> String {
        switch type {
        case .video: "film"
        case .audio: "waveform"
        case .image: "photo"
        case .text: "textformat"
        case .lottie: "sparkles"
        case .sequence: "square.stack.3d.up"
        default: "square"
        }
    }

    private func defaultName(_ type: ClipType) -> String {
        switch type {
        case .video: L10n.string("Video")
        case .audio: L10n.string("Audio")
        case .image: L10n.string("Image")
        case .text: L10n.string("Text")
        case .lottie: L10n.string("Lottie")
        case .sequence: L10n.string("Sequence")
        default: L10n.string("Track")
        }
    }
}
