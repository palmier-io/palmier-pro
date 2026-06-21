import AppKit
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

final class VideoProject: NSDocument {

    static let typeIdentifier = Project.typeIdentifier

    let editorViewModel = EditorViewModel()

    /// Decoded off-main in read(), applied on main in makeWindowControllers.
    private nonisolated(unsafe) var loadedTimeline: Timeline?
    private nonisolated(unsafe) var loadedManifest: MediaManifest?
    private nonisolated(unsafe) var loadedGenerationLog: GenerationLog?

    private nonisolated(unsafe) var packageWrapper = FileWrapper(directoryWithFileWrappers: [:])

    /// Captured on main thread before fileWrapper runs (possibly off-main).
    private nonisolated(unsafe) var snapshotTimeline: Data?
    private nonisolated(unsafe) var snapshotManifest: Data?
    private nonisolated(unsafe) var snapshotGenerationLog: Data?
    private nonisolated(unsafe) var snapshotThumbnail: Data?
    private nonisolated(unsafe) var snapshotChatSessionFiles: [(name: String, data: Data)] = []
    private nonisolated(unsafe) var snapshotPreparedForFileWrapper = false

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
            Log.project.error("read: timeline decode failed: \(String(describing: error))")
            throw error
        }
        if let manifestData = fileWrapper.fileWrappers?[Project.manifestFilename]?.regularFileContents {
            do {
                loadedManifest = try JSONDecoder().decode(MediaManifest.self, from: manifestData)
            } catch {
                Log.project.error("read manifest decode failed bytes=\(manifestData.count) error=\(error)")
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        if let logData = fileWrapper.fileWrappers?[Project.generationLogFilename]?.regularFileContents {
            loadedGenerationLog = try? JSONDecoder().decode(GenerationLog.self, from: logData)
        }
        Log.project.notice(
            "read ok tracks=\(self.loadedTimeline?.tracks.count ?? 0)",
            telemetry: "Project read",
            data: [
                "tracks": loadedTimeline?.tracks.count ?? 0,
                "clips": loadedTimeline?.tracks.reduce(0) { $0 + $1.clips.count } ?? 0,
                "media": loadedManifest?.entries.count ?? 0,
                "hasGenerationLog": loadedGenerationLog != nil
            ]
        )
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, completionHandler: @escaping (Error?) -> Void) {
        if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            fileModificationDate = date
        }

        captureSaveSnapshot()
        super.save(to: url, ofType: typeName, for: saveOperation, completionHandler: completionHandler)
    }

    override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        if !snapshotPreparedForFileWrapper {
            guard Thread.isMainThread else {
                Log.project.error("save: snapshot not prepared for off-main fileWrapper()")
                throw CocoaError(.fileWriteUnknown)
            }
            captureSaveSnapshot()
        }
        defer { snapshotPreparedForFileWrapper = false }
        guard let data = snapshotTimeline else {
            Log.project.error("save: snapshotTimeline missing at fileWrapper()")
            throw CocoaError(.fileWriteUnknown)
        }

        replaceChild(Project.timelineFilename, with: data)
        if let manifest = snapshotManifest { replaceChild(Project.manifestFilename, with: manifest) }
        if let log = snapshotGenerationLog { replaceChild(Project.generationLogFilename, with: log) }
        if let thumb = snapshotThumbnail { replaceChild(Project.thumbnailFilename, with: thumb) }
        replaceChild(ChatSessionStore.dirName, with: chatDirWrapper())
        if let mediaDir = mediaDirWrapper() { replaceChild(Project.mediaDirectoryName, with: mediaDir) }

        return packageWrapper
    }

    private func captureSaveSnapshot() {
        snapshotTimeline = try? JSONEncoder().encode(editorViewModel.timeline)
        snapshotManifest = try? JSONEncoder().encode(editorViewModel.mediaManifest)
        snapshotGenerationLog = try? JSONEncoder().encode(editorViewModel.generationLog)
        snapshotThumbnail = captureThumbnail()
        snapshotChatSessionFiles = editorViewModel.agentService.sessions
            .filter { !$0.messages.isEmpty }
            .compactMap { session in
                ChatSessionStore.encodeSession(session).map { (name: "\(session.id.uuidString).json", data: $0) }
            }
        snapshotPreparedForFileWrapper = true
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

    override var displayName: String! {
        get { fileURL?.deletingPathExtension().lastPathComponent ?? Project.defaultProjectName }
        set { super.displayName = newValue }
    }

    override var fileURL: URL? {
        get { super.fileURL }
        set {
            let oldURL = super.fileURL
            super.fileURL = newValue
            if let oldURL, let newURL = newValue,
               oldURL.standardizedFileURL != newURL.standardizedFileURL {
                MainActor.assumeIsolated {
                    ProjectRegistry.shared.updateURL(from: oldURL, to: newURL)
                }
            }
        }
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
            .sheet(item: Bindable(editorViewModel).pendingSettingsMismatch) { [editorViewModel] mismatch in
                ProjectSettingsMismatchView(mismatch: mismatch)
                    .environment(editorViewModel)
            }
            .overlay {
                TourOverlay()
                    .environment(editorViewModel)
            }
        let hostingController = NSHostingController(rootView: editorView.tint(AppTheme.Accent.primary))

        let window = NSWindow(contentViewController: hostingController)
        window.setContentSize(AppTheme.Window.projectDefault)
        window.minSize = AppTheme.Window.projectMin
        window.setFrameAutosaveName("PalmierProWindow")
        window.appearance = NSAppearance(named: .darkAqua)
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(AppTheme.Background.surfaceColor)
        window.center()

        window.addTitlebarSwiftUI(TitleBarLeadingView().environment(editorViewModel), side: .leading, width: AppTheme.IconSize.lg + AppTheme.Spacing.sm)
        window.addTitlebarSwiftUI(TitleBarTrailingView().environment(editorViewModel), side: .trailing, width: AppTheme.Window.projectTitlebarTrailingWidth)

        let controller = EditorWindowController(editorViewModel: editorViewModel, window: window)
        controller.shouldCascadeWindows = true
        controller.installKeyMonitor()
        addWindowController(controller)

        window.standardWindowButton(.documentIconButton)?.isHidden = true

        AppState.shared.showEditor(for: self)

        if let manifest = loadedManifest {
            editorViewModel.mediaManifest = manifest
            loadedManifest = nil
            restoreAssetsFromManifest()
        }
        if let log = loadedGenerationLog {
            editorViewModel.generationLog = log
            loadedGenerationLog = nil
        } else {
            editorViewModel.seedGenerationLogFromAssets()
        }
        editorViewModel.searchIndex.projectOpened()
        editorViewModel.updateTelemetryContext()
        Telemetry.breadcrumb(
            "Project opened",
            category: "project",
            data: editorViewModel.telemetrySnapshot()
        )
    }

    // MARK: - Thumbnail

    private var cachedThumbnail: Data?

    private func captureThumbnail() -> Data? {
        if let cached = cachedThumbnail { return cached }
        Log.project.debug("captureThumbnail begin")

        for track in editorViewModel.timeline.tracks where track.type == .video {
            for clip in track.clips {
                guard let url = editorViewModel.mediaResolver.resolveURL(for: clip.mediaRef) else { continue }
                if clip.mediaType == .image,
                   let image = ImageEncoder.thumbnail(url: url, maxPixelSize: 640),
                   let data = ImageEncoder.encodeJPEG(image, quality: 0.7) {
                    cachedThumbnail = data
                    return data
                }
                guard clip.mediaType == .video else { continue }

                let asset = AVURLAsset(url: url)
                guard !asset.tracks(withMediaType: .video).isEmpty else { continue }
                let generator = AVAssetImageGenerator(asset: asset)
                generator.maximumSize = CGSize(width: 320, height: 180)
                generator.appliesPreferredTrackTransform = true
                let time = CMTime(value: CMTimeValue(clip.trimStartFrame), timescale: CMTimeScale(editorViewModel.timeline.fps))
                nonisolated(unsafe) var result: CGImage?
                let semaphore = DispatchSemaphore(value: 0)
                generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, _, _ in
                    result = image
                    semaphore.signal()
                }
                guard semaphore.wait(timeout: .now() + .seconds(5)) == .success else {
                    generator.cancelAllCGImageGeneration()
                    continue
                }
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
        let resolver = editorViewModel.mediaResolver
        var restored = 0
        var missing = 0
        for entry in editorViewModel.mediaManifest.entries {
            guard let url = resolver.expectedURL(for: entry.id) else {
                Log.project.warning("restore: could not resolve URL for entry id=\(entry.id) name=\(entry.name)")
                missing += 1
                continue
            }
            let asset = MediaAsset(entry: entry, resolvedURL: url)
            editorViewModel.mediaAssets.append(asset)
            guard FileManager.default.fileExists(atPath: url.path) else {
                Log.project.warning("restore: media file missing id=\(entry.id) name=\(entry.name) path=\(url.path)")
                missing += 1
                continue
            }
            restored += 1
            if asset.type == .audio || asset.type == .video {
                cache.generateWaveform(for: asset)
            }
            if asset.type == .video {
                cache.generateVideoThumbnails(for: asset)
            }
            if asset.type == .image {
                cache.generateImageThumbnail(for: asset)
            }
            Task { await asset.loadMetadata() }
        }
        Log.project.notice(
            "restore ok restored=\(restored) missing=\(missing)",
            telemetry: "Media restored",
            data: ["restored": restored, "missing": missing, "manifestEntries": editorViewModel.mediaManifest.entries.count]
        )
    }
}

// MARK: - NSWindow helper

extension NSWindow {
    func addTitlebarSwiftUI<V: View>(_ view: V, side: NSLayoutConstraint.Attribute, width: CGFloat) {
        let host = NSHostingController(rootView: view.tint(AppTheme.Accent.primary))
        host.view.translatesAutoresizingMaskIntoConstraints = false

        let wrapper = CornerAdaptiveView()
        wrapper.frame = NSRect(x: 0, y: 0, width: width, height: 28)
        wrapper.addSubview(host.view)

        let safeArea = wrapper.layoutGuide(for: .safeArea(cornerAdaptation: .horizontal))
        var constraints = [
            host.view.topAnchor.constraint(equalTo: wrapper.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ]
        if side == .leading {
            constraints.append(contentsOf: [
                host.view.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
                host.view.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor),
            ])
        } else {
            constraints.append(contentsOf: [
                host.view.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            ])
        }
        NSLayoutConstraint.activate(constraints)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = wrapper
        accessory.layoutAttribute = side
        addTitlebarAccessoryViewController(accessory)
    }
}

private class CornerAdaptiveView: NSView {
    override class var requiresConstraintBasedLayout: Bool { true }
}
