import SwiftUI

struct MulticamTab: View {
    @Environment(EditorViewModel.self) var editor
    let groupId: String
    @Bindable private var timelineColors = TimelineClipColorStore.shared

    var body: some View {
        let _ = timelineColors.revision

        if let group = editor.multicamGroup(id: groupId) {
            EditorPanelGroup(group.name.isEmpty ? L10n.string("Multicam") : group.name) {
                ForEach(group.members) { member in
                    memberRow(member, group: group)
                }
            }
        }
    }

    private func memberRow(_ member: MulticamSource.Member, group: MulticamSource) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(localizedKind(member.kind))
                .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(Color(AppTheme.TrackColor.readableForeground(on: kindColor(member.kind))).opacity(AppTheme.Opacity.prominent))
                .padding(.horizontal, AppTheme.Spacing.xs)
                .padding(.vertical, AppTheme.Spacing.xxs)
                .background(Color(kindColor(member.kind)), in: RoundedRectangle(cornerRadius: AppTheme.Radius.xs))

            Text(member.angleLabel)
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                .lineLimit(1)

            if member.id == group.masterMemberId {
                Image(systemName: "star.fill")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Accent.timecodeColor)
                    .help(L10n.string("Master — defines the group's clock and transcript."))
            }

            Spacer(minLength: AppTheme.Spacing.sm)

            if member.usable {
                Text(verbatim: String(format: "%+.2fs · %.0f%%", member.sync.offsetSeconds, member.sync.confidence * 100))
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .help(L10n.string("Starts \(String(format: "%.2f", member.sync.offsetSeconds))s into the group's clock; matched the master with \(String(format: "%.0f", member.sync.confidence * 100))% confidence."))
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .help(L10n.string("Not synced — unusable as an angle."))
            }
        }
    }

    private func localizedKind(_ kind: MulticamSource.MemberKind) -> String {
        switch kind {
        case .angle: L10n.string("Angle")
        case .mic: L10n.string("Mic")
        case .both: L10n.string("Both")
        }
    }

    private func kindColor(_ kind: MulticamSource.MemberKind) -> NSColor {
        switch kind {
        case .angle: AppTheme.TrackColor.video
        case .mic: AppTheme.TrackColor.audio
        case .both: AppTheme.TrackColor.multicam
        }
    }
}
