import SwiftUI
import UniformTypeIdentifiers

struct MediaPanelView: View {
    @Environment(EditorViewModel.self) var editor
    @State private var selectedTab: ClipType = .video
    @State private var isDropTargeted = false

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
                                .draggable(asset.url.absoluteString) // drag to timeline
                        }
                    }
                    .padding(AppTheme.Spacing.md)
                }

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

    private var emptyIcon: String { selectedTab.sfSymbolName }

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

        // Load metadata async
        Task {
            await loadMetadata(for: asset)
        }
    }

    private func loadMetadata(for asset: MediaAsset) async {
        let avAsset = AVFoundation.AVURLAsset(url: asset.url)
        if asset.type == .video || asset.type == .audio {
            if let duration = try? await avAsset.load(.duration) {
                asset.duration = duration.seconds
            }
        }
        if asset.type == .image {
            asset.thumbnail = NSImage(contentsOf: asset.url)
        } else if asset.type == .video {
            let gen = AVFoundation.AVAssetImageGenerator(asset: avAsset)
            gen.maximumSize = CGSize(width: 160, height: 90)
            gen.appliesPreferredTrackTransform = true
            if let cgImage = try? await gen.image(at: .zero).image {
                asset.thumbnail = NSImage(cgImage: cgImage, size: NSSize(width: 160, height: 90))
            }
        }
    }
}

import AVFoundation
