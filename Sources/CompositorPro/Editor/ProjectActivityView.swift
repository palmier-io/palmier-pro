import Combine
import SwiftUI

/// Backend-owned activity for the current project.
struct ProjectActivityView: View {
    let projectId: String?

    private static let listHeight: CGFloat = 420

    @State private var entries: [BackendProjectActivityEntry] = []
    @State private var isLoading = true
    @State private var unavailableMessage: String?

    private var total: Int {
        entries.reduce(0) { $0 + $1.creditImpact }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = AppLocalization.shared.activeLocale
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack {
                Text(L10n.string("Project Activity"))
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Spacer()
                if !entries.isEmpty {
                    Text(CostEstimator.localizedUsedCredits(total))
                        .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }

            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, AppTheme.Spacing.sm)
                } else if let unavailableMessage {
                    Text(unavailableMessage)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .padding(.vertical, AppTheme.Spacing.sm)
                } else if entries.isEmpty {
                    Text(L10n.string("No generations yet"))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .padding(.vertical, AppTheme.Spacing.sm)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                            ForEach(entries) { entry in
                                row(entry)
                            }
                        }
                    }
                }
            }
            .frame(height: Self.listHeight, alignment: .topLeading)
        }
        .padding(AppTheme.Spacing.md)
        .frame(width: 340)
        .task(id: projectId) {
            await subscribe()
        }
    }

    private func row(_ entry: BackendProjectActivityEntry) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: symbolName(for: entry))
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(entryColor(entry, fallback: AppTheme.Text.tertiaryColor))
                .frame(width: AppTheme.IconSize.xs)
            Text(creditLabel(entry))
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(entryColor(entry, fallback: AppTheme.Text.secondaryColor))
                .frame(width: 68, alignment: .leading)
            Text(ModelRegistry.displayName(for: entry.model))
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: AppTheme.Spacing.xs)
            Text(Self.relativeFormatter.localizedString(for: entry.createdDate, relativeTo: Date()))
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.mutedColor)
                .lineLimit(1)
        }
        .padding(.vertical, AppTheme.Spacing.xs)
        .padding(.horizontal, AppTheme.Spacing.xxs)
    }

    private func symbolName(for entry: BackendProjectActivityEntry) -> String {
        if entry.kind == .refund { return "arrow.uturn.backward.circle.fill" }
        return switch ModelRegistry.byId[entry.model] {
        case .video?:   "video.fill"
        case .image?:   "photo.fill"
        case .audio?:   "music.note"
        case .upscale?: "arrow.up.right.square.fill"
        case nil:       "sparkles"
        }
    }

    private func entryColor(_ entry: BackendProjectActivityEntry, fallback: Color) -> Color {
        switch entry.kind {
        case .generation: fallback
        case .failed: AppTheme.Status.errorColor
        case .refund: AppTheme.Status.successColor
        }
    }

    private func creditLabel(_ entry: BackendProjectActivityEntry) -> String {
        entry.kind == .refund
            ? L10n.string("\(entry.credits) credits refunded")
            : CostEstimator.localizedDescription(entry.credits)
    }

    @MainActor
    private func subscribe() async {
        entries = []
        unavailableMessage = nil
        isLoading = true

        guard let projectId else {
            isLoading = false
            unavailableMessage = L10n.string("Save this project to view activity")
            return
        }
        guard let publisher = GenerationBackend.subscribeToProjectActivity(projectId: projectId) else {
            isLoading = false
            unavailableMessage = L10n.string("Activity unavailable")
            return
        }

        do {
            for try await update in publisher.values {
                guard !Task.isCancelled else { return }
                entries = update
                isLoading = false
            }
            guard !Task.isCancelled else { return }
            if isLoading {
                isLoading = false
                unavailableMessage = L10n.string("Activity unavailable")
            }
        } catch {
            guard !Task.isCancelled else { return }
            Log.generation.warning("project activity failed: \(error.localizedDescription)")
            isLoading = false
            unavailableMessage = L10n.string("Activity unavailable")
        }
    }
}

struct ProjectActivityButton: View {
    @Environment(EditorViewModel.self) var editor
    @State private var isPresented = false

    private var projectId: String? {
        editor.projectId ?? editor.projectURL.flatMap { ProjectRegistry.shared.id(for: $0)?.uuidString }
    }

    var body: some View {
        Button(action: { isPresented.toggle() }) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .help(L10n.string("Project Activity"))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ProjectActivityView(projectId: projectId)
        }
    }
}
