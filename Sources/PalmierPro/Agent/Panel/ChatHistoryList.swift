import SwiftUI

struct ChatHistoryList: View {
    let sessions: [ChatSession]
    let currentId: UUID?
    let onSelect: (UUID) -> Void
    let onDelete: (UUID) -> Void

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if sessions.isEmpty {
                Text("No chat history")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .padding(AppTheme.Spacing.md)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sessions) { session in
                            row(session: session)
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 280)
        .glassEffect(.clear, in: .rect(cornerRadius: AppTheme.Radius.md))
    }

    private func row(session: ChatSession) -> some View {
        let isCurrent = session.id == currentId
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(session.title)
                        .font(.system(size: AppTheme.FontSize.xs, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .lineLimit(1)
                    if !session.isOpen {
                        Text("closed")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(AppTheme.Text.mutedColor)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(Color.white.opacity(0.06))
                            )
                    }
                }
                Text(Self.formatter.localizedString(for: session.updatedAt, relativeTo: Date()))
                    .font(.system(size: 9))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            Spacer()
            if !isCurrent {
                Button { onDelete(session.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Delete from history")
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, 6)
        .background(isCurrent ? Color.accentColor.opacity(0.15) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(session.id) }
    }
}
