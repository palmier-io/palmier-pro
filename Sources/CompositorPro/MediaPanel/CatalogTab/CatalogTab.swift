import SwiftUI

struct CatalogTab: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var query = ""
    @State private var selectedCategory: String? = nil

    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            VStack(spacing: AppTheme.Spacing.md) {
                searchBar
                categoryFilters
            }
            .padding(AppTheme.Spacing.md)

            if HyperframesCatalog.shared.isLoading {
                ProgressView("Loading catalog…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = HyperframesCatalog.shared.lastError {
                VStack(spacing: AppTheme.Spacing.md) {
                    Text(error)
                        .foregroundColor(.secondary)
                    if !HyperframesCatalog.base.isEmpty {
                        Text("Make sure the catalog mirror contains block files.")
                            .font(.caption)
                            .foregroundColor(AppTheme.Text.tertiaryColor)
                    } else {
                        Button("Retry") {
                            Task { await HyperframesCatalog.shared.refresh() }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if HyperframesCatalog.shared.blocks.isEmpty {
                VStack(spacing: AppTheme.Spacing.md) {
                    Text("No blocks in catalog.")
                        .foregroundColor(.secondary)
                    if !HyperframesCatalog.base.isEmpty {
                        Text("Make sure the catalog mirror contains block files.")
                            .font(.caption)
                            .foregroundColor(AppTheme.Text.tertiaryColor)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                catalogGrid
            }
        }
        .task {
            await HyperframesCatalog.shared.refresh()
        }
        .onChange(of: query) { _, _ in filterBlocks() }
        .onChange(of: selectedCategory) { _, _ in filterBlocks() }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Search blocks...", text: $query)
                .textFieldStyle(.roundedBorder)
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .frame(height: AppTheme.IconSize.md)
        .background(AppTheme.Background.surfaceColor)
        .cornerRadius(AppTheme.Radius.md)
    }

    private var categoryFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppTheme.Spacing.xs) {
                let categories = Set(HyperframesCatalog.shared.blocks.map { $0.category })
                ForEach([nil] + Array(categories), id: \.self) { cat in
                    Button(action: {
                        selectedCategory = cat
                    }) {
                        Text(cat?.capitalized ?? "All")
                            .font(.caption)
                            .padding(.horizontal, AppTheme.Spacing.sm)
                            .padding(.vertical, AppTheme.Spacing.xs)
                            .background(selectedCategory == cat ? AppTheme.Background.prominentColor : AppTheme.Background.raisedColor)
                            .cornerRadius(AppTheme.Radius.sm)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.md)
        }
    }

    private var catalogGrid: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: AppTheme.Spacing.md),
                GridItem(.flexible(), spacing: AppTheme.Spacing.md)
            ], spacing: AppTheme.Spacing.md) {
                ForEach(filteredBlocks, id: \.id) { block in
                    CatalogBlockCell(block: block)
                }
            }
            .padding(AppTheme.Spacing.md)
        }
    }

    private var filteredBlocks: [HyperframesBlock] {
        var filtered = HyperframesCatalog.shared.blocks
        if let cat = selectedCategory, !cat.isEmpty {
            filtered = filtered.filter { $0.category == cat }
        }
        if !query.isEmpty {
            filtered = filtered.filter { block in
                block.name.localizedCaseInsensitiveContains(query) ||
                    block.tags.contains { $0.localizedCaseInsensitiveContains(query) } ||
                    block.description.localizedCaseInsensitiveContains(query)
            }
        }
        return filtered
    }

    private func filterBlocks() {
        // Filtering happens in the `filteredBlocks` computed property above.
    }
}

struct CatalogBlockCell: View {
    let block: HyperframesBlock

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Rectangle()
                .aspectRatio(16/9, contentMode: .fill)
                .background(Color.gray.opacity(0.2))
                .cornerRadius(AppTheme.Radius.sm)
                .overlay(
                    VStack {
                        Image(systemName: "image")
                            .foregroundColor(.secondary)
                    }
                    , alignment: .center
                )

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(block.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)

                Text(block.category.capitalized)
                    .font(.caption2)
                    .foregroundColor(.secondary)

                if !block.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            ForEach(block.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption2)
                                    .padding(.horizontal, AppTheme.Spacing.xs)
                                    .padding(.vertical, 2)
                                    .background(AppTheme.Background.raisedColor)
                                    .cornerRadius(AppTheme.Radius.xs)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(AppTheme.Spacing.sm)
        .background(AppTheme.Background.surfaceColor)
        .cornerRadius(AppTheme.Radius.md)
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .stroke(AppTheme.Border.primaryColor.opacity(0.1), lineWidth: 1)
        )
    }
}