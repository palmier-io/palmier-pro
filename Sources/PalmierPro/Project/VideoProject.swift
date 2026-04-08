import AppKit
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

final class VideoProject: NSDocument {

    static let typeIdentifier = Project.typeIdentifier

    let editorViewModel = EditorViewModel()

    /// Decoded off-main in read(), applied on main in makeWindowControllers.
    private nonisolated(unsafe) var loadedTimeline: Timeline?

    /// Captured on main thread in save(to:) before fileWrapper runs (possibly off-main).
    private nonisolated(unsafe) var snapshotData: Data?
    private nonisolated(unsafe) var snapshotThumbnail: Data?

    // MARK: - Persistence

    override class var autosavesInPlace: Bool { true }

    override func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        guard let data = fileWrapper.fileWrappers?[Project.timelineFilename]?.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        loadedTimeline = try JSONDecoder().decode(Timeline.self, from: data)
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, completionHandler: @escaping (Error?) -> Void) {
        snapshotData = try? JSONEncoder().encode(editorViewModel.timeline)
        snapshotThumbnail = captureThumbnail()
        super.save(to: url, ofType: typeName, for: saveOperation, completionHandler: completionHandler)
    }

    override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        guard let data = snapshotData else { throw CocoaError(.fileWriteUnknown) }
        let dir = FileWrapper(directoryWithFileWrappers: [:])
        dir.addRegularFile(withContents: data, preferredFilename: Project.timelineFilename)
        if let thumb = snapshotThumbnail {
            dir.addRegularFile(withContents: thumb, preferredFilename: Project.thumbnailFilename)
        }
        return dir
    }

    // MARK: - Close

    // TODO: Test removing this override when running as .app bundle — autosavesInPlace may handle it
    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        if fileURL != nil, isDocumentEdited {
            save(withDelegate: delegate, didSave: shouldCloseSelector, contextInfo: contextInfo)
        } else {
            super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
        }
    }

    override func close() {
        super.close()
        DispatchQueue.main.async {
            if AppState.shared.activeProject === self {
                AppState.shared.showHome()
            }
        }
    }

    // MARK: - Window setup

    override func makeWindowControllers() {
        if let loaded = loadedTimeline {
            editorViewModel.timeline = loaded
            loadedTimeline = nil
        }
        editorViewModel.undoManager = undoManager

        let editorView = EditorView().environment(editorViewModel)
        let hostingController = NSHostingController(rootView: editorView)

        let window = NSWindow(contentViewController: hostingController)
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.minSize = NSSize(width: 960, height: 600)
        window.title = "Palmier Pro"
        window.setFrameAutosaveName("PalmierProWindow")
        window.appearance = NSAppearance(named: .darkAqua)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = false
        window.center()

        window.addTitlebarSwiftUI(TitleBarLeadingView(), side: .leading, width: 240)
        window.addTitlebarSwiftUI(TitleBarTrailingView().environment(editorViewModel), side: .trailing, width: 100)

        let controller = EditorWindowController(editorViewModel: editorViewModel, window: window)
        controller.shouldCascadeWindows = true
        controller.installKeyMonitor()
        addWindowController(controller)

        AppState.shared.showEditor(for: self)

        if let fileURL {
            Task { @MainActor in
                await scanMedia(projectURL: fileURL)
            }
        }
    }

    // MARK: - Thumbnail

    private var cachedThumbnail: Data?

    /// Grabs a JPEG from the first video clip's first frame. Cached after first call.
    private func captureThumbnail() -> Data? {
        if let cached = cachedThumbnail { return cached }

        for track in editorViewModel.timeline.tracks where track.type == .video {
            for clip in track.clips {
                guard let asset = editorViewModel.mediaAssets.first(where: { $0.url.lastPathComponent == clip.mediaRef }) else { continue }
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: asset.url))
                generator.maximumSize = CGSize(width: 320, height: 180)
                generator.appliesPreferredTrackTransform = true
                let time = CMTime(value: CMTimeValue(clip.trimStartFrame), timescale: CMTimeScale(editorViewModel.timeline.fps))
                if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                    let rep = NSBitmapImageRep(cgImage: cgImage)
                    cachedThumbnail = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
                    return cachedThumbnail
                }
            }
        }
        return nil
    }

    // MARK: - Media scanning


    private func scanMedia(projectURL: URL) async {
        let mediaDir = projectURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: mediaDir, includingPropertiesForKeys: nil
        ) else { return }

        for url in contents {
            guard let type = ClipType(fileExtension: url.pathExtension.lowercased()) else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            let asset = MediaAsset(url: url, type: type, name: name)
            editorViewModel.mediaAssets.append(asset)
            await asset.loadMetadata()
        }
    }
}

// MARK: - NSWindow helper

extension NSWindow {
    /// Adds a SwiftUI view as a title bar accessory.
    func addTitlebarSwiftUI<V: View>(_ view: V, side: NSLayoutConstraint.Attribute, width: CGFloat) {
        let host = NSHostingController(rootView: view)
        host.view.frame = NSRect(x: 0, y: 0, width: width, height: 28)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = host.view
        accessory.layoutAttribute = side
        addTitlebarAccessoryViewController(accessory)
    }
}
