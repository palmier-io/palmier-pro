import SwiftUI

// Browse external media catalogs (Photos, downloaded footage, past cuts, other editors'
// caches) and import into the project library. See docs/design/external-media-providers.md.
struct SourcesTab: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var model = SourceBrowserModel()

    var body: some View {
        VStack(spacing: 0) {
            providerSwitcher
            if model.availableTypes.count > 1 { typeSwitcher }
            searchField
            Divider().overlay(AppTheme.Border.primaryColor)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            await model.refreshHealth()
            await model.reload()
        }
    }

    private var providerSwitcher: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppTheme.Spacing.xs) {
                ForEach(model.providers) { p in
                    providerPill(p)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.sm)
        }
    }

    private func providerPill(_ p: SourceBrowserModel.ProviderState) -> some View {
        let selected = model.selectedId == p.id
        return Button {
            model.select(p.id)
        } label: {
            HStack(spacing: AppTheme.Spacing.xxs) {
                Circle()
                    .fill(healthColor(p.online))
                    .frame(width: AppTheme.IconSize.xs / 2, height: AppTheme.IconSize.xs / 2)
                Text(p.label)
                    .font(.system(size: AppTheme.FontSize.xs,
                                  weight: selected ? AppTheme.FontWeight.semibold : AppTheme.FontWeight.regular))
            }
            .foregroundStyle(selected ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
            .padding(.horizontal, AppTheme.Spacing.smMd)
            .padding(.vertical, AppTheme.Spacing.xs)
            .background(
                Capsule().fill(selected ? AppTheme.Background.prominentColor : AppTheme.Background.raisedColor)
            )
            .overlay(Capsule().strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.hairline))
        }
        .buttonStyle(.plain)
    }

    private var typeSwitcher: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            ForEach(model.availableTypes, id: \.self) { t in
                let selected = model.activeType == t
                Button { model.selectType(t) } label: {
                    Text(t.rawValue.capitalized)
                        .font(.system(size: AppTheme.FontSize.xxs,
                                      weight: selected ? AppTheme.FontWeight.semibold : AppTheme.FontWeight.regular))
                        .foregroundStyle(selected ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                        .padding(.horizontal, AppTheme.Spacing.sm)
                        .padding(.vertical, AppTheme.Spacing.xxs)
                        .background(Capsule().fill(selected ? AppTheme.Background.prominentColor : .clear))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.bottom, AppTheme.Spacing.xs)
    }

    private var searchField: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            TextField("Search", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.xs))
                .onSubmit { Task { await model.reload() } }
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                    Task { await model.reload() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.smMd)
        .padding(.vertical, AppTheme.Spacing.xs)
        .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(AppTheme.Background.raisedColor))
        .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
            .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.hairline))
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.bottom, AppTheme.Spacing.sm)
    }

    @ViewBuilder private var content: some View {
        if model.selected?.online == false {
            offlineState
        } else if model.items.isEmpty && (model.isLoading || !model.hasLoaded) {
            centeredMessage(spinner: true, "Loading…")
        } else if let err = model.loadError, model.items.isEmpty {
            centeredMessage("Couldn’t load. \(err)")
        } else if model.items.isEmpty {
            centeredMessage(model.searchText.isEmpty ? "No assets in this source." : "No matches.")
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 140), spacing: AppTheme.Spacing.md)],
                alignment: .leading, spacing: AppTheme.Spacing.md
            ) {
                ForEach(model.items) { card in
                    SourceCardView(card: card, isImported: importedRefs.contains(Self.key(card.providerId, card.ref))) {
                        importCard(card)
                    }
                }
            }
            .padding(AppTheme.Spacing.sm)

            if model.hasMore {
                Button {
                    Task { await model.loadMore() }
                } label: {
                    Text(model.isLoading ? "Loading…" : "Load more")
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppTheme.Spacing.sm)
                }
                .buttonStyle(.plain)
                .disabled(model.isLoading)
                .padding(.bottom, AppTheme.Spacing.md)
            }
        }
    }

    private var offlineState: some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: AppTheme.FontSize.title1))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Text("“\(model.selected?.label ?? "Source")” is offline.")
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Text("Start its local server, then retry.")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Button("Retry") {
                Task { await model.refreshHealth(); await model.reload() }
            }
            .font(.system(size: AppTheme.FontSize.xs))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func centeredMessage(spinner: Bool = false, _ text: String) -> some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            if spinner { ProgressView().controlSize(.small) }
            Text(text)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppTheme.Spacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func healthColor(_ online: Bool?) -> Color {
        switch online {
        case .some(true): AppTheme.Status.successColor
        case .some(false): AppTheme.Status.errorColor
        case .none: AppTheme.Text.tertiaryColor
        }
    }

    // Provider refs already present in the library (by provenance) — marks grid cards as imported.
    private var importedRefs: Set<String> {
        Set(editor.mediaManifest.entries.compactMap { entry in
            entry.provenance.map { Self.key($0.providerId, $0.providerRef) }
        })
    }

    private static func key(_ providerId: String, _ ref: String) -> String { "\(providerId)\u{1}\(ref)" }

    private func importCard(_ card: AssetCard) {
        do {
            _ = try ToolExecutor(editor: editor).importFromProvider(
                editor: editor, providerId: card.providerId, ref: card.ref, name: card.name,
                folderId: nil, typeHint: card.type
            )
            editor.mediaPanelToast = MediaPanelToast(message: "Importing “\(card.name)”…", kind: .success)
        } catch {
            editor.mediaPanelToast = MediaPanelToast(message: "Import failed: \(error.localizedDescription)")
        }
    }
}
