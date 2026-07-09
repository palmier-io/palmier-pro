import SwiftUI

struct MulticamTab: View {
    @Environment(EditorViewModel.self) var editor
    let groupId: String

    var body: some View {
        if let group = editor.multicamGroup(id: groupId) {
            InspectorSection(group.name.isEmpty ? "Multicam" : group.name) {
                ForEach(group.members) { member in
                    memberRow(member, group: group)
                }
            }
        }
    }

    private func memberRow(_ member: MulticamSource.Member, group: MulticamSource) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(member.kind.rawValue.uppercased())
                .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.bold))
                .foregroundStyle(.black.opacity(AppTheme.Opacity.prominent))
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
                    .help("Master — defines the group's clock and transcript.")
            }

            Spacer(minLength: AppTheme.Spacing.sm)

            if member.usable {
                Text(String(format: "%+.2fs · %.0f%%", member.sync.offsetSeconds, member.sync.confidence * 100))
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .help("Starts \(String(format: "%.2f", member.sync.offsetSeconds))s into the group's clock; matched the master with \(String(format: "%.0f", member.sync.confidence * 100))% confidence.")
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .help("Not synced — unusable as an angle.")
            }
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
