import SwiftUI

// Group overview: kind, offset, sync, master, mute.
struct MulticamInspectorSection: View {
    @Environment(EditorViewModel.self) var editor
    let childId: String

    var body: some View {
        if let (child, source) = editor.multicamChild(id: childId) {
            InspectorSection("Multicam") {
                ForEach(source.members) { member in
                    memberRow(member, source: source, child: child)
                }
            }
        }
    }

    private func memberRow(_ member: MulticamSource.Member, source: MulticamSource, child: Timeline) -> some View {
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

            if member.id == source.masterMemberId {
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
                    .help("Starts \(String(format: "%.2f", member.sync.offsetSeconds))s into the group's clock; audio matched the master with \(String(format: "%.0f", member.sync.confidence * 100))% confidence.")
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .help("Not synced — unusable as an angle.")
            }

            if member.providesAudio {
                let muted = editor.multicamMemberMuted(child: child, member: member)
                Button {
                    editor.setMulticamMemberMuted(childId: childId, memberId: member.id, muted: !muted)
                } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(muted ? AppTheme.Status.errorColor : AppTheme.Text.secondaryColor)
                }
                .buttonStyle(.plain)
                .help(muted ? "Unmute this mic" : "Mute this mic")
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
