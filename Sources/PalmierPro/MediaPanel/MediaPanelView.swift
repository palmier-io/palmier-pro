import SwiftUI
import UniformTypeIdentifiers

struct MediaPanelView: View {
    @Environment(EditorViewModel.self) var editor

    // Toolbar state
    @State var sortMode: SortMode = .dateAdded
    @State var filterTypes: Set<ClipType> = []
    @State var filterAI = false
    @State var thumbnailSize: Double = 110
    @State var viewMode: ViewMode = .folder

    // Navigation + selection state
    @State var currentFolderId: String? = nil
    @State var folderReturnViewMode: ViewMode?
    @State var renamingFolderId: String?
    @State var pendingFolderFocusId: String?
    @State var dropTargetFolderId: String?
    /// Hovered grouped-section key; "" = root.
    @State var dropTargetGroupedKey: String?
    /// Collapsed grouped-section keys; "" = root.
    @State var collapsedGroupedKeys: Set<String> = []

    // Drop + marquee
    @State var isDropTargeted = false
    @State var assetFrames: [String: CGRect] = [:]
    @State var marqueeSelection = MarqueeSelection()

    enum ViewMode: String, CaseIterable {
        case folder, flat, grouped

        var title: String {
            switch self {
            case .folder: "Folders"
            case .flat: "Flat"
            case .grouped: "Grouped"
            }
        }

        var systemImage: String {
            switch self {
            case .folder: "folder"
            case .flat: "square.grid.2x2"
            case .grouped: "rectangle.split.1x2"
            }
        }
    }

    private static let minThumbnailSize: Double = 72
    private static let maxThumbnailSize: Double = 220

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    if showsEmptyState {
                        emptyStateView
                    } else {
                        VStack(spacing: 0) {
                            if viewMode == .folder, !breadcrumbItems.isEmpty {
                                breadcrumbBar
                            }
                            switch viewMode {
                            case .folder: mediaGridView
                            case .flat: flatGridView
                            case .grouped: groupedGridView
                            }
                        }
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                    handleProviderDrop(providers, into: currentFolderId)
                    return true
                }
                .overlay {
                    if isDropTargeted { dropHighlight }
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
        .background(KeyCommandSink(onNewFolder: createNewFolderInCurrent, onNavigateUp: navigateUp))
        .onChange(of: editor.folders.map(\.id)) { _, _ in pruneStaleFolderState() }
        .onChange(of: editor.mediaPanelRevealAssetId) { _, target in
            guard let target else { return }
            revealAsset(id: target)
            editor.mediaPanelRevealAssetId = nil
        }
        .onChange(of: editor.mediaPanelOpenFolderId) { _, target in
            guard let target else { return }
            openFolder(id: target)
            editor.mediaPanelOpenFolderId = nil
        }
    }

    /// If the current folder, rename target, or hover target has been deleted,
    /// drop them back to safe defaults. Pops drilled-in views to root.
    private func pruneStaleFolderState() {
        if let id = currentFolderId, editor.folder(id: id) == nil { navigateToFolder(nil) }
        if let id = renamingFolderId, editor.folder(id: id) == nil { renamingFolderId = nil }
        if let id = pendingFolderFocusId, editor.folder(id: id) == nil { pendingFolderFocusId = nil }
        if let id = dropTargetFolderId, editor.folder(id: id) == nil { dropTargetFolderId = nil }
    }

    private func revealAsset(id: String) {
        guard let asset = editor.mediaAssets.first(where: { $0.id == id }) else { return }
        if viewMode == .folder, currentFolderId != asset.folderId {
            currentFolderId = asset.folderId
        }
        // Auto-expand the asset's grouped section so the scroll target exists.
        if viewMode == .grouped {
            collapsedGroupedKeys.remove(asset.folderId ?? "")
        }
        editor.mediaPanelScrollTarget = id
    }

