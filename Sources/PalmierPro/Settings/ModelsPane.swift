import SwiftUI

struct ModelsPane: View {
    enum Scope: Equatable {
        case all
        case visual
        case audio
    }

    let scope: Scope

    private var prefs = ModelPreferences.shared
    private var catalog = ModelCatalog.shared
    @Bindable private var openRouter = OpenRouterService.shared

    @State private var query = ""

    init(scope: Scope = .all) {
        self.scope = scope
    }

    private struct Row: Identifiable {
        let id: String
        let displayName: String
        let detail: String
    }

    private struct ModelSection: Identifiable {
        let id: String
        let title: String
        let rows: [Row]
    }

    private var sections: [ModelSection] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        func filtered(_ rows: [Row]) -> [Row] {
            q.isEmpty ? rows : rows.filter {
                $0.displayName.lowercased().contains(q)
                    || $0.detail.lowercased().contains(q)
                    || $0.id.lowercased().contains(q)
            }
        }
        var sections: [ModelSection] = []
        if scope == .all || scope == .visual {
            sections.append(contentsOf: [
                ModelSection(id: "palmier-image", title: "Palmier Image",
                             rows: filtered(catalog.image.map { Row(id: $0.id, displayName: $0.displayName, detail: "Palmier") })),
                ModelSection(id: "palmier-video", title: "Palmier Video",
                             rows: filtered(catalog.video.map { Row(id: $0.id, displayName: $0.displayName, detail: "Palmier") })),
                ModelSection(id: "openrouter-image", title: "OpenRouter Image",
                             rows: filtered(openRouter.image.map {
                                 Row(id: OpenRouterModelId.stored($0.id), displayName: $0.displayName, detail: $0.id)
                             })),
                ModelSection(id: "openrouter-video", title: "OpenRouter Video",
                             rows: filtered(openRouter.video.map {
                                 Row(id: OpenRouterModelId.stored($0.id), displayName: $0.displayName, detail: $0.id)
                             })),
            ])
        }
        if scope == .all || scope == .audio {
            sections.append(
                ModelSection(id: "palmier-audio", title: "Palmier Audio",
                             rows: filtered(catalog.audio.map { Row(id: $0.id, displayName: $0.displayName, detail: "Palmier") }))
            )
        }
        return sections.filter { !$0.rows.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            searchBar

            if sections.isEmpty {
                Text(emptyStateText)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .padding(.top, AppTheme.Spacing.lg)
            } else {
                ForEach(sections) { section in
                    sectionView(section)
                }
            }
        }
    }

    private var emptyStateText: String {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            return "No models match \"\(query)\"."
        }
        if scope == .visual, openRouter.hasAPIKey && openRouter.isLoading {
            return "Loading models…"
        }
        if scope == .visual {
            return "Configure a video generation provider to load models."
        }
        if scope == .audio {
            return "Configure an audio generation provider to load models."
        }
        if !catalog.isLoaded || (openRouter.hasAPIKey && !openRouter.isLoaded) {
            return "Loading models…"
        }
        return "No models available."
    }

    private var searchBar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.mutedColor)
            TextField("Search models", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.primaryColor)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .fill(Color.white.opacity(AppTheme.Opacity.subtle))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.thin)
        )
    }

    private func sectionView(_ section: ModelSection) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text(section.title.uppercased())
                .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                .tracking(AppTheme.Tracking.tight)
                .foregroundStyle(AppTheme.Text.tertiaryColor)

            VStack(spacing: 0) {
                ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                    modelRow(row)
                    if index < section.rows.count - 1 {
                        Divider().overlay(AppTheme.Border.subtleColor)
                    }
                }
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .fill(Color.white.opacity(AppTheme.Opacity.subtle))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.thin)
            )
        }
    }

    private func modelRow(_ row: Row) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(row.displayName)
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                Text(row.detail)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .lineLimit(1)
            }
            Spacer(minLength: AppTheme.Spacing.lg)
            Toggle("", isOn: Binding(
                get: { prefs.isEnabled(row.id) },
                set: { prefs.setEnabled(row.id, $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.vertical, AppTheme.Spacing.smMd)
    }
}
