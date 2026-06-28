import AppKit
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

private struct ProjectPackageContents: Sendable {
    var timeline: Timeline
    var manifest: MediaManifest?
    var generationLog: GenerationLog?
}

private struct ProjectPackageSnapshot: Sendable {
    var timeline: Data
    var manifest: Data?
    var generationLog: Data?
    var thumbnail: Data?
    var chatSessionFiles: [(name: String, data: Data)]
}

private struct RestoredMediaCandidate: Sendable {
    let id: String
    let name: String
    let url: URL
}

final class VideoProject: NSDocument {

    static let typeIdentifier = Project.typeIdentifier

    let editorViewModel = EditorViewModel()

    /// Decoded off-main in read(), applied on main in makeWindowControllers.
    private nonisolated(unsafe) var loadedTimeline: Timeline?
    private nonisolated(unsafe) var loadedManifest: MediaManifest?
    private nonisolated(unsafe) var loadedGenerationLog: GenerationLog?

    /// Captured on main thread before writes may continue off-main.
    private nonisolated(unsafe) var snapshotTimeline: Data?
    private nonisolated(unsafe) var snapshotManifest: Data?
    private nonisolated(unsafe) var snapshotGenerationLog: Data?
    private nonisolated(unsafe) var snapshotThumbnail: Data?
    private nonisolated(unsafe) var snapshotChatSessionFiles: [(name: String, data: Data)] = []
    private nonisolated(unsafe) var snapshotSourceProjectURL: URL?
    private nonisolated(unsafe) var snapshotPreparedForWrite = false

    // MARK: - Persistence

    override class var autosavesInPlace: Bool { true }

    @MainActor
    static func load(from url: URL) async throws -> VideoProject {
        let contents = try await Task.detached(priority: .userInitiated) {
            try readProjectPackage(at: url)
        }.value
        let doc = VideoProject()
        doc.fileURL = url
        doc.fileType = typeIdentifier
        doc.applyLoadedContents(contents)
        return doc
    }

    override func read(from url: URL, ofType typeName: String) throws {
        applyLoadedContents(try Self.readProjectPackage(at: url))
    }

    private nonisolated func applyLoadedContents(_ contents: ProjectPackageContents) {
        loadedTimeline = contents.timeline
        loadedManifest = contents.manifest
        loadedGenerationLog = contents.generationLog
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

    private nonisolated static func readProjectPackage(at url: URL) throws -> ProjectPackageContents {
        let data = try requiredData(Project.timelineFilename, in: url)
        let timeline: Timeline
        do {
            timeline = try JSONDecoder().decode(Timeline.self, from: data)
        } catch {
            Log.project.error("read: timeline decode failed: \(String(describing: error))")
            throw error
        }

        let manifest: MediaManifest?
        if let manifestData = try optionalData(Project.manifestFilename, in: url) {
            do {
                manifest = try JSONDecoder().decode(MediaManifest.self, from: manifestData)
            } catch {
                Log.project.error("read manifest decode failed bytes=\(manifestData.count) error=\(error)")
                throw CocoaError(.fileReadCorruptFile)
            }
        } else {
            manifest = nil
        }

        let generationLog = try optionalData(Project.generationLogFilename, in: url)
            .flatMap { try? JSONDecoder().decode(GenerationLog.self, from: $0) }

        return ProjectPackageContents(
            timeline: timeline,
            manifest: manifest,
            generationLog: generationLog
        )
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, completionHandler: @escaping (Error?) -> Void) {
        if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            fileModificationDate = date
        }

        captureSaveSnapshot()
        snapshotSourceProjectURL = fileURL
        super.save(to: url, ofType: typeName, for: saveOperation, completionHandler: completionHandler)
    }

    override func write(to url: URL, ofType typeName: String) throws {
        if !snapshotPreparedForWrite {
            guard Thread.isMainThread else {
                Log.project.error("save: snapshot not prepared for off-main write()")
                throw CocoaError(.fileWriteUnknown)
            }
            MainActor.assumeIsolated {
                captureSaveSnapshot()
                snapshotSourceProjectURL = fileURL
            }
        }
        defer {
            snapshotPreparedForWrite = false
            snapshotSourceProjectURL = nil
        }
        guard let data = snapshotTimeline else {
            Log.project.error("save: snapshotTimeline missing at write()")
            throw CocoaError(.fileWriteUnknown)
        }

        try Self.writeProjectPackage(
            ProjectPackageSnapshot(
                timeline: data,
                manifest: snapshotManifest,
                generationLog: snapshotGenerationLog,
                thumbnail: snapshotThumbnail,
                chatSessionFiles: snapshotChatSessionFiles
            ),
            to: url,
            sourceURL: snapshotSourceProjectURL
        )
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
        snapshotPreparedForWrite = true
    }

