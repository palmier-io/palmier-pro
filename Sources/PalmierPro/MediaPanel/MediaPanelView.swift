import SwiftUI
import UniformTypeIdentifiers

struct MediaPanelView: View {
    @Environment(EditorViewModel.self) var editor
    @State private var sortMode: SortMode = .dateAdded
    @State private var filterTypes: Set<ClipType> = []
    @State private var filterAI = false
    @State private var isDropTargeted = false
    @State private var assetFrames: [String: CGRect] = [:]
    @State private var marqueeSelection = MarqueeSelection()
    @State private var thumbnailSize: Double = 110

    private static let minThumbnailSize: Double = 72
    private static let maxThumbnailSize: Double = 220

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: thumbnailSize), spacing: AppTheme.Spacing.xl)]
    }

    var body: some View {
        VStack(spacing: 0) {
            GlassEffectContainer {
                ZStack(alignment: .top) {
                    // Content layer
                    VStack(spacing: 0) {
                        if showsEmptyState {
                            emptyStateView
                        } else {
                            mediaGridView
                        }
                    }
                    .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                        handleDrop(providers)
                        return true
                    }
                    .overlay {
                        if isDropTargeted {
                            dropHighlight
                        }
                    }

                // Floating toolbar
                HStack(spacing: AppTheme.Spacing.xs) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            toolbarButton(title: "Import", systemImage: "plus", compact: false, action: importMedia)
                            toolbarButton(title: "Generate", systemImage: "sparkles", compact: false, accentStyle: AnyShapeStyle(AppTheme.aiGradient), action: toggleGenerationPanel)
                        }
                        HStack(spacing: AppTheme.Spacing.xs) {
                            toolbarButton(title: "Import", systemImage: "plus", compact: true, action: importMedia)
                            toolbarButton(title: "Generate", systemImage: "sparkles", compact: true, accentStyle: AnyShapeStyle(AppTheme.aiGradient), action: toggleGenerationPanel)
                        }
                    }

                    Spacer()

                    Text("\(filteredAndSortedAssets.count) items")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()

                    Slider(
                        value: $thumbnailSize,
                        in: Self.minThumbnailSize...Self.maxThumbnailSize
                    )
                    .controlSize(.mini)
                    .frame(width: 60)
                    .help("Thumbnail size")

                    // Sort
                    toolbarMenuIcon(systemName: "arrow.up.arrow.down") {
                        ForEach(SortMode.allCases, id: \.self) { mode in
                            Button(mode.title) { sortMode = mode }
                        }
                    }

                    // Filter
                    toolbarMenuIcon(
                        systemName: "line.3.horizontal.decrease",
                        foregroundStyle: hasActiveFilters ? Color.accentColor : AppTheme.Text.tertiaryColor
                    ) {
                        ForEach(ClipType.allCases, id: \.self) { type in
                            Button { toggleFilter(type) } label: {
                                Label(type.trackLabel, systemImage: filterTypes.contains(type) ? "checkmark" : "")
                            }
                        }
                        Divider()
                        Button { filterAI.toggle() } label: {
                            Label("AI Generated", systemImage: filterAI ? "checkmark" : "")
                        }
                        Divider()
                        Button("Clear Filters", action: clearFilters)
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.vertical, AppTheme.Spacing.xs)
                .glassEffect(.regular, in: .capsule)
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.top, AppTheme.Spacing.xs)
            }
            }

            if editor.showGenerationPanel {
                GenerationView()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(AppTheme.Border.subtleColor).frame(width: 0.5)
        }
    }

    private var selectedMediaAssetsInOrder: [MediaAsset] {
        editor.mediaAssets.filter { editor.selectedMediaAssetIds.contains($0.id) }
    }

    private var showsEmptyState: Bool {
        editor.mediaAssets.isEmpty && !editor.showGenerationPanel
    }

    // MARK: - Sort & Filter

    enum SortMode: CaseIterable {
        case name, dateAdded, duration, type

        var title: String {
            switch self {
            case .name: "Name"
            case .dateAdded: "Date Added"
            case .duration: "Duration"
            case .type: "Type"
            }
        }
    }

    private var hasActiveFilters: Bool {
        !filterTypes.isEmpty || filterAI
    }

    private func toggleFilter(_ type: ClipType) {
        if filterTypes.contains(type) {
            filterTypes.remove(type)
        } else {
            filterTypes.insert(type)
        }
    }

    private func clearFilters() {
        filterTypes.removeAll()
        filterAI = false
    }

    private var filteredAndSortedAssets: [MediaAsset] {
        let filteredAssets = editor.mediaAssets.filter { asset in
            (filterTypes.isEmpty || filterTypes.contains(asset.type)) &&
            (!filterAI || asset.isGenerated)
        }

        return switch sortMode {
        case .dateAdded:
            filteredAssets
        case .name:
            filteredAssets.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .duration:
            filteredAssets.sorted { $0.duration > $1.duration }
        case .type:
            filteredAssets.sorted { $0.type.rawValue < $1.type.rawValue }
        }
    }

    private var mediaGridView: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: AppTheme.Spacing.xl) {
                    ForEach(filteredAndSortedAssets) { asset in
                        assetCell(for: asset)
                            .id(asset.id)
                    }
                }
                .padding(AppTheme.Spacing.md)
                .padding(.top, Layout.panelHeaderHeight + AppTheme.Spacing.sm)
            }
            .coordinateSpace(name: "mediaGrid")
            .onPreferenceChange(AssetFramePreferenceKey.self) { frames in
                assetFrames = frames
                if let topY = frames.values.map(\.midY).min() {
                    editor.mediaPanelColumnCount = frames.values.filter { abs($0.midY - topY) < 1 }.count
                }
            }
            .onAppear {
                editor.mediaPanelOrderedIds = filteredAndSortedAssets.map(\.id)
            }
            .onChange(of: filteredAndSortedAssets.map(\.id)) { _, ids in
                editor.mediaPanelOrderedIds = ids
            }
            .onChange(of: editor.mediaPanelScrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(target, anchor: .center)
                }
                editor.mediaPanelScrollTarget = nil
            }
            .onTapGesture {
                editor.selectedMediaAssetIds.removeAll()
            }
            .overlay {
                marqueeOverlay
            }
            .gesture(marqueeGesture)
        }
    }

    private func assetCell(for asset: MediaAsset) -> some View {
        AssetThumbnailView(asset: asset)
            .draggable(dragPayload(for: asset)) {
                dragPreview(for: asset)
            }
            .background(assetFrameReader(for: asset))
    }

    private func assetFrameReader(for asset: MediaAsset) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: AssetFramePreferenceKey.self,
                value: [asset.id: geo.frame(in: .named("mediaGrid"))]
            )
        }
    }

    private func toolbarButton(
        title: String,
        systemImage: String,
        compact: Bool,
        accentStyle: AnyShapeStyle? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                if !compact {
                    Text(title)
                }
            }
            .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
            .foregroundStyle(accentStyle ?? AnyShapeStyle(AppTheme.Text.secondaryColor))
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, 4)
            .hoverHighlight()
            .help(title)
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    private func toggleGenerationPanel() {
        withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) {
            editor.showGenerationPanel.toggle()
        }
    }

    private func toolbarMenuIcon<Content: View>(
        systemName: String,
        foregroundStyle: some ShapeStyle = AppTheme.Text.tertiaryColor,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu(content: content) {
            Image(systemName: systemName)
                .font(.system(size: 10))
                .foregroundStyle(foregroundStyle)
                .frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusable(false)
        .hoverHighlight()
    }

    // MARK: - Multi-drag payload

    private func dragPayload(for asset: MediaAsset) -> String {
        if editor.selectedMediaAssetIds.contains(asset.id) {
            return selectedMediaAssetsInOrder.map(\.url.absoluteString).joined(separator: "\n")
        }
        return asset.url.absoluteString
    }

    // MARK: - Drag Preview

    @ViewBuilder
    private func dragPreview(for asset: MediaAsset) -> some View {
        let count = editor.selectedMediaAssetIds.contains(asset.id) ? editor.selectedMediaAssetIds.count : 1
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumbnail = asset.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Image(systemName: asset.type.sfSymbolName)
                            .font(.title2)
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                }
            }
            .frame(width: 80, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
            )
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)

            if count > 1 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
                    .offset(x: 4, y: -4)
            }
        }
        .padding(.top, 4)
        .padding(.trailing, 4)
    }

    // MARK: - Marquee Selection

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("mediaGrid"))
            .onChanged { value in
                if !marqueeSelection.isActive {
                    let startOnAsset = assetFrames.values.contains { $0.contains(value.startLocation) }
                    if startOnAsset { return }
                    marqueeSelection.begin(
                        baseSelection: NSEvent.modifierFlags.contains(.shift) ? editor.selectedMediaAssetIds : []
                    )
                }

                let rect = marqueeRect(from: value)
                marqueeSelection.rect = rect
                var ids = marqueeSelection.baseSelection

                for (id, frame) in assetFrames where rect.intersects(frame) {
                    ids.insert(id)
                }

                if ids != editor.selectedMediaAssetIds {
                    editor.selectedMediaAssetIds = ids
                }
            }
            .onEnded { _ in
                marqueeSelection.reset()
            }
    }

    @ViewBuilder
    private var marqueeOverlay: some View {
        if let rect = marqueeSelection.rect {
            Rectangle()
                .stroke(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .background(Rectangle().fill(Color.white.opacity(0.1)))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
        }
    }

    private func marqueeRect(from value: DragGesture.Value) -> CGRect {
        CGRect(
            x: min(value.startLocation.x, value.location.x),
            y: min(value.startLocation.y, value.location.y),
            width: abs(value.location.x - value.startLocation.x),
            height: abs(value.location.y - value.startLocation.y)
        )
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: AppTheme.Spacing.lg) {
            Spacer()

            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(AppTheme.Text.tertiaryColor)

            VStack(spacing: AppTheme.Spacing.xs) {
                Text("No media yet")
                    .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)

                Text("Drop files here or import from disk")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Drop Highlight

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: AppTheme.Radius.md)
            .strokeBorder(
                Color.accentColor.opacity(0.6),
                style: StrokeStyle(lineWidth: 2, dash: [8, 4])
            )
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .fill(Color.accentColor.opacity(0.05))
            )
            .padding(4)
    }

    // MARK: - Import

    private func importMedia() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .image, .audio]
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                editor.addMediaAsset(from: url)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    editor.addMediaAsset(from: url)
                }
            }
        }
    }
}

// MARK: - Preference Key for asset frame tracking

private struct MarqueeSelection {
    var rect: CGRect?
    var isActive = false
    var baseSelection: Set<String> = []

    mutating func begin(baseSelection: Set<String>) {
        isActive = true
        self.baseSelection = baseSelection
    }

    mutating func reset() {
        rect = nil
        isActive = false
        baseSelection = []
    }
}

private struct AssetFramePreferenceKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
