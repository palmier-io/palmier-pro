import AVFoundation
import SwiftUI

extension MediaTab {
    var trimmedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var searchResults: some View {
        let nameMatches = sortAndFilter(editor.mediaAssets)
        let timelineMatches = searchFilteredTimelines(editor.timelines)
        let orderedItemIds = Self.searchOrderedItemIds(
            momentAssetIds: visualHits.map(\.assetID),
            spokenAssetIds: spokenHits.map(\.assetID),
            timelineItemIds: timelineMatches.map { MediaPanelItemKey.timeline($0.id) },
            fileAssetIds: nameMatches.map(\.id),
            collapsedSectionTitles: collapsedSearchSections
        )
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !visualHits.isEmpty {
                    momentHeader(L10n.key("Moments"), icon: "sparkle.magnifyingglass", count: visualHits.count, collapsible: true)
                    if !collapsedSearchSections.contains(L10n.key("Moments")) {
                        resultsGrid { ForEach(visualHits.indices, id: \.self) { momentCard(visualHits[$0]) } }
                    }
                }
                if !spokenHits.isEmpty {
                    momentHeader(L10n.key("Spoken"), icon: "waveform", count: spokenHits.count, collapsible: true)
                    if !collapsedSearchSections.contains(L10n.key("Spoken")) {
                        VStack(spacing: AppTheme.Spacing.sm) {
                            ForEach(spokenHits.indices, id: \.self) { spokenRow(spokenHits[$0]) }
                        }
                        .padding(.bottom, AppTheme.Spacing.sm)
                    }
                }
                if !timelineMatches.isEmpty {
                    momentHeader(L10n.key("Timelines"), icon: "film.stack", count: timelineMatches.count)
                    resultsGrid {
                        ForEach(timelineMatches) { timeline in
                            timelineTile(timeline)
                                .id(MediaPanelItemKey.timeline(timeline.id))
                        }
                    }
                }
                if !nameMatches.isEmpty {
                    momentHeader(L10n.key("Files"), icon: "doc", count: nameMatches.count)
                    resultsGrid { ForEach(nameMatches) { fileCard($0) } }
                }
                if visualHits.isEmpty, spokenHits.isEmpty, timelineMatches.isEmpty, nameMatches.isEmpty {
                    Text(L10n.string("No matches for “\(trimmedSearchQuery)”"))
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .frame(maxWidth: .infinity)
                        .padding(.top, AppTheme.Spacing.xl)
                }
            }
            .padding(.top, AppTheme.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { publishGridState(orderedIds: orderedItemIds, columnCount: 1) }
        .onChange(of: orderedItemIds) { _, ids in publishOrderedIds(ids) }
    }

    static func searchOrderedItemIds(
        momentAssetIds: [String],
        spokenAssetIds: [String],
        timelineItemIds: [String],
        fileAssetIds: [String],
        collapsedSectionTitles: Set<String>
    ) -> [String] {
        let sections = [
            collapsedSectionTitles.contains(L10n.key("Moments")) ? [] : momentAssetIds,
            collapsedSectionTitles.contains(L10n.key("Spoken")) ? [] : spokenAssetIds,
            timelineItemIds,
            fileAssetIds,
        ]
        var seen: Set<String> = []
        return sections.joined().filter { seen.insert($0).inserted }
    }

