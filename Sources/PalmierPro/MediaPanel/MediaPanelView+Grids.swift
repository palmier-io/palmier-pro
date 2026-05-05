import SwiftUI
import UniformTypeIdentifiers

// MARK: - Grid layout types

extension MediaPanelView {
    struct MediaCell: Identifiable {
        enum Kind { case folder(MediaFolder), asset(MediaAsset) }
        let kind: Kind

        /// Folder cell ids carry this prefix so marquee can split asset/folder hits.
        static let folderFrameKeyPrefix = "folder-"

        var id: String {
            switch kind {
            case .folder(let f): return Self.folderFrameKeyPrefix + f.id
            case .asset(let a): return a.id
            }
        }
        var assetId: String? {
            if case .asset(let a) = kind { return a.id }
            return nil
        }

        static func folderId(fromFrameKey key: String) -> String? {
            guard key.hasPrefix(folderFrameKeyPrefix) else { return nil }
            return String(key.dropFirst(folderFrameKeyPrefix.count))
        }
    }

    struct GridLayoutInfo {
        let cols: Int
        let tileWidth: CGFloat
        let spacing: CGFloat
        let cells: [MediaCell]
        let orderedAssetIds: [String]
    }

    struct GridDimensions {
        let cols: Int
        let tileWidth: CGFloat
        let spacing: CGFloat
    }
}

// MARK: - Layout math

extension MediaPanelView {
    func gridDimensions(width: CGFloat) -> GridDimensions {
        let spacing = AppTheme.Spacing.xl
        let outerPadding: CGFloat = AppTheme.Spacing.md * 2
        let usable = max(0, width - outerPadding)
        let cols = max(1, Int(floor((usable + spacing) / (thumbnailSize + spacing))))
        let tileWidth = max(thumbnailSize, (usable - CGFloat(cols - 1) * spacing) / CGFloat(cols))
        return GridDimensions(cols: cols, tileWidth: tileWidth, spacing: spacing)
    }

    func computeLayout(width: CGFloat) -> GridLayoutInfo {
        let dims = gridDimensions(width: width)
        var cells: [MediaCell] = []
        for folder in subfoldersInCurrentFolder {
            cells.append(MediaCell(kind: .folder(folder)))
        }
        for asset in assetsInCurrentFolder {
            cells.append(MediaCell(kind: .asset(asset)))
        }
        let orderedAssetIds = cells.compactMap(\.assetId)
        return GridLayoutInfo(
            cols: dims.cols, tileWidth: dims.tileWidth, spacing: dims.spacing,
            cells: cells, orderedAssetIds: orderedAssetIds
        )
    }

    func clearSelections() {
        if !editor.selectedMediaAssetIds.isEmpty { editor.selectedMediaAssetIds.removeAll() }
        if !editor.selectedFolderIds.isEmpty { editor.selectedFolderIds.removeAll() }
    }

    func publishOrderedIds(_ ids: [String]) {
        if editor.mediaPanelOrderedIds != ids {
            editor.mediaPanelOrderedIds = ids
        }
    }
}

// MARK: - Shared scroll/grid scaffolding (folder + flat modes)

extension MediaPanelView {
    /// Shared scroll/grid/marquee scaffolding for folder and flat modes.
    @ViewBuilder
    fileprivate func gridScroll<Cell: Identifiable, Content: View>(
        cells: [Cell],
        orderedAssetIds: [String],
        cols: Int,
        tileWidth: CGFloat,
        spacing: CGFloat,
        topPadding: CGFloat,
        @ViewBuilder cellView: @escaping (Cell) -> Content
    ) -> some View where Cell.ID == String {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                let columns = [GridItem(.adaptive(minimum: thumbnailSize), spacing: spacing)]
                LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
                    ForEach(cells) { cell in
                        cellView(cell)
                            .frame(width: tileWidth)
                            .id(cell.id)
                    }
                }
                .padding(AppTheme.Spacing.md)
                .padding(.top, topPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .coordinateSpace(name: "mediaGrid")
            .onPreferenceChange(AssetFramePreferenceKey.self) { frames in
                assetFrames = frames
                if editor.mediaPanelColumnCount != cols { editor.mediaPanelColumnCount = cols }
            }
            .onAppear { publishOrderedIds(orderedAssetIds) }
            .onChange(of: orderedAssetIds) { _, ids in publishOrderedIds(ids) }
            .onChange(of: editor.mediaPanelScrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(target, anchor: .center)
                }
                editor.mediaPanelScrollTarget = nil
            }
            .onTapGesture { clearSelections() }
            .overlay { marqueeOverlay }
            .gesture(marqueeGesture)
        }
    }
}

// MARK: - Folder mode (drill-in with breadcrumb)

