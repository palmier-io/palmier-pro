import SwiftUI

/// Scrollable list of AI generations for the current project.
struct ProjectActivityView: View {
    let entries: [GenerationLogEntry]

    private var total: Double {
        entries.reduce(0) { $0 + ($1.cost ?? 0) }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack {
                Text("Project Activity")
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Spacer()
                if !entries.isEmpty {
                    Text("\(CostEstimator.format(total)) used")
                        .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }

            if entries.isEmpty {
                Text("No generations yet")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, AppTheme.Spacing.sm)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(entries) { entry in
                            row(entry)
                        }
                    }
                }
                .frame(maxHeight: 420)
            }
        }
        .padding(AppTheme.Spacing.md)
        .frame(width: 340)
    }

    private func row(_ entry: GenerationLogEntry) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: entry.sfSymbolName)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: 14)
            Text(CostEstimator.format(entry.cost))
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: 54, alignment: .leading)
            Text(entry.modelDisplayName)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: AppTheme.Spacing.xs)
            Text(relativeTime(entry.createdAt))
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.mutedColor)
                .lineLimit(1)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 2)
    }

    private func relativeTime(_ date: Date?) -> String {
        guard let date else { return "—" }
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

struct ProjectActivityButton: View {
    @Environment(EditorViewModel.self) var editor
    @State private var isPresented = false

    var body: some View {
        Button(action: { isPresented.toggle() }) {
            Image(systemName: "dollarsign.circle")
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: 26, height: 26)
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .help("Project Activity — \(CostEstimator.format(editor.totalGenerationCost)) used")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ProjectActivityView(entries: editor.generationLogEntries)
        }
    }
}