    private nonisolated static func requiredData(_ name: String, in packageURL: URL) throws -> Data {
        do {
            return try Data(contentsOf: packageURL.appendingPathComponent(name, isDirectory: false), options: [.mappedIfSafe])
        } catch {
            Log.project.error("read: missing \(name) in package")
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private nonisolated static func optionalData(_ name: String, in packageURL: URL) throws -> Data? {
        let url = packageURL.appendingPathComponent(name, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private nonisolated static func writeProjectPackage(_ snapshot: ProjectPackageSnapshot, to packageURL: URL, sourceURL: URL?) throws {
        let fm = FileManager.default
        try createPackageDirectory(at: packageURL, fm: fm)
        try snapshot.timeline.write(to: packageURL.appendingPathComponent(Project.timelineFilename), options: .atomic)
        if let manifest = snapshot.manifest {
            try manifest.write(to: packageURL.appendingPathComponent(Project.manifestFilename), options: .atomic)
        }
        if let log = snapshot.generationLog {
            try log.write(to: packageURL.appendingPathComponent(Project.generationLogFilename), options: .atomic)
        }
        if let thumbnail = snapshot.thumbnail {
            try thumbnail.write(to: packageURL.appendingPathComponent(Project.thumbnailFilename), options: .atomic)
        } else {
            try copyPreservedFile(Project.thumbnailFilename, from: sourceURL, to: packageURL, fm: fm)
        }
        try writeChatDirectory(snapshot.chatSessionFiles, to: packageURL, fm: fm)
        try copyMediaDirectoryIfNeeded(from: sourceURL, to: packageURL, fm: fm)
    }

    private nonisolated static func createPackageDirectory(at url: URL, fm: FileManager) throws {
        var isDirectory = ObjCBool(false)
        if fm.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue { return }
            try fm.removeItem(at: url)
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private nonisolated static func writeChatDirectory(_ files: [(name: String, data: Data)], to packageURL: URL, fm: FileManager) throws {
        let chatURL = packageURL.appendingPathComponent(ChatSessionStore.dirName, isDirectory: true)
        if fm.fileExists(atPath: chatURL.path) {
            try fm.removeItem(at: chatURL)
        }
        try fm.createDirectory(at: chatURL, withIntermediateDirectories: true)
        for file in files {
            try file.data.write(to: chatURL.appendingPathComponent(file.name, isDirectory: false), options: .atomic)
        }
    }

    private nonisolated static func copyPreservedFile(_ name: String, from sourceURL: URL?, to packageURL: URL, fm: FileManager) throws {
        guard let sourceURL, !sameFile(sourceURL, packageURL) else { return }
        let source = sourceURL.appendingPathComponent(name, isDirectory: false)
        guard fm.fileExists(atPath: source.path) else { return }
        let destination = packageURL.appendingPathComponent(name, isDirectory: false)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
    }

    private nonisolated static func copyMediaDirectoryIfNeeded(from sourceURL: URL?, to packageURL: URL, fm: FileManager) throws {
        guard let sourceURL, !sameFile(sourceURL, packageURL) else { return }
        let source = sourceURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        let destination = packageURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        guard fm.fileExists(atPath: source.path) else { return }
        try fm.copyItem(at: source, to: destination)
    }

    private nonisolated static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
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

        if let manifest = loadedManifest {
            editorViewModel.mediaManifest = manifest
            loadedManifest = nil
            restoreAssetsFromManifest()
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
        hostingController.sizingOptions = .minSize

        let window = NSWindow(contentViewController: hostingController)
        window.minSize = AppTheme.Window.projectMin
        window.appearance = NSAppearance(named: .darkAqua)
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(AppTheme.Background.surfaceColor)
        window.fillVisibleScreen()

        window.addTitlebarSwiftUI(TitleBarLeadingView().environment(editorViewModel), side: .leading, width: AppTheme.IconSize.lg + AppTheme.Spacing.sm)
        window.addTitlebarSwiftUI(TitleBarTrailingView().environment(editorViewModel), side: .trailing, width: AppTheme.Window.projectTitlebarTrailingWidth)

        let controller = EditorWindowController(editorViewModel: editorViewModel, window: window)
        controller.installKeyMonitor()
        addWindowController(controller)

        window.standardWindowButton(.documentIconButton)?.isHidden = true

        AppState.shared.showEditor(for: self)

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
    private var thumbnailInFlight = false
    private nonisolated static let thumbnailMaxPixelSize = 640

    private func captureThumbnail() -> Data? {
        if let cached = cachedThumbnail { return cached }
        guard !thumbnailInFlight else { return nil }
        thumbnailInFlight = true
        Task { [weak self] in
            await self?.generateThumbnail()
        }
        return nil
    }

    /// Picks the first usable video-track clip and generates a jpeg
    private func generateThumbnail() async {
        defer { thumbnailInFlight = false }

        struct Candidate { let url: URL; let isVideo: Bool; let trimStartFrame: Int }
        var candidates: [Candidate] = []
        for track in editorViewModel.timeline.tracks where track.type == .video {
            for clip in track.clips {
                guard clip.mediaType == .image || clip.mediaType == .video,
                      let url = editorViewModel.mediaResolver.expectedURL(for: clip.mediaRef) else { continue }
                candidates.append(Candidate(
                    url: url,
                    isVideo: clip.mediaType == .video,
                    trimStartFrame: clip.trimStartFrame
                ))
            }
        }
        let fps = editorViewModel.timeline.fps
        guard !candidates.isEmpty else { return }

        let maxPixelSize = Self.thumbnailMaxPixelSize
        let data: Data? = await Task.detached(priority: .utility) {
            for candidate in candidates {
                if candidate.isVideo {
                    // Async `loadTracks` / `image(at:)` — no blocking semaphore wait.
                    let asset = AVURLAsset(url: candidate.url)
                    guard (try? await asset.loadTracks(withMediaType: .video).first) != nil else { continue }
                    let generator = AVAssetImageGenerator(asset: asset)
                    // Aspect-preserving box; frame is ~640px on the long edge.
                    generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
                    generator.appliesPreferredTrackTransform = true
                    let time = CMTime(value: CMTimeValue(candidate.trimStartFrame), timescale: CMTimeScale(max(fps, 1)))
                    guard let cgImage = try? await generator.image(at: time).image else { continue }
                    return NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: 0.7])
                } else if let image = ImageEncoder.thumbnail(url: candidate.url, maxPixelSize: maxPixelSize),
                          let data = ImageEncoder.encodeJPEG(image, quality: 0.7) {
                    return data
                }
            }
            return nil
        }.value

        guard let data else { return }
        cachedThumbnail = data
        guard let packageURL = fileURL else { return }
        let thumbURL = packageURL.appendingPathComponent(Project.thumbnailFilename, isDirectory: false)
        try? await Task.detached(priority: .utility) {
            try data.write(to: thumbURL, options: .atomic)
        }.value
    }

    // MARK: - Media restore

    private func restoreAssetsFromManifest() {
        let resolver = editorViewModel.mediaResolver
        var missing = 0
        var missingRefs: Set<String> = []
        var candidates: [RestoredMediaCandidate] = []
        for entry in editorViewModel.mediaManifest.entries {
            guard let url = resolver.expectedURL(for: entry.id) else {
                Log.project.warning("restore: could not resolve URL for entry id=\(entry.id) name=\(entry.name)")
                missing += 1
                missingRefs.insert(entry.id)
                continue
            }
            let asset = MediaAsset(entry: entry, resolvedURL: url)
            editorViewModel.mediaAssets.append(asset)
            candidates.append(RestoredMediaCandidate(id: entry.id, name: entry.name, url: url))
        }
        editorViewModel.missingMediaRefs = missingRefs

        let restoreCandidates = candidates
        let initialMissingRefs = missingRefs
        let initialMissingCount = missing
        let manifestEntries = editorViewModel.mediaManifest.entries.count
        Task { [weak self] in
            let existingRefs = await Task.detached(priority: .utility) {
                Self.existingMediaRefs(restoreCandidates)
            }.value
            self?.finishRestoredMediaScan(
                candidates: restoreCandidates,
                existingRefs: existingRefs,
                initialMissingRefs: initialMissingRefs,
                initialMissingCount: initialMissingCount,
                manifestEntries: manifestEntries
            )
        }
    }

    private nonisolated static func existingMediaRefs(_ candidates: [RestoredMediaCandidate]) -> Set<String> {
        Set(candidates.compactMap { candidate in
            FileManager.default.fileExists(atPath: candidate.url.path) ? candidate.id : nil
        })
    }

    private func finishRestoredMediaScan(
        candidates: [RestoredMediaCandidate],
        existingRefs: Set<String>,
        initialMissingRefs: Set<String>,
        initialMissingCount: Int,
        manifestEntries: Int
    ) {
        let cache = editorViewModel.mediaVisualCache
        var assetsByID: [String: MediaAsset] = [:]
        for asset in editorViewModel.mediaAssets {
            assetsByID[asset.id] = asset
        }
        var restored = 0
        var missing = initialMissingCount
        var missingRefs = initialMissingRefs

        for candidate in candidates {
            guard let asset = assetsByID[candidate.id] else { continue }
            guard existingRefs.contains(candidate.id) else {
                Log.project.warning("restore: media file missing id=\(candidate.id) name=\(candidate.name) path=\(candidate.url.path)")
                missing += 1
                missingRefs.insert(candidate.id)
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

        editorViewModel.missingMediaRefs = missingRefs
        Log.project.notice(
            "restore ok restored=\(restored) missing=\(missing)",
            telemetry: "Media restored",
            data: ["restored": restored, "missing": missing, "manifestEntries": manifestEntries]
        )
    }
}

// MARK: - NSWindow helper

extension NSWindow {
    func fillVisibleScreen(using screen: NSScreen? = nil) {
        let target = screen ?? self.screen ?? NSScreen.main
        guard let frame = target?.visibleFrame else { return }
        setFrame(frame, display: true)
    }

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