    func openFolder(id: String) {
        guard editor.folder(id: id) != nil else { return }
        if viewMode != .folder {
            folderReturnViewMode = viewMode
        }
        currentFolderId = id
        viewMode = .folder
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    toolbarButton(title: "Import", systemImage: "plus", compact: false, action: importMedia)
                    toolbarButton(title: "New Folder", systemImage: "folder.badge.plus", compact: false, action: createNewFolderInCurrent)
                    toolbarButton(title: "Generate", systemImage: "sparkles", compact: false, accentStyle: AnyShapeStyle(AppTheme.aiGradient), action: toggleGenerationPanel)
                }
                HStack(spacing: AppTheme.Spacing.xs) {
                    toolbarButton(title: "Import", systemImage: "plus", compact: true, action: importMedia)
                    toolbarButton(title: "New Folder", systemImage: "folder.badge.plus", compact: true, action: createNewFolderInCurrent)
                    toolbarButton(title: "Generate", systemImage: "sparkles", compact: true, accentStyle: AnyShapeStyle(AppTheme.aiGradient), action: toggleGenerationPanel)
                }
            }

            Spacer()

            // Drop count + slider when the panel is too narrow.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    itemCountText
                    thumbnailSlider
                }
                itemCountText
                EmptyView()
            }

            toolbarMenuIcon(systemName: viewMode.systemImage) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Button {
                        setViewMode(mode)
                    } label: {
                        Label(mode.title, systemImage: viewMode == mode ? "checkmark" : mode.systemImage)
                    }
                }
            }

            toolbarMenuIcon(systemName: "arrow.up.arrow.down") {
                ForEach(SortMode.allCases, id: \.self) { mode in
                    Button(mode.title) { sortMode = mode }
                }
            }

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
        .frame(height: Layout.panelHeaderHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppTheme.Border.subtleColor).frame(height: 0.5)
        }
    }

    // MARK: - Breadcrumb

    var breadcrumbItems: [BreadcrumbItem] {
        var items: [BreadcrumbItem] = [BreadcrumbItem(folderId: nil, name: "Library")]
        for f in editor.folderPath(for: currentFolderId) {
            items.append(BreadcrumbItem(folderId: f.id, name: f.name))
        }
        return items.count > 1 ? items : []
    }

    struct BreadcrumbItem: Identifiable {
        let folderId: String?
        let name: String
        var id: String { folderId ?? "__root__" }
    }

    private var breadcrumbBar: some View {
        HStack(spacing: 4) {
            ForEach(Array(breadcrumbItems.enumerated()), id: \.element.id) { idx, item in
                if idx > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                breadcrumbChip(item: item, isLeaf: idx == breadcrumbItems.count - 1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.top, AppTheme.Spacing.sm)
        .padding(.bottom, AppTheme.Spacing.xs)
    }

    private func breadcrumbChip(item: BreadcrumbItem, isLeaf: Bool) -> some View {
        let textColor = isLeaf ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor
        return Button {
            if !isLeaf { navigateToFolder(item.folderId) }
        } label: {
            Text(item.name)
                .font(.system(size: AppTheme.FontSize.xs, weight: isLeaf ? .semibold : .regular))
                .foregroundStyle(textColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .hoverHighlight(cornerRadius: 4)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onDrop(of: [.fileURL, .text], isTargeted: nil) { providers in
            handleProviderDrop(providers, into: item.folderId)
            return true
        }
    }

    // MARK: - Selection / state derivations

    var selectedMediaAssetsInOrder: [MediaAsset] {
        editor.mediaAssets.filter { editor.selectedMediaAssetIds.contains($0.id) }
    }

    private var showsEmptyState: Bool {
        editor.mediaAssets.isEmpty && editor.folders.isEmpty && !editor.showGenerationPanel
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

    var assetsInCurrentFolder: [MediaAsset] {
        sortAndFilter(editor.assetsIn(folderId: currentFolderId))
    }

    var subfoldersInCurrentFolder: [MediaFolder] {
        editor.subfolders(of: currentFolderId)
    }

    private func passesFilters(_ asset: MediaAsset) -> Bool {
        let typeOk = filterTypes.isEmpty || filterTypes.contains(asset.type)
        let aiOk = !filterAI || asset.isGenerated
        return typeOk && aiOk
    }

    func sortAndFilter(_ assets: [MediaAsset]) -> [MediaAsset] {
        let filtered = assets.filter(passesFilters)
        return switch sortMode {
        case .dateAdded: filtered
        case .name: filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .duration: filtered.sorted { $0.duration > $1.duration }
        case .type: filtered.sorted { $0.type.rawValue < $1.type.rawValue }
        }
    }

    private var currentFolderItemCount: Int {
        subfoldersInCurrentFolder.count + assetsInCurrentFolder.count
    }

    // MARK: - Toolbar helpers

    private var itemCountText: some View {
        Text("\(currentFolderItemCount) items")
            .font(.system(size: AppTheme.FontSize.xs))
            .foregroundStyle(AppTheme.Text.mutedColor)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
    }

    private var thumbnailSlider: some View {
        Slider(
            value: $thumbnailSize,
            in: Self.minThumbnailSize...Self.maxThumbnailSize
        )
        .controlSize(.mini)
        .frame(width: 60)
        .help("Thumbnail size")
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

    // MARK: - Folder commands

    private func createNewFolderInCurrent() {
        let id = editor.createFolder(name: "New Folder", in: currentFolderId)
        pendingFolderFocusId = id
        renamingFolderId = id
    }

    private func navigateUp() {
        guard let id = currentFolderId, let folder = editor.folder(id: id) else { return }
        navigateToFolder(folder.parentFolderId)
    }

    func setViewMode(_ mode: ViewMode) {
        viewMode = mode
        folderReturnViewMode = nil
    }

    func navigateToFolder(_ folderId: String?) {
        currentFolderId = folderId
        if folderId == nil, let returnMode = folderReturnViewMode {
            viewMode = returnMode
            folderReturnViewMode = nil
        }
    }

    // MARK: - Marquee Selection

    var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("mediaGrid"))
            .onChanged { value in
                if !marqueeSelection.isActive {
                    let startOnCell = assetFrames.values.contains { $0.contains(value.startLocation) }
                    if startOnCell { return }
                    let extending = NSEvent.modifierFlags.contains(.shift)
                    marqueeSelection.begin(
                        baseAssets: extending ? editor.selectedMediaAssetIds : [],
                        baseFolders: extending ? editor.selectedFolderIds : []
                    )
                }

                let rect = marqueeRect(from: value)
                marqueeSelection.rect = rect
                var assetIds = marqueeSelection.baseAssets
                var folderIds = marqueeSelection.baseFolders

                // Frame keys are either raw asset ids or "folder-<id>".
                for (id, frame) in assetFrames where rect.intersects(frame) {
                    if let folderId = MediaCell.folderId(fromFrameKey: id) {
                        folderIds.insert(folderId)
                    } else {
                        assetIds.insert(id)
                    }
                }

                if assetIds != editor.selectedMediaAssetIds {
                    editor.selectedMediaAssetIds = assetIds
                }
                if folderIds != editor.selectedFolderIds {
                    editor.selectedFolderIds = folderIds
                }
            }
            .onEnded { _ in
                marqueeSelection.reset()
            }
    }

    @ViewBuilder
    var marqueeOverlay: some View {
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

    // MARK: - Empty state + drop highlight

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
            let folderId = currentFolderId
            for url in panel.urls {
                if let asset = editor.addMediaAsset(from: url), let folderId {
                    editor.moveAssetsToFolder(assetIds: [asset.id], folderId: folderId)
                }
            }
        }
    }
}

// MARK: - Marquee state

struct MarqueeSelection {
    var rect: CGRect?
    var isActive = false
    var baseAssets: Set<String> = []
    var baseFolders: Set<String> = []

    mutating func begin(baseAssets: Set<String>, baseFolders: Set<String>) {
        isActive = true
        self.baseAssets = baseAssets
        self.baseFolders = baseFolders
    }

    mutating func reset() {
        rect = nil
        isActive = false
        baseAssets = []
        baseFolders = []
    }
}

// MARK: - Cmd+Shift+N / Cmd+Up keyboard shortcuts

private struct KeyCommandSink: NSViewRepresentable {
    let onNewFolder: () -> Void
    let onNavigateUp: () -> Void

    func makeNSView(context: Context) -> SinkView {
        let v = SinkView()
        v.onNewFolder = onNewFolder
        v.onNavigateUp = onNavigateUp
        return v
    }

    func updateNSView(_ nsView: SinkView, context: Context) {
        nsView.onNewFolder = onNewFolder
        nsView.onNavigateUp = onNavigateUp
    }

    final class SinkView: NSView {
        var onNewFolder: (() -> Void)?
        var onNavigateUp: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            let cmd = event.modifierFlags.contains(.command)
            let shift = event.modifierFlags.contains(.shift)
            if cmd, shift, event.charactersIgnoringModifiers?.lowercased() == "n" {
                onNewFolder?()
                return
            }
            if cmd, event.keyCode == 126 {
                onNavigateUp?()
                return
            }
            super.keyDown(with: event)
        }
    }
}
