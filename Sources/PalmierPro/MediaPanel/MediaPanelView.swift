import SwiftUI
import UniformTypeIdentifiers

struct MediaPanelView: View {
    @Environment(EditorViewModel.self) var editor
    @State private var selectedTab: ClipType = .video

    private let columns = [GridItem(.adaptive(minimum: 80), spacing: AppTheme.Spacing.md)]

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            MediaTabBar(selected: $selectedTab)
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.vertical, AppTheme.Spacing.xs)
                .background(.ultraThinMaterial)

            // Asset grid
            ScrollView {
                if filteredAssets.isEmpty {
                    ContentUnavailableView {
                        Label("No \(selectedTab.rawValue) assets", systemImage: emptyIcon)
                    } description: {
                        Text("Import or drag files here")
                    }
                    .padding(.top, 40)
                } else {
                    LazyVGrid(columns: columns, spacing: AppTheme.Spacing.md) {
                        ForEach(filteredAssets) { asset in
                            AssetThumbnailView(asset: asset)
                                .draggable(asset.url.absoluteString) // drag to timeline
                        }
                    }
                    .padding(AppTheme.Spacing.md)
                }
            }

            Rectangle()
                .fill(AppTheme.Border.subtleColor)
                .frame(height: 0.5)

            // Import button
            Button {
                importMedia()
            } label: {
                Label("Import", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(AppTheme.Spacing.md)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
            return true
        }
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
