import SwiftUI

struct ChatHistoryList: View {
    let sessions: [ChatSession]
    let currentId: UUID?
    var runningIDs: Set<UUID> = []
    let onSelect: (UUID) -> Void
    let onDelete: (UUID) -> Void
    @State private var query = ""

    private var filteredSessions: [ChatSession] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? sessions : sessions.filter { $0.title.localizedStandardContains(query) }
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            HStack {
                Text(L10n.string("Chat history"))
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Spacer(minLength: AppTheme.Spacing.zero)
                Text(verbatim: String(sessions.count))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
            HStack(spacing: AppTheme.Spacing.smMd) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppTheme.Text.mutedColor)
                TextField(L10n.string("Search conversations"), text: $query)
                    .textFieldStyle(.plain)
            }
            .font(.system(size: AppTheme.FontSize.smMd))
            .padding(AppTheme.Spacing.smMd)
            .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))

            if filteredSessions.isEmpty {
                Text(sessions.isEmpty ? L10n.string("No conversations yet") : L10n.string("No matching conversations"))
                    .font(.system(size: AppTheme.FontSize.smMd))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .padding(.vertical, AppTheme.Spacing.xl)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        ForEach(filteredSessions) { session in
                            row(session: session)
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(maxHeight: AppTheme.Chat.historyMaxHeight)
            }
        }
        .padding(AppTheme.Spacing.mdLg)
        .frame(width: AppTheme.Chat.historyWidth)
        .background(AppTheme.Background.baseColor)
    }

    private func row(session: ChatSession) -> some View {
        let isCurrent = session.id == currentId
        let isRunning = runningIDs.contains(session.id)
        return HStack(spacing: AppTheme.Spacing.smMd) {
            Button { onSelect(session.id) } label: {
                HStack(spacing: AppTheme.Spacing.smMd) {
                    Image(systemName: isRunning ? "circle.fill" : "bubble.left")
                        .font(.system(size: isRunning ? AppTheme.FontSize.micro : AppTheme.FontSize.smMd))
                        .foregroundStyle(isRunning ? AppTheme.Accent.primary : AppTheme.Text.mutedColor)
                        .frame(width: AppTheme.IconSize.sm)
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text(verbatim: session.title == "New chat" ? L10n.string("New chat") : session.title)
                            .font(.system(size: AppTheme.FontSize.smMd, weight: isCurrent ? AppTheme.FontWeight.semibold : AppTheme.FontWeight.medium))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                            .lineLimit(1)
                        Text(verbatim: Self.formatter.localizedString(for: session.updatedAt, relativeTo: Date()))
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                    Spacer(minLength: AppTheme.Spacing.zero)
                    if isCurrent {
                        Image(systemName: "checkmark")
                            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                            .foregroundStyle(AppTheme.Accent.primary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AppTheme.Spacing.smMd)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
            .hoverHighlight(cornerRadius: AppTheme.Radius.sm)

            if !isCurrent {
                Button { onDelete(session.id) } label: {
                    Image(systemName: "trash")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
                        .contentShape(Rectangle())
                        .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .accessibilityLabel(L10n.string("Delete from history"))
                .help(L10n.string("Delete from history"))
            }
        }
        .background(isCurrent ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.faint) : .clear,
                    in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
    }
}
