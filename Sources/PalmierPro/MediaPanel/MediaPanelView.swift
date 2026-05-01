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
    @State private var expandedStacks: Set<String> = []

    private static let minThumbnailSize: Double = 72
    private static let maxThumbnailSize: Double = 220

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
        editor.mediaAssets
            .filter { editor.selectedMediaAssetIds.contains($0.id) }
            .map { asset in
                if asset.parentAssetId == nil,
                   editor.variantCount(ofStackRootId: asset.id) > 1,
                   let cover = editor.coverVariant(forStackRootId: asset.id) {
                    return cover
                }
                return asset
            }
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
        let roots = editor.mediaAssets.filter { $0.parentAssetId == nil }
        let filtered = roots.filter { root in
            let typeOk = filterTypes.isEmpty || filterTypes.contains(root.type)
            let aiOk = !filterAI
                || root.isGenerated
                || editor.mediaAssets.contains { $0.parentAssetId == root.id }
            return typeOk && aiOk
        }

        return switch sortMode {
        case .dateAdded:
            filtered
        case .name:
            filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .duration:
            filtered.sorted { $0.duration > $1.duration }
        case .type:
            filtered.sorted { $0.type.rawValue < $1.type.rawValue }
        }
    }

    private struct MediaCell: Identifiable {
        enum Kind { case root, variant }
        let asset: MediaAsset
        let kind: Kind
        let stackRootId: String
        let variantCount: Int
        let isStackExpanded: Bool
        let variantIndex: Int
        let isTimelineVariant: Bool

        var id: String { asset.id }
    }

    private struct GridLayoutInfo {
        let cols: Int
        let tileWidth: CGFloat
        let spacing: CGFloat
        let rows: [Row]
        let orderedIds: [String]
        let buckets: [String: [MediaAsset]]
        /// Number of variants of each stack currently referenced by the timeline.
        let timelineCountByStack: [String: Int]

        struct Row: Identifiable {
            let id: Int
            let roots: [MediaCell]
            let expandedStacks: [ExpandedStack]
        }

        struct ExpandedStack: Identifiable {
            let rootId: String
            let root: MediaAsset
            let cells: [MediaCell]
            var id: String { rootId }
        }
    }

    private func bucketByStack() -> [String: [MediaAsset]] {
        var buckets: [String: [MediaAsset]] = [:]
        for asset in editor.mediaAssets {
            let rootId = asset.parentAssetId ?? asset.id
            buckets[rootId, default: []].append(asset)
        }
        return buckets
    }

    private func collectTimelineRefs() -> Set<String> {
        var refs: Set<String> = []
        for track in editor.timeline.tracks {
            for clip in track.clips { refs.insert(clip.mediaRef) }
        }
        return refs
    }

    private func rootCells(buckets: [String: [MediaAsset]], timelineRefs: Set<String>) -> [MediaCell] {
        filteredAndSortedAssets.map { root in
            let count = buckets[root.id]?.count ?? 1
            let expanded = count > 1 && expandedStacks.contains(root.id)
            return MediaCell(
                asset: root, kind: .root, stackRootId: root.id,
                variantCount: count, isStackExpanded: expanded,
                variantIndex: 0, isTimelineVariant: timelineRefs.contains(root.id)
            )
        }
    }

    private func variantCells(forStackRootId rootId: String, buckets: [String: [MediaAsset]], timelineRefs: Set<String>) -> [MediaCell] {
        guard let members = buckets[rootId], let root = members.first(where: { $0.id == rootId }) else {
            return []
        }
        let total = members.count
        let children = members.filter { $0.id != rootId }.sortedByGenerationDate()
        var cells: [MediaCell] = [
            MediaCell(
                asset: root, kind: .variant, stackRootId: rootId,
                variantCount: total, isStackExpanded: true,
                variantIndex: 1, isTimelineVariant: timelineRefs.contains(rootId)
            )
        ]
        for (i, child) in children.enumerated() {
            cells.append(MediaCell(
                asset: child, kind: .variant, stackRootId: rootId,
                variantCount: total, isStackExpanded: true,
                variantIndex: i + 2, isTimelineVariant: timelineRefs.contains(child.id)
            ))
        }
        return cells
    }

    private func toggleStackExpansion(_ rootId: String) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if expandedStacks.contains(rootId) {
                _ = expandedStacks.remove(rootId)
            } else {
                _ = expandedStacks.insert(rootId)
            }
        }
    }

    private func computeLayout(width: CGFloat) -> GridLayoutInfo {
        let spacing = AppTheme.Spacing.xl
        let outerPadding: CGFloat = AppTheme.Spacing.md * 2
        let usable = max(0, width - outerPadding)
        let minTile = thumbnailSize
        let cols = max(1, Int(floor((usable + spacing) / (minTile + spacing))))
        let tileWidth = max(minTile, (usable - CGFloat(cols - 1) * spacing) / CGFloat(cols))

        let buckets = bucketByStack()
        let timelineRefs = collectTimelineRefs()
        var timelineCountByStack: [String: Int] = [:]
        for (rootId, members) in buckets {
            timelineCountByStack[rootId] = members.reduce(0) { $0 + (timelineRefs.contains($1.id) ? 1 : 0) }
        }
        let roots = rootCells(buckets: buckets, timelineRefs: timelineRefs)
        var rows: [GridLayoutInfo.Row] = []
        var ordered: [String] = []
        var rowIndex = 0
        var index = 0
        while index < roots.count {
            let end = min(index + cols, roots.count)
            let rowRoots = Array(roots[index..<end])
            ordered.append(contentsOf: rowRoots.map(\.id))
            var expandedStacks: [GridLayoutInfo.ExpandedStack] = []
            for rowCell in rowRoots where rowCell.isStackExpanded {
                let rootId = rowCell.stackRootId
                let cells = variantCells(forStackRootId: rootId, buckets: buckets, timelineRefs: timelineRefs)
                // v1 in the strip shares its asset.id with the row tile.
                ordered.append(contentsOf: cells.map(\.id).filter { $0 != rootId })
                expandedStacks.append(.init(rootId: rootId, root: rowCell.asset, cells: cells))
            }
            rows.append(.init(id: rowIndex, roots: rowRoots, expandedStacks: expandedStacks))
            index = end
            rowIndex += 1
        }
        return GridLayoutInfo(
            cols: cols, tileWidth: tileWidth, spacing: spacing,
            rows: rows, orderedIds: ordered, buckets: buckets,
            timelineCountByStack: timelineCountByStack
        )
    }

    private var mediaGridView: some View {
        GeometryReader { geo in
            let layout = computeLayout(width: geo.size.width)
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                        ForEach(layout.rows) { row in
                            rowView(row, layout: layout)
                            ForEach(row.expandedStacks) { stack in
                                variantTray(stack, layout: layout)
                            }
                        }
                    }
                    .padding(AppTheme.Spacing.md)
                    .padding(.top, Layout.panelHeaderHeight + AppTheme.Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .coordinateSpace(name: "mediaGrid")
                .onPreferenceChange(AssetFramePreferenceKey.self) { frames in
                    assetFrames = frames
                    if editor.mediaPanelColumnCount != layout.cols {
                        editor.mediaPanelColumnCount = layout.cols
                    }
                }
                .onAppear {
                    editor.mediaPanelOrderedIds = layout.orderedIds
                }
                .onChange(of: layout.orderedIds) { _, ids in
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
    }

    private func rowView(_ row: GridLayoutInfo.Row, layout: GridLayoutInfo) -> some View {
        HStack(alignment: .top, spacing: layout.spacing) {
            ForEach(row.roots) { cell in
                assetCell(for: cell, layout: layout)
                    .frame(width: layout.tileWidth)
                    .id(cell.id)
            }
            if row.roots.count < layout.cols {
                Spacer(minLength: 0)
            }
        }
    }

    private func variantTray(_ stack: GridLayoutInfo.ExpandedStack, layout: GridLayoutInfo) -> some View {
        let trayColumns = [GridItem(.adaptive(minimum: thumbnailSize), spacing: layout.spacing)]
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 9))
                Text("\(stack.cells.count) variants of \(stack.root.name)")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        _ = expandedStacks.remove(stack.rootId)
                    }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .hoverHighlight()
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Collapse stack")
            }
            .foregroundStyle(AppTheme.Text.tertiaryColor)

            LazyVGrid(columns: trayColumns, alignment: .leading, spacing: layout.spacing) {
                ForEach(stack.cells) { cell in
                    assetCell(for: cell, layout: layout)
                        .id(cell.id)
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .fill(Color(white: 1.0, opacity: 0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: 0.5)
        )
        .transition(AnyTransition.opacity.combined(with: .move(edge: .top)))
    }

    private func assetCell(for cell: MediaCell, layout: GridLayoutInfo) -> some View {
        // Collapsed stack covers redirect to the active timeline variant; everything else shows itself.
        let cover: MediaAsset = {
            if cell.kind == .root, !cell.isStackExpanded, cell.variantCount > 1 {
                return editor.coverVariant(forStackRootId: cell.stackRootId) ?? cell.asset
            }
            return cell.asset
        }()
        return AssetThumbnailView(
            asset: cell.asset,
            coverAsset: cover,
            stackContext: stackContext(for: cell),
            onToggleExpand: cell.kind == .root && cell.variantCount > 1
                ? { toggleStackExpansion(cell.stackRootId) } : nil,
            onUseVariantInTimeline: retargetCallback(for: cell, layout: layout),
            onGroupAsStack: groupCallback(for: cell),
            onRemoveFromStack: removeFromStackCallback(for: cell)
        )
        .draggable(dragPayload(for: cover, selectionId: cell.asset.id)) {
            dragPreview(for: cover, selectionId: cell.asset.id)
        }
        .background(assetFrameReader(for: cell.asset))
    }

    /// nil when the retarget would be a no-op or doesn't apply to this cell.
    private func retargetCallback(for cell: MediaCell, layout: GridLayoutInfo) -> (() -> Void)? {
        let count = layout.timelineCountByStack[cell.stackRootId] ?? 0
        guard count > 0 else { return nil }
        if count == 1 && cell.isTimelineVariant { return nil }
        let promotable = cell.kind == .variant
            || (cell.kind == .root && cell.isStackExpanded && cell.variantCount > 1)
        guard promotable else { return nil }
        return { editor.retargetStack(rootId: cell.stackRootId, to: cell.asset.id) }
    }

    private func groupCallback(for cell: MediaCell) -> (() -> Void)? {
        let ids = contextTargetIds(for: cell.asset.id)
        guard ids.count >= 2 else { return nil }
        let types = Set(ids.compactMap { id in
            editor.mediaAssets.first(where: { $0.id == id })?.type
        })
        guard types.count == 1 else { return nil }
        return { [editor] in editor.groupAsStack(assetIds: Set(ids), targetTileId: cell.asset.id) }
    }

    private func removeFromStackCallback(for cell: MediaCell) -> (() -> Void)? {
        let ids = contextTargetIds(for: cell.asset.id)
        let removable = ids.filter { id in
            editor.mediaAssets.first(where: { $0.id == id })?.parentAssetId != nil
        }
        guard !removable.isEmpty else { return nil }
        return { [editor] in editor.removeFromStack(assetIds: Set(removable)) }
    }

    private func contextTargetIds(for assetId: String) -> [String] {
        if editor.selectedMediaAssetIds.contains(assetId) {
            return Array(editor.selectedMediaAssetIds)
        }
        return [assetId]
    }

    private func stackContext(for cell: MediaCell) -> AssetThumbnailView.StackContext {
        switch cell.kind {
        case .root:
            return .root(variantCount: cell.variantCount, isExpanded: cell.isStackExpanded)
        case .variant:
            return .variant(index: cell.variantIndex, total: cell.variantCount)
        }
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

    private func dragPayload(for asset: MediaAsset, selectionId: String? = nil) -> String {
        if editor.selectedMediaAssetIds.contains(selectionId ?? asset.id) {
            return selectedMediaAssetsInOrder.map(\.url.absoluteString).joined(separator: "\n")
        }
        return asset.url.absoluteString
    }

    // MARK: - Drag Preview

    @ViewBuilder
    private func dragPreview(for asset: MediaAsset, selectionId: String? = nil) -> some View {
        let count = editor.selectedMediaAssetIds.contains(selectionId ?? asset.id) ? editor.selectedMediaAssetIds.count : 1
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
