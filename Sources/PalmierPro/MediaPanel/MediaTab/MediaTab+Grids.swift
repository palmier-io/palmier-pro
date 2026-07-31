import SwiftUI
import UniformTypeIdentifiers

// MARK: - Grid layout types

extension MediaTab {
    struct MediaCell: Identifiable {
        enum Kind { case folder(MediaFolder), timeline(Timeline), asset(MediaAsset) }
        let kind: Kind

        var id: String {
            switch kind {
            case .folder(let f): return MediaPanelItemKey.folder(f.id)
            case .timeline(let t): return MediaPanelItemKey.timeline(t.id)
            case .asset(let a): return a.id
            }
        }

        static func folderId(fromFrameKey key: String) -> String? {
            MediaPanelItemKey.folderId(from: key)
        }
    }

    struct GridLayoutInfo {
        let cols: Int
        let tileWidth: CGFloat
        let spacing: CGFloat
        let cells: [MediaCell]
        let orderedIds: [String]
    }

    struct GridDimensions {
        let cols: Int
        let tileWidth: CGFloat
        let spacing: CGFloat
    }
}

// MARK: - Layout math

extension MediaTab {
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
        for timeline in timelinesInCurrentFolder {
            cells.append(MediaCell(kind: .timeline(timeline)))
        }
        for asset in assetsInCurrentFolder {
            cells.append(MediaCell(kind: .asset(asset)))
        }
        let orderedIds = cells.map(\.id)
        return GridLayoutInfo(
            cols: dims.cols, tileWidth: dims.tileWidth, spacing: dims.spacing,
            cells: cells, orderedIds: orderedIds
        )
    }

    func publishOrderedIds(_ ids: [String]) {
        if editor.mediaPanelOrderedItemIds != ids {
            editor.mediaPanelOrderedItemIds = ids
        }
    }

    func publishGridState(orderedIds: [String], columnCount: Int) {
        publishOrderedIds(orderedIds)
        if editor.mediaPanelColumnCount != columnCount { editor.mediaPanelColumnCount = columnCount }
    }
}

// MARK: - Shared scroll/grid scaffolding (folder + flat modes)

extension MediaTab {
    /// Shared scroll/grid/marquee scaffolding for folder and flat modes.
    @ViewBuilder
    fileprivate func gridScroll<Cell: Identifiable, Content: View>(
        cells: [Cell],
        orderedIds: [String],
        cols: Int,
        tileWidth: CGFloat,
        spacing: CGFloat,
        topPadding: CGFloat,
        @ViewBuilder cellView: @escaping (Cell) -> Content
    ) -> some View where Cell.ID == String {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                let columns = Array(repeating: GridItem(.fixed(tileWidth), spacing: spacing), count: max(cols, 1))
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
            .onAppear { publishGridState(orderedIds: orderedIds, columnCount: cols) }
            .onChange(of: orderedIds) { _, ids in publishOrderedIds(ids) }
            .onChange(of: editor.mediaPanelScrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(target, anchor: .center)
                }
                editor.mediaPanelScrollTarget = nil
            }
            .onTapGesture { editor.clearMediaPanelSelection() }
            .overlay { marqueeOverlay }
            .gesture(marqueeGesture)
        }
    }
}

// MARK: - Folder mode (drill-in with breadcrumb)

extension MediaTab {
    var mediaGridView: some View {
        GeometryReader { geo in
            let layout = computeLayout(width: geo.size.width)
            gridScroll(
                cells: layout.cells,
                orderedIds: layout.orderedIds,
                cols: layout.cols,
                tileWidth: layout.tileWidth,
                spacing: layout.spacing,
                topPadding: AppTheme.Spacing.sm
            ) { cell in
                cellView(for: cell)
            }
        }
    }
}

// MARK: - Flat mode (every asset, no folders)

extension MediaTab {
    var flatGridView: some View {
        var cells = searchFilteredTimelines(editor.timelines).map { MediaCell(kind: .timeline($0)) }
        cells.append(contentsOf: sortAndFilter(editor.mediaAssets).map { MediaCell(kind: .asset($0)) })
        let orderedIds = cells.map(\.id)
        return GeometryReader { geo in
            let dims = gridDimensions(width: geo.size.width)
            gridScroll(
                cells: cells,
                orderedIds: orderedIds,
                cols: dims.cols,
                tileWidth: dims.tileWidth,
                spacing: dims.spacing,
                topPadding: AppTheme.Spacing.sm
            ) { cell in
                cellView(for: cell)
            }
        }
    }
}

// MARK: - Grouped mode (folder sections with dividers)