    private func resultsGrid<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: CGFloat(thumbnailSize) * 1.4), spacing: AppTheme.Spacing.sm)],
            alignment: .leading,
            spacing: AppTheme.Spacing.md,
            content: content
        )
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.bottom, AppTheme.Spacing.md)
    }

    private func momentHeader(_ title: String, icon: String, count: Int, collapsible: Bool = false) -> some View {
        let isCollapsed = collapsedSearchSections.contains(title)
        return Button {
            guard collapsible else { return }
            withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) {
                if isCollapsed { collapsedSearchSections.remove(title) }
                else { collapsedSearchSections.insert(title) }
            }
        } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                if collapsible {
                    Image(systemName: "chevron.down")
                        .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                }
                Image(systemName: icon)
                    .font(.system(size: AppTheme.FontSize.xs))
                Text(L10n.string(key: title))
                    .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                Text(verbatim: "\(count)")
                    .font(.system(size: AppTheme.FontSize.xs).monospacedDigit())
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                Spacer()
            }
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .padding(.horizontal, AppTheme.Spacing.mdLg)
            .padding(.vertical, AppTheme.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!collapsible)
    }

    // MARK: - Rows

    private func momentCard(_ hit: VisualSearch.Hit) -> some View {
        let asset = editor.mediaAssets.first { $0.id == hit.assetID }
        let isImage = asset?.type == .image
        let range = hit.shotStart...max(hit.shotEnd, hit.shotStart + 0.1)
        // Stills drag as plain assets; a source segment is meaningless for them.
        let payload = isImage
            ? MediaTab.assetDragString(forAssetId: hit.assetID)
            : MediaTab.assetDragString(forAssetId: hit.assetID, segment: range)
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            momentThumb(asset, time: hit.time)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            Text(verbatim: asset?.name ?? String())
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)
            if !isImage {
                Text(verbatim: "\(timecode(range.lowerBound))–\(timecode(range.upperBound))")
                    .font(.system(size: AppTheme.FontSize.xxs).monospacedDigit())
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
        .draggable(payload) {
            momentThumb(asset, time: hit.time)
                .frame(width: 80, height: 45)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        }
        .overlay { searchSelectionBorder(for: hit.assetID) }
        .onTapGesture { selectSearchHit(assetID: hit.assetID, atSeconds: range.lowerBound) }
    }

    @ViewBuilder
    private func momentThumb(_ asset: MediaAsset?, time: Double) -> some View {
        if let asset, asset.type == .image {
            ZStack {
                Rectangle().fill(AppTheme.MediaOverlay.backgroundColor)
                if let thumb = asset.thumbnail {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(AppTheme.MediaOverlay.tertiaryColor)
                }
            }
            .task(id: searchThumbnailTaskID(for: asset)) {
                await loadSearchThumbnail(asset)
            }
        } else {
            MomentThumbnail(url: asset?.url, time: time)
        }
    }

    private func spokenRow(_ hit: TranscriptSearch.Hit) -> some View {
        let asset = editor.mediaAssets.first { $0.id == hit.assetID }
        let range = hit.start...max(hit.end, hit.start + 0.1)
        let thumbW = CGFloat(thumbnailSize) * 1.4
        return HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            MomentThumbnail(url: asset?.url, time: hit.start)
                .frame(width: thumbW, height: thumbW * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(hit.text)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(3)
                Text(verbatim: "\(asset?.name ?? "") · \(timecode(hit.start))")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .contentShape(Rectangle())
        .draggable(MediaTab.assetDragString(forAssetId: hit.assetID, segment: range)) {
            MomentThumbnail(url: asset?.url, time: hit.start)
                .frame(width: 80, height: 45)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        }
        .overlay { searchSelectionBorder(for: hit.assetID) }
        .onTapGesture { selectSearchHit(assetID: hit.assetID, atSeconds: range.lowerBound) }
    }

    private func fileCard(_ asset: MediaAsset) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            ZStack {
                Rectangle().fill(AppTheme.MediaOverlay.backgroundColor)
                if let thumb = asset.thumbnail {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: asset.type.sfSymbolName)
                        .foregroundStyle(AppTheme.MediaOverlay.tertiaryColor)
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            Text(asset.name)
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)
        }
        .draggable(dragPayload(for: asset)) { dragPreview(for: asset) }
        .overlay { searchSelectionBorder(for: asset.id) }
        .onTapGesture { selectSearchHit(assetID: asset.id, atSeconds: 0) }
        .task(id: searchThumbnailTaskID(for: asset)) {
            await loadSearchThumbnail(asset)
        }
    }

    private func searchThumbnailTaskID(for asset: MediaAsset) -> String {
        "\(asset.id)|\(asset.url.path)|\(asset.generationStatus.serialized)|\(editor.isMediaOffline(asset.id))"
    }

    private func loadSearchThumbnail(_ asset: MediaAsset) async {
        guard case .none = asset.generationStatus, !editor.isMediaOffline(asset.id) else { return }
        await asset.loadLibraryThumbnail()
    }

    private func searchSelectionBorder(for assetID: String) -> some View {
        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
            .strokeBorder(editor.selectedMediaAssetIds.contains(assetID) ? AppTheme.Accent.primary : .clear,
                          lineWidth: AppTheme.BorderWidth.medium)
            .allowsHitTesting(false)
    }

    private func selectSearchHit(assetID: String, atSeconds seconds: Double) {
        editor.selectMediaPanelItem(
            assetID,
            mode: MediaPanelSelectionMode(modifierFlags: NSEvent.modifierFlags),
            atSourceFrame: secondsToFrame(seconds: seconds, fps: editor.timeline.fps)
        )
    }

    private func timecode(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Query execution

    func scheduleMomentSearch() {
        momentSearchTask?.cancel()
        let query = trimmedSearchQuery
        guard !query.isEmpty else {
            visualHits = []
            spokenHits = []
            return
        }
        let assets = editor.mediaAssets
            .filter { $0.type == .video || $0.type == .audio }
            .map { (id: $0.id, url: $0.url) }
        let coordinator = editor.searchIndex
        momentSearchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let spoken = TranscriptSearch.search(query: query, assets: assets)
            let visual = await coordinator.search(query: query)
            guard !Task.isCancelled else { return }
            visualHits = visual
            spokenHits = spoken
        }
    }
}

/// Async frame thumbnail for a search hit.
private struct MomentThumbnail: View {
    let url: URL?
    let time: Double
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(AppTheme.MediaOverlay.backgroundColor)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .task(id: "\(url?.path ?? "")@\(time)") {
            guard let url else { return }
            image = await Self.thumbnail(url: url, time: time)
        }
    }

    private static func thumbnail(url: URL, time: Double) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.loadTracks(withMediaType: .video).first) != nil else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        return try? await generator.image(at: cmTime).image
    }
}