extension MediaPanelView {
    var mediaGridView: some View {
        GeometryReader { geo in
            let layout = computeLayout(width: geo.size.width)
            let topPadding: CGFloat = breadcrumbItems.isEmpty
                ? Layout.panelHeaderHeight + AppTheme.Spacing.sm
                : AppTheme.Spacing.xs
            gridScroll(
                cells: layout.cells,
                orderedAssetIds: layout.orderedAssetIds,
                cols: layout.cols,
                tileWidth: layout.tileWidth,
                spacing: layout.spacing,
                topPadding: topPadding
            ) { cell in
                cellView(for: cell)
            }
        }
    }
}

// MARK: - Flat mode (every asset, no folders)

extension MediaPanelView {
    var flatGridView: some View {
        let assets = sortAndFilter(editor.mediaAssets)
        let orderedIds = assets.map(\.id)
        return GeometryReader { geo in
            let dims = gridDimensions(width: geo.size.width)
            gridScroll(
                cells: assets,
                orderedAssetIds: orderedIds,
                cols: dims.cols,
                tileWidth: dims.tileWidth,
                spacing: dims.spacing,
                topPadding: Layout.panelHeaderHeight + AppTheme.Spacing.sm
            ) { asset in
                assetCellView(for: asset)
            }
        }
    }
}

// MARK: - Grouped mode (folder sections with dividers)