extension MediaTab {
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
        var orderedIds: [String] = []
        if !collapsedGroupedKeys.contains("") {
            orderedIds = filteredTimelines(in: nil).map { MediaPanelItemKey.timeline($0.id) } + rootAssets.map(\.id)
        }
        for (folder, _) in allFolders where !collapsedGroupedKeys.contains(folder.id) {
            orderedIds.append(contentsOf: filteredTimelines(in: folder.id).map { MediaPanelItemKey.timeline($0.id) })
            orderedIds.append(contentsOf: sortAndFilter(bucketed[folder.id] ?? []).map(\.id))
        }
        return GeometryReader { geo in
            let dims = gridDimensions(width: geo.size.width)
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                        let rootTimelines = filteredTimelines(in: nil)
                        if !rootAssets.isEmpty || !rootTimelines.isEmpty {
                            groupedSection(
                                title: L10n.string("Library"),
                                folderId: nil,
                                timelines: rootTimelines,
                                assets: rootAssets,
                                tileWidth: dims.tileWidth,
                                spacing: dims.spacing
                            )
                        }
                        ForEach(allFolders, id: \.0.id) { folder, path in
                            groupedSection(
                                title: path,
                                folderId: folder.id,
                                timelines: filteredTimelines(in: folder.id),
                                assets: sortAndFilter(bucketed[folder.id] ?? []),
                                tileWidth: dims.tileWidth,
                                spacing: dims.spacing
                            )
                        }
                    }
                    .padding(AppTheme.Spacing.md)
                }
                .coordinateSpace(name: "mediaGrid")
                .onPreferenceChange(AssetFramePreferenceKey.self) { frames in
                    assetFrames = frames
                    if editor.mediaPanelColumnCount != dims.cols { editor.mediaPanelColumnCount = dims.cols }
                }
                .onAppear { publishGridState(orderedIds: orderedIds, columnCount: dims.cols) }
                .onChange(of: orderedIds) { _, ids in publishOrderedIds(ids) }
                .onChange(of: editor.mediaPanelScrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                    editor.mediaPanelScrollTarget = nil
                }
                .onTapGesture { editor.clearMediaPanelSelection() }
                .overlay { marqueeOverlay }
                .gesture(marqueeGesture)
            }
        }
    }

    @ViewBuilder
    fileprivate func groupedSection(
        title: String,
        folderId: String?,
        timelines: [Timeline],
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
                        .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                        .frame(width: AppTheme.IconSize.xs, height: AppTheme.IconSize.xs)
                        .hoverHighlight(cornerRadius: AppTheme.Radius.xsSm)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(isCollapsed ? L10n.string("Expand") : L10n.string("Collapse"))

                if let folderId {
                    Button {
                        openFolder(id: folderId)
                    } label: {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Accent.primary.opacity(0.85))
                            groupedSectionTitle(title)
                        }
                        .padding(.horizontal, AppTheme.Spacing.xs)
                        .padding(.vertical, AppTheme.Spacing.xxs)
                        .hoverHighlight(cornerRadius: AppTheme.Radius.xsSm)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help(L10n.string("Open \(title)"))
                    .contextMenu {
                        Button(L10n.string("Open")) {
                            openFolder(id: folderId)
                        }
                        Divider()
                        Button(L10n.string("Delete"), role: .destructive) {
                            editor.deleteMediaPanelItems(targeting: MediaPanelItemKey.folder(folderId))
                        }
                    }
                } else {
                    groupedSectionTitle(title)
                }
                Text(verbatim: "\(timelines.count + assets.count)")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }

            if !isCollapsed {
                Rectangle()
                    .fill(AppTheme.Border.subtleColor)
                    .frame(height: 0.5)

                if assets.isEmpty && timelines.isEmpty {
                    Text(L10n.string("Empty"))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .padding(.vertical, AppTheme.Spacing.sm)
                } else {
                    let columns = [GridItem(.adaptive(minimum: thumbnailSize), spacing: spacing)]
                    LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
                        ForEach(timelines) { timeline in
                            timelineTile(timeline)
                                .background(assetFrameReader(for: MediaPanelItemKey.timeline(timeline.id)))
                                .frame(width: tileWidth)
                                .id(MediaPanelItemKey.timeline(timeline.id))
                        }
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
                .fill(isTargeted.wrappedValue ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.faint) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(isTargeted.wrappedValue ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.strong) : .clear, lineWidth: AppTheme.BorderWidth.thin)
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
            HStack(spacing: AppTheme.Spacing.xs) {
                ForEach(Array(segments.enumerated()), id: \.offset) { idx, segment in
                    if idx > 0 {
                        Text(verbatim: "/")
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

extension MediaTab {
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
        case .timeline(let timeline):
            timelineTile(timeline)
                .background(assetFrameReader(for: cell.id))
        case .asset(let asset):
            assetCellView(for: asset)
        }
    }

    fileprivate func timelineTile(_ timeline: Timeline) -> some View {
        TimelineTileView(
            timeline: timeline,
            posterImage: timelinePoster(timeline),
            isSelected: editor.selectedTimelineIds.contains(timeline.id),
            isActive: editor.activeTimelineId == timeline.id,
            canDelete: editor.timelines.count > 1,
            isRenaming: Binding(
                get: { renamingTimelineId == timeline.id },
                set: { renamingTimelineId = $0 ? timeline.id : nil }
            ),
            onTap: { handleTileTap(MediaPanelItemKey.timeline(timeline.id)) },
            onOpen: { editor.activateTimeline(timeline.id) },
            onCommitRename: { newName in
                editor.renameTimeline(timeline.id, to: newName)
                renamingTimelineId = nil
            },
            onCancelRename: { renamingTimelineId = nil },
            onDuplicate: { editor.duplicateTimeline(timeline.id) },
            onDelete: {
                editor.deleteMediaPanelItems(targeting: MediaPanelItemKey.timeline(timeline.id))
            }
        )
        .draggable(MediaTab.timelineDragString(forTimelineId: timeline.id)) {
            TileDragPreview(icon: "film.stack", name: timeline.name)
        }
    }

    /// First visual clip's cached asset thumbnail — no dedicated timeline render.
    fileprivate func timelinePoster(_ timeline: Timeline) -> NSImage? {
        for track in timeline.tracks where track.type == .video {
            for clip in track.clips where clip.mediaType == .video || clip.mediaType == .image {
                if let thumb = editor.mediaAssets.first(where: { $0.id == clip.mediaRef })?.thumbnail {
                    return thumb
                }
            }
        }
        return nil
    }

    fileprivate func handleTileTap(_ key: String) {
        editor.selectMediaPanelItem(key, mode: MediaPanelSelectionMode(modifierFlags: NSEvent.modifierFlags))
    }

    fileprivate func folderTile(_ folder: MediaFolder) -> some View {
        let dropHover = Binding<Bool>(
            get: { dropTargetFolderId == folder.id },
            set: { dropTargetFolderId = $0 ? folder.id : nil }
        )
        return ZStack {
            FolderTileView(
                folder: folder,
                isSelected: editor.selectedFolderIds.contains(folder.id),
                isDropHover: dropTargetFolderId == folder.id,
                childCount: editor.subfolders(of: folder.id).count + editor.assetsIn(folderId: folder.id).count,
                isRenaming: Binding(
                    get: { renamingFolderId == folder.id },
                    set: { renamingFolderId = $0 ? folder.id : nil }
                ),
                onTap: { handleTileTap(MediaPanelItemKey.folder(folder.id)) },
                onOpen: { openFolder(id: folder.id) },
                onCommitRename: { newName in
                    editor.renameFolder(id: folder.id, name: newName)
                    renamingFolderId = nil
                },
                onCancelRename: { renamingFolderId = nil },
                onDelete: {
                    editor.deleteMediaPanelItems(targeting: MediaPanelItemKey.folder(folder.id))
                }
            )
            .draggable(MediaTab.folderDragString(forFolderId: folder.id)) {
                TileDragPreview(icon: "folder.fill", name: folder.name)
            }
        }
        .onDrop(of: [.fileURL, .text], isTargeted: dropHover) { providers in
            handleProviderDrop(providers, into: folder.id)
            return true
        }
    }

    @ViewBuilder
    fileprivate func moveToFolderMenu(for asset: MediaAsset) -> some View {
        let targetIds: Set<String> = editor.selectedMediaAssetIds.contains(asset.id)
            ? editor.selectedMediaAssetIds
            : [asset.id]
        Menu(L10n.string("Move to Folder")) {
            Button(L10n.string("New Folder")) {
                let id = editor.createFolder(name: "New Folder", in: currentFolderId)
                editor.moveAssetsToFolder(assetIds: targetIds, folderId: id)
                renamingFolderId = id
            }
            if currentFolderId != nil || targetIds.contains(where: { id in editor.mediaAssets.first(where: { $0.id == id })?.folderId != nil }) {
                Button(L10n.string("Library")) {
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

private struct TileDragPreview: View {
    let icon: String
    let name: String
    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: icon)
                .foregroundStyle(AppTheme.Accent.primary)
            Text(name)
                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, AppTheme.Spacing.smMd)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .shadow(color: AppTheme.MediaOverlay.backgroundColor.opacity(AppTheme.Opacity.medium), radius: 4, y: 2)
    }
}
