import SwiftUI
import UniformTypeIdentifiers

struct MediaPanelView: View {
    @Environment(EditorViewModel.self) var editor
    @State private var selectedTab: ClipType = .video
    @State private var isDropTargeted = false
    @State private var assetFrames: [String: CGRect] = [:]
    @State private var marqueeRect: CGRect? = nil
    @State private var marqueeActive = false
    @State private var marqueeShiftHeld = false
    @State private var marqueeBaseSelection: Set<String> = []

    private let columns = [GridItem(.adaptive(minimum: 80), spacing: AppTheme.Spacing.md)]

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            MediaTabBar(selected: $selectedTab)
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.vertical, AppTheme.Spacing.xs)
                .background(.ultraThinMaterial)

            // Asset grid or empty state
            if filteredAssets.isEmpty {
                emptyStateView
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: AppTheme.Spacing.md) {
                        ForEach(filteredAssets) { asset in
                            AssetThumbnailView(asset: asset)
                                .draggable(dragPayload(for: asset)) {
                                    dragPreview(for: asset)
                                }
                                .background(
                                    GeometryReader { geo in
                                        Color.clear.preference(
                                            key: AssetFramePreferenceKey.self,
                                            value: [asset.id: geo.frame(in: .named("mediaGrid"))]
                                        )
                                    }
                                )
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

                Rectangle()
                    .fill(AppTheme.Border.subtleColor)
                    .frame(height: 0.5)

                // Import button only when assets exist
                Button {
                    importMedia()
                } label: {
                    Label("Import", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(AppTheme.Spacing.md)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
            return true
        }
        .overlay {
            if isDropTargeted {
                dropHighlight
            }
        }
        .onChange(of: selectedTab) {
            editor.selectedMediaAssetIds.removeAll()
        }
    }

    // MARK: - Multi-drag payload

    private func dragPayload(for asset: MediaAsset) -> String {
        if editor.selectedMediaAssetIds.contains(asset.id) {
            let selectedInOrder = filteredAssets.filter { editor.selectedMediaAssetIds.contains($0.id) }
            return selectedInOrder.map(\.url.absoluteString).joined(separator: "\n")
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
                if !marqueeActive {
                    let startOnAsset = assetFrames.values.contains { $0.contains(value.startLocation) }
                    if startOnAsset { return }
                    marqueeActive = true
                    marqueeShiftHeld = NSEvent.modifierFlags.contains(.shift)
                    marqueeBaseSelection = marqueeShiftHeld ? editor.selectedMediaAssetIds : []
                }
                let rect = CGRect(
                    x: min(value.startLocation.x, value.location.x),
                    y: min(value.startLocation.y, value.location.y),
                    width: abs(value.location.x - value.startLocation.x),
                    height: abs(value.location.y - value.startLocation.y)
                )
                marqueeRect = rect
                var ids = marqueeBaseSelection
                for (id, frame) in assetFrames {
                    if rect.intersects(frame) {
                        ids.insert(id)
                    }
                }
                if ids != editor.selectedMediaAssetIds {
                    editor.selectedMediaAssetIds = ids
                }
            }
            .onEnded { _ in
                marqueeRect = nil
                marqueeActive = false
            }
    }

    @ViewBuilder
    private var marqueeOverlay: some View {
        if let rect = marqueeRect {
            Rectangle()
                .stroke(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .background(Rectangle().fill(Color.white.opacity(0.1)))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: AppTheme.Spacing.lg) {
            Spacer()

            // Icon with accent tint
            Image(systemName: selectedTab.sfSymbolName)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color(nsColor: selectedTab.themeColor).opacity(0.7))

            VStack(spacing: AppTheme.Spacing.xs) {
                Text("Add \(selectedTab.rawValue) files")
                    .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)

                Text("Drop files here or import from disk")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }

            Button {
                importMedia()
            } label: {
                Label("Import Media", systemImage: "plus")
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                    .padding(.horizontal, AppTheme.Spacing.lg)
                    .padding(.vertical, AppTheme.Spacing.sm)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(Color(nsColor: selectedTab.themeColor))

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Drop Highlight

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: AppTheme.Radius.md)
            .strokeBorder(
                Color(nsColor: selectedTab.themeColor).opacity(0.6),
                style: StrokeStyle(lineWidth: 2, dash: [8, 4])
            )
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .fill(Color(nsColor: selectedTab.themeColor).opacity(0.05))
            )
            .padding(4)
    }

    private var filteredAssets: [MediaAsset] {
        editor.mediaAssets.filter { $0.type == selectedTab }
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
        editor.mediaAssets.append(asset)

        Task {
            await asset.loadMetadata()
            if asset.type == .audio || asset.type == .video {
                editor.mediaVisualCache.generateWaveform(for: asset)
            }
            if asset.type == .video {
                editor.mediaVisualCache.generateThumbnails(for: asset, fps: editor.timeline.fps)
            }
        }
    }
}

// MARK: - Preference Key for asset frame tracking

private struct AssetFramePreferenceKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
