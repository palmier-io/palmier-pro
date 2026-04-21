import AppKit
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

final class VideoProject: NSDocument {

    static let typeIdentifier = Project.typeIdentifier

    let editorViewModel = EditorViewModel()
    private var mcpService: MCPService?

    /// Decoded off-main in read(), applied on main in makeWindowControllers.
    private nonisolated(unsafe) var loadedTimeline: Timeline?
    private nonisolated(unsafe) var loadedManifest: MediaManifest?

    private nonisolated(unsafe) var packageWrapper = FileWrapper(directoryWithFileWrappers: [:])

    /// Captured on main thread in save(to:) before fileWrapper runs (possibly off-main).
    private nonisolated(unsafe) var snapshotTimeline: Data?
    private nonisolated(unsafe) var snapshotManifest: Data?
    private nonisolated(unsafe) var snapshotThumbnail: Data?
    private nonisolated(unsafe) var snapshotChatSessionFiles: [(name: String, data: Data)] = []

    // MARK: - Persistence

    override class var autosavesInPlace: Bool { true }

    override func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        guard let data = fileWrapper.fileWrappers?[Project.timelineFilename]?.regularFileContents else {
            Log.project.error("read: missing \(Project.timelineFilename) in package")
            throw CocoaError(.fileReadCorruptFile)
        }
        packageWrapper = fileWrapper
        do {
            loadedTimeline = try JSONDecoder().decode(Timeline.self, from: data)
        } catch {
            Log.project.error("read: timeline decode failed: \(error.localizedDescription)")
            throw error
        }
        if let manifestData = fileWrapper.fileWrappers?[Project.manifestFilename]?.regularFileContents {
            loadedManifest = try? JSONDecoder().decode(MediaManifest.self, from: manifestData)
        }
        Log.project.notice("read ok tracks=\(self.loadedTimeline?.tracks.count ?? 0)")
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, completionHandler: @escaping (Error?) -> Void) {
        if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            fileModificationDate = date
        }

        snapshotTimeline = try? JSONEncoder().encode(editorViewModel.timeline)
        snapshotManifest = try? JSONEncoder().encode(editorViewModel.mediaManifest)
        snapshotThumbnail = captureThumbnail()
        snapshotChatSessionFiles = editorViewModel.agentService.sessions.compactMap { session in
            ChatSessionStore.encodeSession(session).map { (name: "\(session.id.uuidString).json", data: $0) }
        }
        super.save(to: url, ofType: typeName, for: saveOperation, completionHandler: completionHandler)
    }

    override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        guard let data = snapshotTimeline else {
            Log.project.error("save: snapshotTimeline missing at fileWrapper()")
            throw CocoaError(.fileWriteUnknown)
        }

        replaceChild(Project.timelineFilename, with: data)
        if let manifest = snapshotManifest { replaceChild(Project.manifestFilename, with: manifest) }
        if let thumb = snapshotThumbnail { replaceChild(Project.thumbnailFilename, with: thumb) }
        replaceChild(ChatSessionStore.dirName, with: chatDirWrapper())
        if let mediaDir = mediaDirWrapper() { replaceChild(Project.mediaDirectoryName, with: mediaDir) }

        return packageWrapper
    }

    private func mediaDirWrapper() -> FileWrapper? {
        guard let projectURL = fileURL else { return nil }
        let mediaDir = projectURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: mediaDir.path) else { return nil }
        return try? FileWrapper(url: mediaDir, options: .immediate)
    }

    private nonisolated func chatDirWrapper() -> FileWrapper {
        let dir = FileWrapper(directoryWithFileWrappers: [:])
        for file in snapshotChatSessionFiles {
            let child = FileWrapper(regularFileWithContents: file.data)
            child.preferredFilename = file.name
            dir.addFileWrapper(child)
        }
        dir.preferredFilename = ChatSessionStore.dirName
        return dir
    }

    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        editorViewModel.isDocumentEdited = isDocumentEdited
    }

    override func updateChangeCount(withToken changeCountToken: Any, for saveOperation: NSDocument.SaveOperationType) {
        super.updateChangeCount(withToken: changeCountToken, for: saveOperation)
        editorViewModel.isDocumentEdited = isDocumentEdited
    }

    private nonisolated func replaceChild(_ name: String, with data: Data) {
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = name
        replaceChild(name, with: wrapper)
    }

    private nonisolated func replaceChild(_ name: String, with wrapper: FileWrapper) {
        if let old = packageWrapper.fileWrappers?[name] {
            packageWrapper.removeFileWrapper(old)
        }
        wrapper.preferredFilename = name
        packageWrapper.addFileWrapper(wrapper)
    }

    // MARK: - Close

    override func close() {
        mcpService?.stop()
        mcpService = nil
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
        editorViewModel.projectURL = fileURL
        editorViewModel.agentService.loadSessions(from: fileURL)
        editorViewModel.agentService.onSessionsChanged = { [weak self] in
            self?.updateChangeCount(.changeDone)
        }

        let editorView = EditorView()
            .environment(editorViewModel)
            .focusEffectDisabled()
            .sheet(isPresented: Bindable(editorViewModel).showExportDialog) { [editorViewModel] in
                ExportView()
                    .environment(editorViewModel)
            }
            .sheet(isPresented: Bindable(editorViewModel).showHelp) { [editorViewModel] in
                HelpView()
                    .environment(editorViewModel)
                    .presentationSizing(.fitted)
                    .presentationBackground(.ultraThinMaterial)
            }
            .sheet(item: Bindable(editorViewModel).pendingSettingsMismatch) { [editorViewModel] mismatch in
                ProjectSettingsMismatchView(mismatch: mismatch)
                    .environment(editorViewModel)
            }
        let hostingController = NSHostingController(rootView: editorView)

        let window = NSWindow(contentViewController: hostingController)
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.minSize = NSSize(width: 960, height: 600)
        window.title = "Palmier Pro"
        window.setFrameAutosaveName("PalmierProWindow")
        window.appearance = NSAppearance(named: .darkAqua)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(AppTheme.Background.surfaceColor)
        window.center()

        window.addTitlebarSwiftUI(TitleBarLeadingView().environment(editorViewModel), side: .leading, width: 280)
        window.addTitlebarSwiftUI(TitleBarTrailingView().environment(editorViewModel), side: .trailing, width: 108)

        let controller = EditorWindowController(editorViewModel: editorViewModel, window: window)
        controller.shouldCascadeWindows = true
        controller.installKeyMonitor()
        addWindowController(controller)

        AppState.shared.showEditor(for: self)

        mcpService = MCPService(editor: editorViewModel)
        mcpService?.start()

        if let manifest = loadedManifest {
            editorViewModel.mediaManifest = manifest
            loadedManifest = nil
            restoreAssetsFromManifest()
        }
    }

    // MARK: - Thumbnail

    private var cachedThumbnail: Data?

    private func captureThumbnail() -> Data? {
        if let cached = cachedThumbnail { return cached }
        Log.project.debug("captureThumbnail begin")

        for track in editorViewModel.timeline.tracks where track.type == .video {
            for clip in track.clips {
                guard let url = editorViewModel.mediaResolver.resolveURL(for: clip.mediaRef) else { continue }
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.maximumSize = CGSize(width: 320, height: 180)
                generator.appliesPreferredTrackTransform = true
                let time = CMTime(value: CMTimeValue(clip.trimStartFrame), timescale: CMTimeScale(editorViewModel.timeline.fps))
                nonisolated(unsafe) var result: CGImage?
                let semaphore = DispatchSemaphore(value: 0)
                generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, _, _ in
                    result = image
                    semaphore.signal()
                }
                semaphore.wait()
                if let cgImage = result {
                    let rep = NSBitmapImageRep(cgImage: cgImage)
                    cachedThumbnail = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
                    return cachedThumbnail
                }
            }
        }
        return nil
    }

    // MARK: - Media restore

    private func restoreAssetsFromManifest() {
        let cache = editorViewModel.mediaVisualCache
        let fps = editorViewModel.timeline.fps
        let resolver = editorViewModel.mediaResolver
        for entry in editorViewModel.mediaManifest.entries {
            guard let url = resolver.resolveURL(for: entry.id) else { continue }
            let asset = MediaAsset(entry: entry, resolvedURL: url)
            editorViewModel.mediaAssets.append(asset)
            if asset.type == .audio || asset.type == .video {
                cache.generateWaveform(for: asset)
            }
            if asset.type == .video {
                cache.generateThumbnails(for: asset, fps: fps)
            }
            if asset.type == .image {
                cache.generateImageThumbnail(for: asset)
            }
            Task { await asset.loadMetadata() }
        }
    }
}

// MARK: - NSWindow helper

extension NSWindow {
    func addTitlebarSwiftUI<V: View>(_ view: V, side: NSLayoutConstraint.Attribute, width: CGFloat) {
        let host = NSHostingController(rootView: view)
        host.view.translatesAutoresizingMaskIntoConstraints = false

        let wrapper = CornerAdaptiveView()
        wrapper.frame = NSRect(x: 0, y: 0, width: width, height: 28)
        wrapper.addSubview(host.view)

        let safeArea = wrapper.layoutGuide(for: .safeArea(cornerAdaptation: .horizontal))
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: wrapper.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: side == .leading ? safeArea.leadingAnchor : wrapper.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: side == .trailing ? safeArea.trailingAnchor : wrapper.trailingAnchor),
        ])

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = wrapper
        accessory.layoutAttribute = side
        addTitlebarAccessoryViewController(accessory)
    }
}

private class CornerAdaptiveView: NSView {
    override class var requiresConstraintBasedLayout: Bool { true }
}
