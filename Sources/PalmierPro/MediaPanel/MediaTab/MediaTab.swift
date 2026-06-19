import SwiftUI
import UniformTypeIdentifiers

struct MediaTab: View {
    @Environment(EditorViewModel.self) var editor

    // Toolbar state
    @State var sortMode: SortMode = .dateAdded
    @State var filterTypes: Set<ClipType> = []
    @State var filterAI = false
    @State var searchQuery: String = ""
    @State var thumbnailSize: Double = 80
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
    @State var visualHits: [VisualSearch.Hit] = []
    @State var spokenHits: [TranscriptSearch.Hit] = []
    @State var collapsedSearchSections: Set<String> = []
    @State var momentSearchTask: Task<Void, Never>?
    @State var assetFrames: [String: CGRect] = [:]
    @State var marqueeSelection = MarqueeSelection()

    @State private var mediaPanelHeight: CGFloat = 600

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

    /// Only media types that can actually appear in the panel. ClipType.text
    /// exists for timeline clips but is never assigned to a MediaAsset.
    private static let filterableTypes: [ClipType] = [.video, .audio, .image]

    private enum ThumbnailPreset: String, CaseIterable, Identifiable {
        case small, medium, large, xlarge
        var id: String { rawValue }
        var title: String {
            switch self {
            case .small: "Small"
            case .medium: "Medium"
            case .large: "Large"
            case .xlarge: "Extra Large"
            }
        }
        var size: Double {
            switch self {
            case .small: 80
            case .medium: 110
            case .large: 150
            case .xlarge: 200
            }
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            if editor.pendingSwapClipId != nil {
                swapBanner
            }

            ZStack(alignment: .top) {
                MediaPanelDropArea(
                    isTargeted: $isDropTargeted,
                    onDrop: { urls in handlePanelFinderDrop(urls: urls) }
                ) {
                    VStack(spacing: 0) {
                        if showsEmptyState {
                            emptyStateView
                        } else if !trimmedSearchQuery.isEmpty {
                            searchResults
                        } else {
                            switch viewMode {
                            case .folder: mediaGridView
                            case .flat: flatGridView
                            case .grouped: groupedGridView
                            }
                        }
                    }
                }
                .overlay {
                    if isDropTargeted { dropHighlight.allowsHitTesting(false) }
                }
                .overlay(alignment: .bottom) {
                    if let toast = editor.mediaPanelToast {
                        toastBanner(toast)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: AppTheme.Anim.transition), value: editor.mediaPanelToast)
            }
            .layoutPriority(1)
            .onChange(of: searchQuery) { _, _ in scheduleMomentSearch() }

            if editor.showGenerationPanel && !mediaAreaCollapsed {
                GenerationView(maxPanelHeight: generationPanelMaxHeight)
                    .frame(maxHeight: CGFloat(generationPanelMaxHeight), alignment: .bottom)
                    .tourAnchor(.generation)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { newValue in
            mediaPanelHeight = newValue
        }
        .onExitCommand { if editor.pendingSwapClipId != nil { editor.cancelMediaSwap() } }
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
        .onChange(of: editor.mediaPanelPasteRequestTick) { _, _ in
            handleClipboardPaste()
        }
        .onChange(of: currentFolderId, initial: true) { _, folderId in
            editor.mediaPanelCurrentFolderId = folderId
        }
    }

    private var swapBanner: some View {
        let tint = Color(nsColor: (editor.pendingSwapClip?.mediaType ?? .video).themeColor)
        return HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: AppTheme.FontSize.smMd, weight: .semibold))
                .foregroundStyle(tint)
            Text("Pick a replacement for \"\(editor.pendingSwapClipName ?? "clip")\"")
                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: AppTheme.Spacing.sm)
            Button("Cancel") { editor.cancelMediaSwap() }
                .buttonStyle(.plain)
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
        }
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(tint.opacity(AppTheme.Opacity.faint))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(tint.opacity(AppTheme.Opacity.muted))
                .frame(height: AppTheme.BorderWidth.hairline)
        }
    }

    private func toastBanner(_ message: String) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: AppTheme.FontSize.smMd, weight: .semibold))
                .foregroundStyle(AppTheme.Accent.timecodeColor)
            Text(message)
                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .fill(AppTheme.Background.prominentColor)
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                        .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.hairline)
                )
        )
        .shadow(AppTheme.Shadow.lg)
        .padding(.horizontal, AppTheme.Spacing.lgXl)
        .padding(.bottom, AppTheme.Spacing.lgXl)
        .onTapGesture { editor.dismissMediaPanelToast() }
        .task(id: message) {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            editor.dismissMediaPanelToast()
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
        if !passesFilters(asset) {
            clearFilters()
            searchQuery = ""
        }
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
        editor.selectedFolderIds.removeAll()
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        VStack(spacing: AppTheme.Spacing.xs) {
            actionsRow
            searchControlsRow
            contextBar
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.top, AppTheme.Spacing.sm)
        .padding(.bottom, AppTheme.Spacing.xs)
        .background(AppTheme.Background.surfaceColor)
    }

    private var actionsRow: some View {
        let showGenerate = !AccountService.shared.isMisconfigured
        return HStack(spacing: AppTheme.Spacing.xs) {
            toolbarButton(title: "Import", systemImage: "plus", action: importMedia)
                .tourAnchor(.importButton)
            if showGenerate {
                toolbarButton(title: "Generate", systemImage: "sparkles", filled: true, accentStyle: AnyShapeStyle(AppTheme.aiGradient), action: toggleGenerationPanel)
                    .tourAnchor(.generateButton)
            }

            overflowMenu

            Spacer(minLength: 0)

            searchIndexStatus
                .tourAnchor(.smartSearch)
        }
        .frame(height: Layout.panelHeaderHeight)
    }

    private var searchControlsRow: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            searchField
                .layoutPriority(1)

            displayControls
        }
        .frame(height: Layout.panelHeaderHeight)
    }

    // MARK: - Context bar (breadcrumb + count)

    var breadcrumbItems: [BreadcrumbItem] {
        var items: [BreadcrumbItem] = [BreadcrumbItem(folderId: nil, name: "Library")]
        for f in editor.folderPath(for: currentFolderId) {
            items.append(BreadcrumbItem(folderId: f.id, name: f.name))
        }
        return items
    }

    struct BreadcrumbItem: Identifiable {
        let folderId: String?
        let name: String
        var id: String { folderId ?? "__root__" }
    }

    private var contextBar: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            contextPath
                .layoutPriority(1)

            Spacer(minLength: AppTheme.Spacing.xs)

            itemCountText
        }
        .frame(height: AppTheme.MediaPanel.contextRowHeight)
    }

    @ViewBuilder
    private var contextPath: some View {
        if viewMode == .folder {
            breadcrumbBar
        } else {
            Text(viewMode.title)
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var breadcrumbBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: AppTheme.Spacing.xs) {
                ForEach(Array(breadcrumbItems.enumerated()), id: \.element.id) { idx, item in
                    if idx > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: AppTheme.FontSize.xxs))
                            .foregroundStyle(AppTheme.Text.mutedColor)
                    }
                    breadcrumbChip(item: item, isLeaf: idx == breadcrumbItems.count - 1)
                }
            }
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var displayControls: some View {
        toolbarMenuIcon(systemName: "rectangle.grid.2x2") {
            Section("View") {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Button {
                        setViewMode(mode)
                    } label: {
                        Label(mode.title, systemImage: viewMode == mode ? "checkmark" : mode.systemImage)
                    }
                }
            }
            Divider()
            Section("Thumbnail Size") {
                ForEach(ThumbnailPreset.allCases) { preset in
                    Button {
                        thumbnailSize = preset.size
                    } label: {
                        Label(preset.title, systemImage: thumbnailSize == preset.size ? "checkmark" : "")
                    }
                }
            }
        }

        toolbarMenuIcon(systemName: "arrow.up.arrow.down") {
            ForEach(SortMode.allCases, id: \.self) { mode in
                Button {
                    sortMode = mode
                } label: {
                    Label(mode.title, systemImage: sortMode == mode ? "checkmark" : "")
                }
            }
        }

        toolbarMenuIcon(
            systemName: "line.3.horizontal.decrease",
            foregroundStyle: hasActiveFilters ? AppTheme.Accent.primary : AppTheme.Text.tertiaryColor
        ) {
            ForEach(Self.filterableTypes, id: \.self) { type in
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

    private func breadcrumbChip(item: BreadcrumbItem, isLeaf: Bool) -> some View {
        let textColor = isLeaf ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor
        return Button {
            if !isLeaf { navigateToFolder(item.folderId) }
        } label: {
            Text(item.name)
                .font(.system(size: AppTheme.FontSize.xs, weight: isLeaf ? .semibold : .regular))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.vertical, AppTheme.Spacing.xxs)
                .hoverHighlight(cornerRadius: AppTheme.Radius.xsSm)
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
        let folders = editor.subfolders(of: currentFolderId)
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return folders }
        return folders.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private func passesFilters(_ asset: MediaAsset) -> Bool {
        let typeOk = filterTypes.isEmpty || filterTypes.contains(asset.type)
        let aiOk = !filterAI || asset.isGenerated
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        let nameOk = q.isEmpty || asset.name.localizedCaseInsensitiveContains(q)
        return typeOk && aiOk && nameOk
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
        Text(currentFolderItemCount == 1 ? "1 item" : "\(currentFolderItemCount) items")
            .font(.system(size: AppTheme.FontSize.xs))
            .foregroundStyle(AppTheme.Text.mutedColor)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
    }

    private var searchField: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            TextField("Search", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.primaryColor)
            if !searchQuery.isEmpty {
                Button { searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Clear search")
            }
        }
        .padding(.leading, AppTheme.Spacing.smMd)
        .padding(.trailing, AppTheme.Spacing.xs)
        .padding(.vertical, AppTheme.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(AppTheme.Opacity.subtle))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(AppTheme.Opacity.faint), lineWidth: AppTheme.BorderWidth.thin)
        )
    }

    private func toolbarButton(
        title: String,
        systemImage: String,
        filled: Bool = false,
        accentStyle: AnyShapeStyle? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: systemImage)
                Text(title)
            }
        }
        .buttonStyle(.capsule(filled ? .prominent : .secondary, fill: accentStyle))
        .focusable(false)
        .help(title)
    }

    private var mediaAreaCollapsed: Bool {
        !editor.mediaPanelVisible
            || (editor.maximizedPanel != nil && editor.maximizedPanel != .media)
    }

    private var generationPanelMaxHeight: Double {
        Double(max(0, mediaPanelHeight - AppTheme.GenerationPanel.mediaAreaMinHeight))
    }

    private func toggleGenerationPanel() {
        withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) {
            editor.showGenerationPanel.toggle()
        }
    }

    private var overflowMenu: some View {
        let canOrganize = !AccountService.shared.isMisconfigured && !editor.mediaAssets.isEmpty
        return toolbarMenuIcon(systemName: "ellipsis") {
            Button(action: createNewFolderInCurrent) {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            if canOrganize {
                Button(action: organizeWithAgent) {
                    Label("Organize with Agent", systemImage: "wand.and.stars")
                }
            }
        }
    }

    private func organizeWithAgent() {
        let folderHint = currentFolderId.map { _ in " Work within the current folder." } ?? ""
        let service = editor.agentService
        service.newChat()
        service.draft = "Organize my media library. Review the assets, group related ones into clearly named folders, and give generically-named assets short descriptive names — inspect an asset when its name is unclear. Don't delete anything or change the timeline.\(folderHint)"
        editor.agentPanelVisible = true
    }

    private func toolbarMenuIcon<Content: View>(
        systemName: String,
        foregroundStyle: some ShapeStyle = AppTheme.Text.tertiaryColor,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu(content: content) {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(foregroundStyle)
                .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
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
                .stroke(Color.white.opacity(AppTheme.Opacity.strong), style: StrokeStyle(lineWidth: AppTheme.BorderWidth.thin, dash: [3, 3]))
                .background(Rectangle().fill(Color.white.opacity(AppTheme.Opacity.soft)))
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
                .font(.system(size: AppTheme.FontSize.display, weight: .light))
                .foregroundStyle(AppTheme.Text.tertiaryColor)

            VStack(spacing: AppTheme.Spacing.xs) {
                Text("No media yet")
                    .font(.system(size: AppTheme.FontSize.title1, weight: .light))
                    .tracking(AppTheme.Tracking.tight)
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
                AppTheme.Accent.primary.opacity(0.6),
                style: StrokeStyle(lineWidth: AppTheme.BorderWidth.thick, dash: [8, 4])
            )
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .fill(AppTheme.Accent.primary.opacity(AppTheme.Opacity.subtle))
            )
            .padding(AppTheme.Spacing.xs)
    }

    // MARK: - Import

    private func importMedia() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Select media files or folders to import"
        var types: [UTType] = [.movie, .image, .audio, .json]
        if let lottie = UTType(filenameExtension: "lottie") { types.append(lottie) }
        panel.allowedContentTypes = types
        panel.begin { response in
            guard response == .OK else { return }
            editor.importFinderItems(panel.urls, into: currentFolderId)
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
