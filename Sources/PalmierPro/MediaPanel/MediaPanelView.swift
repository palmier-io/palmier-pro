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

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: AppTheme.Spacing.xl)]

    var body: some View {
        VStack(spacing: 0) {
            // Top toolbar
            HStack(spacing: AppTheme.Spacing.xs) {
                toolbarButton(title: "Import", systemImage: "plus", action: importMedia)

                toolbarButton(title: "Generate", systemImage: "sparkles") {
                    withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) {
                        editor.showGenerationPanel.toggle()
                    }
                }

                Spacer()

                Text("\(filteredAndSortedAssets.count) items")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .monospacedDigit()

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
            .frame(height: 28)
            .background(AppTheme.Background.barColor)
            .overlay(alignment: .bottom) {
                Rectangle().fill(AppTheme.Border.primaryColor).frame(height: 0.5)
            }

            if showsEmptyState {
                emptyStateView
            } else {
                mediaGridView

                if editor.showGenerationPanel {
                    Rectangle()
                        .fill(AppTheme.Border.subtleColor)
                        .frame(height: 0.5)

                    GenerationView()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .background(AppTheme.Background.panelColor)
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
        ScrollView {
            LazyVGrid(columns: columns, spacing: AppTheme.Spacing.xl) {
                ForEach(filteredAndSortedAssets) { asset in
                    assetCell(for: asset)
                }
            }
            .padding(AppTheme.Spacing.md)
        }
        .coordinateSpace(name: "mediaGrid")
        .onPreferenceChange(AssetFramePreferenceKey.self) { assetFrames = $0 }
        .onTapGesture {
            editor.selectedMediaAssetIds.removeAll()
        }
        .overlay {
            marqueeOverlay
        }
        .gesture(marqueeGesture)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
            return true
        }
        .overlay {
            if isDropTargeted {
                dropHighlight
            }
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

    private func toolbarButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .focusable(false)
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
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusable(false)
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
                addMediaAsset(from: url)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    addMediaAsset(from: url)
                }
            }
        }
    }

    private func addMediaAsset(from url: URL) {
        guard let type = ClipType(fileExtension: url.pathExtension.lowercased()) else { return }

        let name = url.deletingPathExtension().lastPathComponent
        let asset = MediaAsset(url: url, type: type, name: name)
        editor.importMediaAsset(asset)

        Task {
            await asset.loadMetadata()
            editor.updateManifestMetadata(for: asset)
            switch asset.type {
            case .video:
                editor.mediaVisualCache.generateWaveform(for: asset)
                editor.mediaVisualCache.generateThumbnails(for: asset, fps: editor.timeline.fps)
            case .audio:
                editor.mediaVisualCache.generateWaveform(for: asset)
            case .image:
                editor.mediaVisualCache.generateImageThumbnail(for: asset)
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