extension MediaPanelView {
    var groupedGridView: some View {
        // Bucket once so each section is O(1).
        let bucketed = editor.mediaAssets.reduce(into: [String?: [MediaAsset]]()) { dict, asset in
            dict[asset.folderId, default: []].append(asset)
        }
        let rootAssets = sortAndFilter(bucketed[nil] ?? [])
        // Sort by full path so parents land before children, siblings cluster.
        let allFolders = editor.folders
            .map { ($0, editor.folderPath(for: $0.id).map(\.name).joined(separator: " / ")) }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
        return GeometryReader { geo in
            let dims = gridDimensions(width: geo.size.width)
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                        if !rootAssets.isEmpty {
                            groupedSection(
                                title: "Library",
                                folderId: nil,
                                assets: rootAssets,
                                tileWidth: dims.tileWidth,
                                spacing: dims.spacing
                            )
                        }
                        ForEach(allFolders, id: \.0.id) { folder, path in
                            let assets = sortAndFilter(bucketed[folder.id] ?? [])
                            groupedSection(
                                title: path,
                                folderId: folder.id,
                                assets: assets,
                                tileWidth: dims.tileWidth,
                                spacing: dims.spacing
                            )
                        }
                    }
                    .padding(AppTheme.Spacing.md)
                    .padding(.top, Layout.panelHeaderHeight + AppTheme.Spacing.sm)
                }
                .coordinateSpace(name: "mediaGrid")
                .onPreferenceChange(AssetFramePreferenceKey.self) { frames in
                    assetFrames = frames
                }
                .onChange(of: editor.mediaPanelScrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                    editor.mediaPanelScrollTarget = nil
                }
                .onTapGesture { clearSelections() }
                .overlay { marqueeOverlay }
                .gesture(marqueeGesture)
            }
        }
    }

    @ViewBuilder
    fileprivate func groupedSection(
        title: String,
        folderId: String?,
        assets: [MediaAsset],
        tileWidth: CGFloat,
        spacing: CGFloat
    ) -> some View {
        let sectionKey = folderId ?? ""
        let isCollapsed = collapsedGroupedKeys.contains(sectionKey)
        let isTargeted = Binding<Bool>(
            get: { dropTargetGroupedKey == sectionKey },
            set: { dropTargetGroupedKey = $0 ? sectionKey : nil }
        )
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if isCollapsed { collapsedGroupedKeys.remove(sectionKey) }
                        else { collapsedGroupedKeys.insert(sectionKey) }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                        .frame(width: 14, height: 14)
                        .hoverHighlight(cornerRadius: 4)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(isCollapsed ? "Expand" : "Collapse")

                if let folderId {
                    Button {
                        currentFolderId = folderId
                        viewMode = .folder
                    } label: {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.accentColor.opacity(0.85))
                            groupedSectionTitle(title)
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .hoverHighlight(cornerRadius: 4)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help("Open \(title)")
                    .contextMenu {
                        Button("Open") {
                            currentFolderId = folderId
                            viewMode = .folder
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            editor.deleteFolders(ids: [folderId])
                        }
                    }
                } else {
                    groupedSectionTitle(title)
                }
                Text("\(assets.count)")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }

            if !isCollapsed {
                Rectangle()
                    .fill(AppTheme.Border.subtleColor)
                    .frame(height: 0.5)

                if assets.isEmpty {
                    Text("Empty")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .padding(.vertical, AppTheme.Spacing.sm)
                } else {
                    let columns = [GridItem(.adaptive(minimum: thumbnailSize), spacing: spacing)]
                    LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
                        ForEach(assets) { asset in
                            assetCellView(for: asset)
                                .frame(width: tileWidth)
                                .id(asset.id)
                        }
                    }
                }
            }
        }
        .padding(AppTheme.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(isTargeted.wrappedValue ? Color.accentColor.opacity(0.08) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(isTargeted.wrappedValue ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .text], isTargeted: isTargeted) { providers in
            handleProviderDrop(providers, into: folderId)
            return true
        }
    }

    /// Path with parent segments de-emphasized so the leaf reads as the title.
    @ViewBuilder
    fileprivate func groupedSectionTitle(_ path: String) -> some View {
        let segments = path.components(separatedBy: " / ")
        if segments.count <= 1 {
            Text(path)
                .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
        } else {
            HStack(spacing: 3) {
                ForEach(Array(segments.enumerated()), id: \.offset) { idx, segment in
                    if idx > 0 {
                        Text("/")
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.mutedColor)
                    }
                    Text(segment)
                        .font(.system(
                            size: idx == segments.count - 1 ? AppTheme.FontSize.sm : AppTheme.FontSize.xs,
                            weight: idx == segments.count - 1 ? .semibold : .regular
                        ))
                        .foregroundStyle(idx == segments.count - 1 ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                        .lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Cell renderers (asset + folder)

extension MediaPanelView {
    func assetCellView(for asset: MediaAsset) -> some View {
        AssetThumbnailView(
            asset: asset,
            onMoveToFolderMenu: AnyView(moveToFolderMenu(for: asset))
        )
        .draggable(dragPayload(for: asset)) {
            dragPreview(for: asset)
        }
        .background(assetFrameReader(for: asset.id))
    }

    @ViewBuilder
    func cellView(for cell: MediaCell) -> some View {
        switch cell.kind {
        case .folder(let folder):
            folderTile(folder)
                .background(assetFrameReader(for: cell.id))
        case .asset(let asset):
            assetCellView(for: asset)
        }
    }

    fileprivate func folderTile(_ folder: MediaFolder) -> some View {
        let dropHover = Binding<Bool>(
            get: { dropTargetFolderId == folder.id },
            set: { dropTargetFolderId = $0 ? folder.id : nil }
        )
        return FolderTileView(
            folder: folder,
            isSelected: editor.selectedFolderIds.contains(folder.id),
            isDropHover: dropTargetFolderId == folder.id,
            childCount: editor.subfolders(of: folder.id).count + editor.assetsIn(folderId: folder.id).count,
            isRenaming: Binding(
                get: { renamingFolderId == folder.id },
                set: { renamingFolderId = $0 ? folder.id : nil }
            ),
            onTap: { handleFolderTap(folder) },
            onOpen: { currentFolderId = folder.id },
            onCommitRename: { newName in
                editor.renameFolder(id: folder.id, name: newName)
                renamingFolderId = nil
            },
            onCancelRename: { renamingFolderId = nil },
            onDelete: { editor.deleteFolders(ids: [folder.id]) },
            shouldAutoFocus: pendingFolderFocusId == folder.id,
            onAutoFocusConsumed: { pendingFolderFocusId = nil }
        )
        .draggable(MediaPanelView.folderDragString(forFolderId: folder.id)) {
            FolderDragPreview(name: folder.name)
        }
        .onDrop(of: [.fileURL, .text], isTargeted: dropHover) { providers in
            handleProviderDrop(providers, into: folder.id)
            return true
        }
    }

    fileprivate func handleFolderTap(_ folder: MediaFolder) {
        let shift = NSEvent.modifierFlags.contains(.shift)
        if shift {
            if editor.selectedFolderIds.contains(folder.id) {
                editor.selectedFolderIds.remove(folder.id)
            } else {
                editor.selectedFolderIds.insert(folder.id)
            }
        } else {
            editor.selectedFolderIds = [folder.id]
            editor.selectedMediaAssetIds.removeAll()
        }
    }

    @ViewBuilder
    fileprivate func moveToFolderMenu(for asset: MediaAsset) -> some View {
        let targetIds: Set<String> = editor.selectedMediaAssetIds.contains(asset.id)
            ? editor.selectedMediaAssetIds
            : [asset.id]
        Menu("Move to Folder") {
            Button("New Folder…") {
                let id = editor.createFolder(name: "New Folder", in: currentFolderId)
                editor.moveAssetsToFolder(assetIds: targetIds, folderId: id)
                pendingFolderFocusId = id
                renamingFolderId = id
            }
            if currentFolderId != nil || targetIds.contains(where: { id in editor.mediaAssets.first(where: { $0.id == id })?.folderId != nil }) {
                Button("Library (root)") {
                    editor.moveAssetsToFolder(assetIds: targetIds, folderId: nil)
                }
            }
            Divider()
            ForEach(editor.folders, id: \.id) { folder in
                Button(folder.name) {
                    editor.moveAssetsToFolder(assetIds: targetIds, folderId: folder.id)
                }
            }
        }
    }

    func assetFrameReader(for id: String) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: AssetFramePreferenceKey.self,
                value: [id: geo.frame(in: .named("mediaGrid"))]
            )
        }
    }
}

// MARK: - File-private supporting views/types

struct AssetFramePreferenceKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct FolderDragPreview: View {
    let name: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder.fill")
                .foregroundStyle(Color.accentColor)
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
    }
}
