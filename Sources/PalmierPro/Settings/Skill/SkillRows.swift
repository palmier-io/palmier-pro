import SwiftUI

enum SkillCommunityState: Equatable {
    case upToDate
    case update
    case modified

    var label: String {
        switch self {
        case .upToDate: "Community"
        case .update: "Update available"
        case .modified: "Modified"
        }
    }

    var color: Color {
        switch self {
        case .update: AppTheme.Accent.link
        case .modified: AppTheme.Status.warningColor
        case .upToDate: AppTheme.Text.tertiaryColor
        }
    }

    @MainActor
    static func resolve(
        _ skill: Skill,
        store: SkillStore,
        catalog: SkillCatalog
    ) -> SkillCommunityState? {
        guard let installedSHA = store.installed[skill.id] else { return nil }
        if store.localSha(skill) != installedSHA { return .modified }
        if let entry = catalog.entry(id: skill.id), entry.sha != installedSHA { return .update }
        return .upToDate
    }
}

struct SkillCollectionButton: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.sm) {
                L10n.text(title)
                Text(verbatim: count.formatted())
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.regular))
            .foregroundStyle(isSelected ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
            .padding(.horizontal, AppTheme.Spacing.mdLg)
            .padding(.vertical, AppTheme.Spacing.sm)
            .hoverHighlight(
                cornerRadius: AppTheme.Radius.xl,
                isActive: isSelected,
                activeFill: AppTheme.Background.raisedColor
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.format("%@, %d skills", L10n.string(title), count))
    }
}

struct SkillRow: View {
    let name: String
    let description: String
    let status: String
    let statusColor: Color
    let actionTitle: String
    let working: Bool
    var summaryAction: (() -> Void)? = nil
    let action: () -> Void

    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            summary
                .frame(maxWidth: .infinity)

            L10n.text(status)
                .font(.system(size: AppTheme.FontSize.smMd))
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .frame(width: AppTheme.Settings.skillStatusWidth, alignment: .trailing)

            Group {
                if working {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(L10n.format("Working on %@", name))
                } else {
                    Button(action: action) {
                        L10n.text(actionTitle)
                    }
                        .buttonStyle(.capsule(
                            actionTitle == "Install" ? .prominent : .secondary,
                            fill: actionTitle == "Install" ? nil : AnyShapeStyle(AppTheme.Background.raisedColor)
                        ))
                }
            }
            .frame(width: AppTheme.Settings.skillActionWidth, alignment: .trailing)
        }
        .padding(.horizontal, AppTheme.Spacing.smMd)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .hoverHighlight(cornerRadius: AppTheme.Radius.md)
    }

    @ViewBuilder
    private var summary: some View {
        if let summaryAction {
            Button(action: summaryAction) {
                SkillRowSummary(name: name, description: description)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.format("Open %@", name))
        } else {
            SkillRowSummary(name: name, description: description)
        }
    }
}

private struct SkillRowSummary: View {
    let name: String
    let description: String

    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            SkillRowIcon()
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(verbatim: name)
                    .font(.system(size: AppTheme.FontSize.mdLg, weight: AppTheme.FontWeight.regular))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                Text(verbatim: description)
                    .font(.system(size: AppTheme.FontSize.smMd))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .lineLimit(1)
            }
            Spacer(minLength: AppTheme.Spacing.md)
        }
    }
}

struct SkillEmptyState: View {
    let systemName: String
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: AppTheme.Spacing.smMd) {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.FontSize.xl))
                .foregroundStyle(AppTheme.Text.mutedColor)
                .accessibilityHidden(true)
            L10n.text(title)
                .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.regular))
                .foregroundStyle(AppTheme.Text.primaryColor)
            L10n.text(message)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: action) {
                L10n.text(actionTitle)
            }
                .buttonStyle(.capsule(.secondary, fill: AnyShapeStyle(AppTheme.Background.raisedColor)))
        }
        .frame(maxWidth: .infinity)
        .padding(AppTheme.Spacing.xlXxl)
    }
}

private struct SkillRowIcon: View {
    var body: some View {
        Image(systemName: "book.closed")
            .font(.system(size: AppTheme.FontSize.md))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
            .frame(
                width: AppTheme.Settings.skillRowIconFrame,
                height: AppTheme.Settings.skillRowIconFrame
            )
            .overlay(
                Circle()
                    .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
            )
            .accessibilityHidden(true)
    }
}
