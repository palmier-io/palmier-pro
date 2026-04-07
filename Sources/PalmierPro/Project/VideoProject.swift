import AppKit
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

final class VideoProject: NSDocument {

    let editorViewModel = EditorViewModel()

    /// Timeline decoded in read(from:ofType:), applied on main in makeWindowControllers
    private nonisolated(unsafe) var loadedTimeline: Timeline?

    // MARK: - NSDocument overrides

    override class var autosavesInPlace: Bool { true }

    override func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        guard let projectData = fileWrapper.fileWrappers?["project.json"]?.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        loadedTimeline = try JSONDecoder().decode(Timeline.self, from: projectData)
    }

    override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        let dir = FileWrapper(directoryWithFileWrappers: [:])
        let data = try JSONEncoder().encode(editorViewModel.timeline)
        dir.addRegularFile(withContents: data, preferredFilename: "project.json")
        // media/ folder is managed on disk alongside project.json — FileWrapper picks it up automatically
        return dir
    }

    override func makeWindowControllers() {
        // Apply any timeline loaded from disk, or create default tracks
        if let loaded = loadedTimeline {
            editorViewModel.timeline = loaded
            loadedTimeline = nil
        } else if editorViewModel.timeline.tracks.isEmpty {
            editorViewModel.timeline.tracks = [
                Track(type: .video, label: "Video 1"),
                Track(type: .audio, label: "Audio 1"),
            ]
        }
        editorViewModel.undoManager = undoManager

        let editorView = EditorView()
            .environment(editorViewModel)

        let hostingController = NSHostingController(rootView: editorView)
        let window = NSWindow(contentViewController: hostingController)
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.minSize = NSSize(width: 960, height: 600)
        window.title = "Palmier Pro"
        window.setFrameAutosaveName("PalmierProWindow")
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()

        let controller = EditorWindowController(editorViewModel: editorViewModel, window: window)
        controller.shouldCascadeWindows = true
        controller.installKeyMonitor()
        addWindowController(controller)

        // Scan media/ folder if opening an existing project
        if let fileURL {
            Task { @MainActor in
                await scanMedia(projectURL: fileURL)
            }
        }
    }

    // MARK: - Media scanning

    private func scanMedia(projectURL: URL) async {
        let mediaDir = projectURL.appendingPathComponent("media", isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: mediaDir, includingPropertiesForKeys: nil
        ) else { return }

        for url in contents {
            let ext = url.pathExtension.lowercased()
            guard let type = clipType(for: ext) else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            let asset = MediaAsset(url: url, type: type, name: name)
            editorViewModel.mediaAssets.append(asset)
            await loadAssetMetadata(asset)
        }
    }

    private func loadAssetMetadata(_ asset: MediaAsset) async {
        let avAsset = AVURLAsset(url: asset.url)
        if asset.type == .video || asset.type == .audio {
            if let duration = try? await avAsset.load(.duration) {
                asset.duration = duration.seconds
            }
        }
        if asset.type == .video || asset.type == .image {
            await generateThumbnail(for: asset)
        }
    }

    private func clipType(for ext: String) -> ClipType? {
        ClipType(fileExtension: ext)
    }

    private func generateThumbnail(for asset: MediaAsset) async {
        if asset.type == .image {
            asset.thumbnail = NSImage(contentsOf: asset.url)
            return
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: asset.url))
        generator.maximumSize = CGSize(width: 160, height: 90)
        generator.appliesPreferredTrackTransform = true
        if let cgImage = try? await generator.image(at: .zero).image {
            asset.thumbnail = NSImage(cgImage: cgImage, size: NSSize(width: 160, height: 90))
        }
    }
}
