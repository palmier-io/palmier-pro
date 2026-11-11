import AppKit
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct ProjectPackageContents: Sendable {
    var projectFile: ProjectFile
    var manifest: MediaManifest?
    var manifestUnreadable: Bool = false
    var plans: [EditPlan]?
    var plansUnreadable: Bool = false
}

struct ProjectPackageSnapshot: Sendable {
    var timeline: Data
    var manifest: Data?
    var plans: Data?
    var thumbnail: Data?
    var chatSessionFiles: [(name: String, data: Data)]
}

private struct RestoredMediaCandidate: Sendable {
    let id: String
    let name: String
    let url: URL
}

private typealias DocumentCloseCallback = @convention(c) (
    AnyObject, Selector, NSDocument, Bool, UnsafeMutableRawPointer?
) -> Void

@MainActor
private final class ProjectCloseDecision: NSObject {
    private var complete: (@MainActor (Bool) -> Void)?

    init(complete: @escaping @MainActor (Bool) -> Void) { self.complete = complete }

    @objc nonisolated func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        Task { @MainActor in
            let callback = complete
            complete = nil
            callback?(shouldClose)
        }
    }
}

private final class SaveReady: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func signal() { semaphore.signal() }

    func wait() { semaphore.wait() }
}

class VideoProject: NSDocument {

    private struct SaveRequest {
        let id = UUID()
        let url: URL
        let typeName: String
        let operation: NSDocument.SaveOperationType
        let completion: (Error?) -> Void
        let ready = SaveReady()
    }

    private struct SaveContext: Sendable {
        let projectFile: ProjectFile
        let manifest: MediaManifest?
        let plans: [EditPlan]?
        let thumbnail: Data?
        let chatSessions: [ChatSession]
        let sourceURL: URL?
    }

    private struct CloseRequest {
        let target: AnyObject
        let selector: Selector
        let callback: DocumentCloseCallback
        let contextInfo: UnsafeMutableRawPointer?
    }

    static let typeIdentifier = Project.typeIdentifier

    let editorViewModel: EditorViewModel
    private nonisolated let packageIO: ProjectPackageIO
    private var registry: ProjectRegistry?

    override convenience init() {
        self.init(registry: nil)
    }

    init(registry: ProjectRegistry?) {
        let editor = EditorViewModel()
        editor.projectRegistry = registry
        editorViewModel = editor
        packageIO = editor.projectPackageCoordinator.io
        self.registry = registry
        super.init()
    }

    /// Decoded off-main in read(), applied on main in makeWindowControllers.
    private nonisolated(unsafe) var loadedProjectFile: ProjectFile?
    private nonisolated(unsafe) var loadedManifest: MediaManifest?
    private nonisolated(unsafe) var loadedPlans: [EditPlan]?
    private nonisolated(unsafe) var loadedPlansUnreadable = false

    /// Set when media.json existed but failed to decode, so saves preserve it instead of clobbering.
    private nonisolated(unsafe) var manifestLoadFailed = false
    private nonisolated(unsafe) var plansLoadFailed = false

    // Published before super.save, read-only until its completion, then cleared on main.
    private nonisolated(unsafe) var saveContext: SaveContext?
    private nonisolated(unsafe) var activeSaveRequest: SaveRequest?
    private nonisolated(unsafe) var activeSaveLease: ProjectPackageCoordinator.SaveLease?
    private var saveQueue: [SaveRequest] = []
    private var directSaveInProgress = false
    private var saveTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var nativeCloseTask: Task<Void, Never>?
    private var nativeCloseLease: ProjectPackageCoordinator.CloseLease?
    private var closeRequests: [CloseRequest] = []
    private var closeDecision: ProjectCloseDecision?
    private var projectCheckpointAutosaveScheduled = false
    private var closeSaveCount = 0
    private var isSavingBeforeClose: Bool { closeSaveCount > 0 }

    // MARK: - Persistence

    override class var autosavesInPlace: Bool { true }

    // The save snapshot is captured on main before super.save; the encode + disk write run off-main.
    override func canAsynchronouslyWrite(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) -> Bool { true }

    @MainActor
    static func load(from url: URL, registry: ProjectRegistry? = nil) async throws -> VideoProject {
        try Task.checkCancellation()
        let contents = try await ProjectPackageIO().perform {
            try readProjectPackage(at: url)
        }
        try Task.checkCancellation()
        let doc = VideoProject(registry: registry)
        doc.fileURL = url
        doc.fileType = typeIdentifier
        doc.applyLoadedContents(contents)
        return doc
    }

    override func read(from url: URL, ofType typeName: String) throws {
        applyLoadedContents(try Self.readProjectPackage(at: url))
    }

    private nonisolated func applyLoadedContents(_ contents: ProjectPackageContents) {
        loadedProjectFile = contents.projectFile
        loadedManifest = contents.manifest
        manifestLoadFailed = contents.manifestUnreadable
        loadedPlans = contents.plans
        loadedPlansUnreadable = contents.plansUnreadable
        plansLoadFailed = contents.plansUnreadable
    }

    nonisolated static func readProjectPackage(at url: URL) throws -> ProjectPackageContents {
        let data = try requiredData(Project.timelineFilename, in: url)
        let projectFile: ProjectFile
        do {
            projectFile = try ProjectFile.decode(data)
        } catch {
            Log.project.error("read: timeline decode failed: \(String(describing: error))")
            throw error
        }

        let manifest: MediaManifest?
        let manifestUnreadable: Bool
        if let manifestData = try optionalData(Project.manifestFilename, in: url) {
            if let decoded = try? JSONDecoder().decode(MediaManifest.self, from: manifestData) {
                manifest = decoded
                manifestUnreadable = false
            } else {
                // A bad manifest must not lose the project; degrade to "media offline" and keep the file for recovery.
                Log.project.error("read manifest decode failed bytes=\(manifestData.count); opening with empty manifest")
                manifest = nil
                manifestUnreadable = true
            }
        } else {
            manifest = nil
            manifestUnreadable = false
        }

        let plans = try EditPlanStore.readPackageFile(at: url)
        Log.project.notice(
            "read ok timelines=\(projectFile.timelines.count)",
            telemetry: "Project read",
            data: [
                "timelines": projectFile.timelines.count,
                "tracks": projectFile.timelines.reduce(0) { $0 + $1.tracks.count },
                "clips": projectFile.timelines.reduce(0) { $0 + $1.tracks.reduce(0) { $0 + $1.clips.count } },
                "media": manifest?.entries.count ?? 0
            ]
        )
        return ProjectPackageContents(
            projectFile: projectFile,
            manifest: manifest,
            manifestUnreadable: manifestUnreadable,
            plans: plans.plans,
            plansUnreadable: plans.unreadable
        )
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, completionHandler: @escaping (Error?) -> Void) {
        // Keep the main thread available to MainActor save work while NSDocument is saving.
        unblockUserInteraction()
        guard !editorViewModel.projectPackageCoordinator.isClosed else {
            completionHandler(CocoaError(.userCancelled))
            return
        }
        let request = SaveRequest(
            url: url,
            typeName: typeName,
            operation: saveOperation,
            completion: completionHandler
        )
        saveQueue.append(request)
        editorViewModel.projectPackageCoordinator.enqueueSave { lease in
            self.performSave(request, lease: lease)
        }
        launchNextSaveIfNeeded()
    }

    private func performSave(_ request: SaveRequest, lease: ProjectPackageCoordinator.SaveLease) {
        activeSaveLease = lease
        saveContext = captureSaveSnapshot()
        request.ready.signal()
    }

    private func launchNextSaveIfNeeded() {
        guard !directSaveInProgress, let request = saveQueue.first else { return }
        directSaveInProgress = true
        activeSaveRequest = request
        super.save(to: request.url, ofType: request.typeName, for: request.operation) { error in
            Task { @MainActor in
                var completionError = error
                do {
                    if error == nil {
                        if self.saveContext?.manifest != nil { self.manifestLoadFailed = false }
                        try await (self.registry ?? self.editorViewModel.projectRegistry)?.flush()
                    }
                } catch let failure {
                    completionError = failure
                }
                self.saveContext = nil
                self.saveTask = nil
                self.directSaveInProgress = false
                if let index = self.saveQueue.firstIndex(where: { $0.id == request.id }) {
                    self.saveQueue.remove(at: index)
                }
                if let lease = self.activeSaveLease {
                    self.activeSaveLease = nil
                    self.activeSaveRequest = nil
                    let coordinator = self.editorViewModel.projectPackageCoordinator
                    coordinator.finishSave(lease) {
                        DispatchQueue.main.async { request.completion(completionError) }
                    }
                } else {
                    self.activeSaveRequest = nil
                    DispatchQueue.main.async { request.completion(completionError) }
                }
                self.launchNextSaveIfNeeded()
            }
        }
    }

    override func canClose(
        withDelegate delegate: Any,
        shouldClose shouldCloseSelector: Selector?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        let target = delegate as AnyObject
        guard let shouldCloseSelector, let callbackTarget = target as? NSObjectProtocol,
              callbackTarget.responds(to: shouldCloseSelector), let implementation = target.method(for: shouldCloseSelector) else { return }
        let request = CloseRequest(target: target, selector: shouldCloseSelector,
            callback: unsafeBitCast(implementation, to: DocumentCloseCallback.self), contextInfo: contextInfo)
        let coordinator = editorViewModel.projectPackageCoordinator
        if coordinator.isClosed {
            do {
                try confirmClosed()
                deliverCloseRequest(request, shouldClose: true)
            } catch { deliverCloseRequest(request, shouldClose: false) }
            return
        }
        if nativeCloseLease == nil { nativeCloseLease = beginClosing() }
        guard let lease = nativeCloseLease else {
            deliverCloseRequest(request, shouldClose: false)
            return
        }
        closeRequests.append(request)
        guard closeTask == nil, closeDecision == nil else { return }
        closeTask = Task { @MainActor in
            do {
                try await saveBeforeClosing(using: lease)
                try coordinator.validate(lease)
                guard nativeCloseLease == lease else { throw CancellationError() }
                let decision = ProjectCloseDecision { [weak self] shouldClose in
                    self?.completeCloseRequests(for: lease, shouldClose: shouldClose)
                }
                closeDecision = decision
                closeTask = nil
                super.canClose(
                    withDelegate: decision,
                    shouldClose: #selector(ProjectCloseDecision.document(_:shouldClose:contextInfo:)),
                    contextInfo: nil
                )
            } catch {
                if !coordinator.isClosed, !(error is CancellationError) { presentError(error) }
                completeCloseRequests(for: lease, shouldClose: coordinator.isClosed)
            }
        }
    }

    private func completeCloseRequests(for lease: ProjectPackageCoordinator.CloseLease, shouldClose: Bool) {
        guard nativeCloseLease == lease else { return }
        let coordinator = editorViewModel.projectPackageCoordinator
        let approved: Bool
        do {
            try validateCloseOwner(lease)
            approved = shouldClose
        } catch { approved = false }
        closeDecision = nil
        closeTask = nil
        if !approved || coordinator.isClosed {
            nativeCloseLease = nil
            coordinator.cancelClosing(lease)
        }
        let requests = closeRequests
        closeRequests.removeAll()
        for request in requests {
            deliverCloseRequest(request, shouldClose: approved)
        }
    }

    private func deliverCloseRequest(_ request: CloseRequest, shouldClose: Bool) {
        request.callback(request.target, request.selector, self, shouldClose, request.contextInfo)
    }

    @MainActor
    @discardableResult
    func beginClosing() -> ProjectPackageCoordinator.CloseLease? {
        let coordinator = editorViewModel.projectPackageCoordinator
        coordinator.onReopen = { [weak self] in
            guard let self else { return }
            restoreAssetsFromManifest()
            editorViewModel.generationService.resumePendingGenerations(editor: editorViewModel)
        }
        let wasClosing = coordinator.isClosing
        let lease = coordinator.beginClosing()
        if lease != nil, !wasClosing { cancelDocumentBackgroundWork() }
        return lease
    }

    @MainActor
    func saveBeforeClosing(using lease: ProjectPackageCoordinator.CloseLease) async throws {
        let coordinator = editorViewModel.projectPackageCoordinator
        try coordinator.validateCloseContext()
        try Task.checkCancellation()
        try coordinator.validate(lease)
        closeSaveCount += 1
        defer { closeSaveCount -= 1 }
        await editorViewModel.agentService.cancelAndWait()
        try Task.checkCancellation()
        try coordinator.validate(lease)
        await editorViewModel.generationService.suspendAndWait()
        try Task.checkCancellation()
        try coordinator.validate(lease)
        try await coordinator.waitUntilIdle(for: lease)
        repeat {
            try Task.checkCancellation()
            try coordinator.validate(lease)
            guard let url = fileURL else { throw CocoaError(.fileNoSuchFile) }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                save(to: url, ofType: Self.typeIdentifier, for: .saveOperation) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
            try Task.checkCancellation()
            try coordinator.validate(lease)
        } while hasUnautosavedChanges
        try await coordinator.waitUntilIdle(for: lease)
    }

    override func writeSafely(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType
    ) throws {
        // NSDocument otherwise blocks the main thread while super prepares a safe-save directory.
        unblockUserInteraction()
        activeSaveRequest?.ready.wait()
        try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
    }

    override func write(to url: URL, ofType typeName: String) throws {
        unblockUserInteraction()
        guard !Thread.isMainThread, let context = saveContext else {
            Log.project.error("save: coordinated snapshot missing at write()")
            throw CocoaError(.fileWriteUnknown)
        }
        try packageIO.write {
            try Self.writeProjectPackage(
                ProjectPackageSnapshot(
                    timeline: try JSONEncoder().encode(context.projectFile),
                    manifest: try context.manifest.map { try JSONEncoder().encode($0) },
                    plans: try context.plans.map { try EditPlanStore.encode($0) },
                    thumbnail: context.thumbnail,
                    chatSessionFiles: try Self.encodeChatSessions(context.chatSessions)
                ),
                to: url,
                sourceURL: context.sourceURL
            )
        }
    }

    private func captureSaveSnapshot() -> SaveContext {
        editorViewModel.flushPendingManifestMetadataUpdates()
        return SaveContext(
            projectFile: editorViewModel.projectFileSnapshot(),
            manifest: Self.manifestSnapshot(manifest: editorViewModel.mediaManifest, loadFailed: manifestLoadFailed),
            plans: EditPlanStore.snapshot(plans: editorViewModel.editPlans, loadFailed: plansLoadFailed),
            thumbnail: captureThumbnail(),
            chatSessions: editorViewModel.agentService.sessions,
            sourceURL: fileURL
        )
    }

    private nonisolated static func encodeChatSessions(_ sessions: [ChatSession]) throws -> [(name: String, data: Data)] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try sessions.filter { !$0.messages.isEmpty }.map {
            (name: "\($0.id.uuidString).json", data: try encoder.encode($0))
        }
    }

    nonisolated static func manifestSnapshot(manifest: MediaManifest, loadFailed: Bool) -> MediaManifest? {
        // If the manifest failed to load, don't overwrite the (recoverable) original with an empty one.
        if loadFailed && manifest.entries.isEmpty && manifest.folders.isEmpty { return nil }
        return manifest
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

    nonisolated static func writeProjectPackage(_ snapshot: ProjectPackageSnapshot, to packageURL: URL, sourceURL: URL?) throws {
        let fm = FileManager.default
        try createPackageDirectory(at: packageURL, fm: fm)
        try snapshot.timeline.write(to: packageURL.appendingPathComponent(Project.timelineFilename), options: .atomic)
        if let manifest = snapshot.manifest {
            try manifest.write(to: packageURL.appendingPathComponent(Project.manifestFilename), options: .atomic)
        } else {
            try copyPreservedFile(Project.manifestFilename, from: sourceURL, to: packageURL, fm: fm)
        }
        if let plans = snapshot.plans {
            try plans.write(to: packageURL.appendingPathComponent(Project.plansFilename), options: .atomic)
        } else {
            try copyPreservedFile(Project.plansFilename, from: sourceURL, to: packageURL, fm: fm)
        }
        if let thumbnail = snapshot.thumbnail {
            try thumbnail.write(to: packageURL.appendingPathComponent(Project.thumbnailFilename), options: .atomic)
        } else {
            try copyPreservedFile(Project.thumbnailFilename, from: sourceURL, to: packageURL, fm: fm)
        }
        try writeChatDirectory(snapshot.chatSessionFiles, to: packageURL, fm: fm)
        try copyMediaDirectoryIfNeeded(from: sourceURL, to: packageURL, fm: fm)
        try fm.createDirectory(
            at: packageURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true),
            withIntermediateDirectories: true
        )
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

    private func scheduleProjectCheckpointAutosave() {
        guard fileURL != nil, !projectCheckpointAutosaveScheduled, !isSavingBeforeClose, !AppDelegate.shared.isTerminating else { return }
        projectCheckpointAutosaveScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.projectCheckpointAutosaveScheduled = false
            guard self.fileURL != nil, !self.isSavingBeforeClose, !AppDelegate.shared.isTerminating else { return }
            self.autosave(withImplicitCancellability: false) { error in
                if let error {
                    Log.project.error("project checkpoint autosave failed: \(error.localizedDescription)")
                }
            }
        }
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
                    let registry = self.registry ?? ProjectRegistry.shared
                    self.registry = registry
                    editorViewModel.projectRegistry = registry
                    Telemetry.beginOperation("project_url_rebase", data: [
                        "media_count": editorViewModel.mediaAssets.count,
                        "registry_count": registry.entries.count,
                    ])
                    defer { Telemetry.endOperation("project_url_rebase") }
                    registry.updateURL(from: oldURL, to: newURL)
                    editorViewModel.rebaseProjectURL(from: oldURL, to: newURL)
                }
            }
        }
    }

    // MARK: - Close

    func closeAfterSaving() async throws {
        try Task.checkCancellation()
        let coordinator = editorViewModel.projectPackageCoordinator
        guard !coordinator.isClosed else {
            try confirmClosed()
            return
        }
        try coordinator.validateCloseContext()
        guard let lease = beginClosing() else { throw CancellationError() }
        defer { coordinator.cancelClosing(lease) }
        do {
            try await finishClose(using: lease)
        } catch {
            if coordinator.isClosed { try confirmClosed(); return }
            throw error
        }
    }

    private func finishClose(using lease: ProjectPackageCoordinator.CloseLease) async throws {
        let coordinator = editorViewModel.projectPackageCoordinator
        try coordinator.validate(lease)
        if let url = fileURL { (registry ?? editorViewModel.projectRegistry)?.register(url) }
        repeat {
            try await saveBeforeClosing(using: lease)
            try Task.checkCancellation()
            try coordinator.validate(lease)
            try await coordinator.waitUntilIdle(for: lease)
        } while hasUnautosavedChanges
        try Task.checkCancellation()
        try coordinator.validate(lease)
        try closeImmediately(using: lease)
    }

    override func close() {
        let coordinator = editorViewModel.projectPackageCoordinator
        guard !coordinator.isClosed else { return }
        guard nativeCloseTask == nil else { return }
        if let lease = nativeCloseLease, coordinator.canFinishClosing, !hasUnautosavedChanges {
            do { try closeImmediately(using: lease) }
            catch {
                completeCloseRequests(for: lease, shouldClose: false)
                presentError(error)
            }
        } else {
            if nativeCloseLease == nil { nativeCloseLease = beginClosing() }
            guard let lease = nativeCloseLease else { return }
            nativeCloseTask = Task { @MainActor in
                defer { nativeCloseTask = nil }
                do {
                    try await finishClose(using: lease)
                    try await AppState.shared.closeProject(self)
                } catch {
                    completeCloseRequests(for: lease, shouldClose: coordinator.isClosed)
                    if !coordinator.isClosed, !(error is CancellationError) { presentError(error) }
                }
            }
        }
    }

    func closeImmediately(using lease: ProjectPackageCoordinator.CloseLease) throws {
        guard !editorViewModel.projectPackageCoordinator.isClosed else {
            try confirmClosed()
            return
        }
        try editorViewModel.projectPackageCoordinator.finishClosing(lease)
        super.close()
        try confirmClosed()
        if let nativeLease = nativeCloseLease { completeCloseRequests(for: nativeLease, shouldClose: true) }
        editorViewModel.detachProxyStore()
        DispatchQueue.main.async {
            guard !AppDelegate.shared.isTerminating else { return }
            if AppState.shared.activeProject === self {
                Task { @MainActor in
                    do { try await AppState.shared.closeProject(self) }
                    catch { self.presentError(error) }
                }
            }
        }
    }

    private func confirmClosed() throws {
        guard editorViewModel.projectPackageCoordinator.isClosed,
              !NSDocumentController.shared.documents.contains(where: { $0 === self }) else {
            throw CocoaError(.userCancelled)
        }
    }

    func validateCloseOwner(_ lease: ProjectPackageCoordinator.CloseLease) throws {
        if editorViewModel.projectPackageCoordinator.isClosed { try confirmClosed() }
        else { try editorViewModel.projectPackageCoordinator.validate(lease) }
    }

    func abortOpening() async {
        let coordinator = editorViewModel.projectPackageCoordinator
        do { try coordinator.validateCloseContext() }
        catch { presentError(error); return }
        guard let lease = beginClosing() else { return }
        defer { coordinator.cancelClosing(lease) }
        // Failed opening must finish cleanup even when its initiating task was cancelled.
        let cleanup = Task.detached { await self.finishAbortedOpening(using: lease) }
        await cleanup.value
    }

    private func finishAbortedOpening(using lease: ProjectPackageCoordinator.CloseLease) async {
        let coordinator = editorViewModel.projectPackageCoordinator
        do {
            await editorViewModel.agentService.cancelAndWait()
            try coordinator.validate(lease)
            await editorViewModel.generationService.suspendAndWait()
            try coordinator.validate(lease)
            try await coordinator.waitUntilIdle(for: lease)
            try closeImmediately(using: lease)
        } catch {
            if !coordinator.isClosed { presentError(error) }
        }
    }

    // MARK: - Window setup

    override func makeWindowControllers() {
        if let loaded = loadedProjectFile {
            editorViewModel.applyProjectFile(loaded)
            loadedProjectFile = nil
        }
        editorViewModel.undo.attach(undoManager)
        editorViewModel.projectURL = fileURL
        // Proxies are a preview cache, not project state: an unsaved project has nowhere to put
        // them, so preview falls back to the originals.
        if let packageURL = fileURL {
            editorViewModel.prepareProxyStore(projectDirectory: packageURL)
        }
        editorViewModel.editPlans = loadedPlans ?? []
        editorViewModel.editPlansLoadFailed = loadedPlansUnreadable
        loadedPlans = nil
        editorViewModel.agentService.loadSessions(from: fileURL)
        editorViewModel.agentService.onSessionsChanged = { [weak self] in
            self?.updateChangeCount(.changeDone)
        }
        editorViewModel.onProjectCheckpointRequired = { [weak self] in
            self?.scheduleProjectCheckpointAutosave()
        }

        if let manifest = loadedManifest {
            editorViewModel.mediaManifest = manifest
            loadedManifest = nil
            restoreAssetsFromManifest()
        }
        if editorViewModel.markSpeakers { editorViewModel.identifySpeakers() }

        let editorView = EditorView()
            .environment(editorViewModel)
            .focusEffectDisabled()
            .background(.ultraThinMaterial)
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
            .ignoresSafeArea(.container, edges: .top)
        let hostingController = NSHostingController(rootView: editorView.appLocalization().tint(AppTheme.Accent.primary))
        hostingController.sizingOptions = .minSize
        hostingController.safeAreaRegions = []

        let window = NSWindow(contentViewController: hostingController)
        window.minSize = AppTheme.Window.projectMin
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.backgroundColor = AppTheme.Background.base.withAlphaComponent(AppTheme.Opacity.high)
        window.isOpaque = false
        window.styleMask.insert(.fullSizeContentView)
        window.fillVisibleScreen()

        window.addTitlebarSwiftUI(TitleBarLeadingView().environment(editorViewModel), side: .leading, width: AppTheme.Window.projectTitlebarLeadingWidth)
        window.addTitlebarSwiftUI(TitleBarTrailingView().environment(editorViewModel), side: .trailing, width: AppTheme.Window.projectTitlebarTrailingWidth)

        let controller = EditorWindowController(editorViewModel: editorViewModel, window: window)
        controller.onBecameKey = { [weak self] in
            guard let self else { return }
            AppState.shared.projectWindowDidBecomeKey(self)
        }
        window.delegate = controller
        controller.installKeyMonitor()
        addWindowController(controller)

        window.standardWindowButton(.documentIconButton)?.isHidden = true

        editorViewModel.searchIndex.projectOpened()
        editorViewModel.updateTelemetryContext()
        Telemetry.breadcrumb(
            "Project opened",
            category: "project",
            data: editorViewModel.telemetrySnapshot()
        )
    }

    // MARK: - Thumbnail

    struct ThumbnailCandidate: Sendable, Equatable {
        let clipID: String
        let mediaRef: String
        let url: URL
        let isVideo: Bool
        let trimStartFrame: Int
        let source: MediaSource
        let inputIdentity: MediaInputIdentity?
        let assetIdentity: ObjectIdentifier?
        let assetURL: URL?
        let assetInputIdentity: MediaInputIdentity?
        let generationStatus: String?
        let generationInput: GenerationInput?
        let pendingDownloadURL: URL?
    }

    struct ThumbnailRequest: Sendable, Equatable {
        let documentURL: URL?
        let projectURL: URL?
        let timelineID: String
        let fps: Int
        let maxPixelSize: Int
        let candidates: [ThumbnailCandidate]
    }

    private struct ThumbnailFileStamp: Sendable, Equatable {
        let fileNumber: UInt64?
        let size: Int?
        let modified: Date?
        let created: Date?
    }

    private struct ThumbnailCache: Sendable {
        let request: ThumbnailRequest
        let stamps: [ThumbnailFileStamp?]
        let data: Data?
    }

    private var cachedThumbnail: ThumbnailCache?
    private var thumbnailTask: Task<Void, Never>?
    private var thumbnailRetryTask: Task<Void, Never>?
    private var thumbnailRequestInFlight: ThumbnailRequest?
    private nonisolated static let thumbnailMaxPixelSize = 640
    var thumbnailRenderer: @Sendable (ThumbnailRequest) async throws -> Data? = { request in
        try await VideoProject.renderThumbnail(request)
    }

    func captureThumbnail() -> Data? {
        let request = thumbnailRequest()
        if cachedThumbnail?.request != request { cachedThumbnail = nil }
        let cached = cachedThumbnail
        let coordinator = editorViewModel.projectPackageCoordinator
        guard !coordinator.isClosing, !coordinator.isClosed else { return cached?.data }
        if let thumbnailTask {
            if thumbnailRequestInFlight != request {
                if thumbnailRetryTask == nil {
                    thumbnailRetryTask = coordinator.startIntent { [weak self] _ in
                        await thumbnailTask.value
                        try Task.checkCancellation()
                        guard let self else { return }
                        self.thumbnailRetryTask = nil
                        _ = self.captureThumbnail()
                    } onFailure: { [weak self] error in
                        self?.thumbnailRetryTask = nil
                        if !(error is CancellationError) {
                            Log.project.warning("thumbnail retry failed: \(error.localizedDescription)")
                        }
                    }
                }
                thumbnailTask.cancel()
            }
            return cached?.data
        }
        guard !request.candidates.isEmpty else { return nil }
        thumbnailRequestInFlight = request
        let renderer = thumbnailRenderer
        thumbnailTask = coordinator.startMutation { [weak self] lease in
            guard let self else { return }
            let result = try await Self.refreshThumbnail(request, cached: cached, render: renderer)
            try Task.checkCancellation()
            try coordinator.validate(lease)
            if !coordinator.isClosing, thumbnailRequest() == request {
                cachedThumbnail = result
                if result.data != cached?.data { editorViewModel.onProjectCheckpointRequired?() }
            }
            finishThumbnailRequest(request)
        } onFailure: { [weak self] error in
            if let self, thumbnailRequestInFlight == request { cachedThumbnail = nil }
            self?.finishThumbnailRequest(request)
            if !(error is CancellationError) {
                Log.project.warning("thumbnail failed: \(error.localizedDescription)")
            }
        }
        return cached?.data
    }

    private func finishThumbnailRequest(_ request: ThumbnailRequest) {
        guard thumbnailRequestInFlight == request else { return }
        thumbnailTask = nil
        thumbnailRequestInFlight = nil
        let coordinator = editorViewModel.projectPackageCoordinator
        if !Task.isCancelled, thumbnailRetryTask == nil, !coordinator.isClosing, !coordinator.isClosed,
           thumbnailRequest() != request { _ = captureThumbnail() }
    }

    private func thumbnailRequest() -> ThumbnailRequest {
        let entries = editorViewModel.mediaManifest.entries
        let urls = MediaResolver.expectedURLMap(entries: entries, projectURL: editorViewModel.projectURL)
        var entriesByID: [String: MediaManifestEntry] = [:]
        for entry in entries where entriesByID[entry.id] == nil { entriesByID[entry.id] = entry }
        var candidates: [ThumbnailCandidate] = []
        for track in editorViewModel.timeline.tracks where track.type == .video {
            for clip in track.clips {
                guard clip.mediaType == .image || clip.mediaType == .video, clip.trimStartFrame >= 0,
                      let entry = entriesByID[clip.mediaRef], let url = urls[clip.mediaRef] else { continue }
                let asset = editorViewModel.mediaAssetsById[clip.mediaRef]
                guard asset == nil || asset?.url == url else { continue }
                candidates.append(ThumbnailCandidate(
                    clipID: clip.id, mediaRef: clip.mediaRef, url: url,
                    isVideo: clip.mediaType == .video, trimStartFrame: clip.trimStartFrame,
                    source: entry.source, inputIdentity: entry.inputIdentity,
                    assetIdentity: asset.map(ObjectIdentifier.init), assetURL: asset?.url,
                    assetInputIdentity: asset?.inputIdentity, generationStatus: asset?.generationStatus.serialized,
                    generationInput: asset?.generationInput ?? entry.generationInput, pendingDownloadURL: asset?.pendingDownloadURL
                ))
            }
        }
        return ThumbnailRequest(
            documentURL: fileURL, projectURL: editorViewModel.projectURL,
            timelineID: editorViewModel.timeline.id, fps: editorViewModel.timeline.fps,
            maxPixelSize: Self.thumbnailMaxPixelSize, candidates: candidates
        )
    }

    @concurrent
    private static func refreshThumbnail(
        _ request: ThumbnailRequest, cached: ThumbnailCache?,
        render: @Sendable (ThumbnailRequest) async throws -> Data?
    ) async throws -> ThumbnailCache {
        try Task.checkCancellation()
        let stamps = try thumbnailFileStamps(request)
        if let cached, cached.request == request, cached.stamps == stamps { return cached }
        let data = try await render(request)
        try Task.checkCancellation()
        guard try thumbnailFileStamps(request) == stamps else { throw CancellationError() }
        return ThumbnailCache(request: request, stamps: stamps, data: data)
    }

    private nonisolated static func thumbnailFileStamps(_ request: ThumbnailRequest) throws -> [ThumbnailFileStamp?] {
        try request.candidates.map { candidate in
            try Task.checkCancellation()
            do {
                let values = try FileManager.default.attributesOfItem(atPath: candidate.url.path)
                return ThumbnailFileStamp(
                    fileNumber: (values[.systemFileNumber] as? NSNumber)?.uint64Value,
                    size: (values[.size] as? NSNumber)?.intValue,
                    modified: values[.modificationDate] as? Date, created: values[.creationDate] as? Date
                )
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                return nil
            }
        }
    }

    @concurrent
    private static func renderThumbnail(_ request: ThumbnailRequest) async throws -> Data? {
        guard request.fps > 0, request.fps <= Int(Int32.max) else { return nil }
        for candidate in request.candidates {
            try Task.checkCancellation()
            do {
                if candidate.isVideo {
                    let time = CMTime(value: CMTimeValue(candidate.trimStartFrame), timescale: CMTimeScale(request.fps))
                    let renderer = ProjectThumbnailFrameRenderer(url: candidate.url, time: time, maxPixelSize: request.maxPixelSize)
                    let image = try await renderer.render()
                    try Task.checkCancellation()
                    if let data = ImageEncoder.encodeJPEG(image, quality: 0.7) { return data }
                } else if let image = ImageEncoder.thumbnail(url: candidate.url, maxPixelSize: request.maxPixelSize),
                          let data = ImageEncoder.encodeJPEG(image, quality: 0.7) {
                    return data
                }
            } catch {
                try Task.checkCancellation()
            }
        }
        return nil
    }

    // MARK: - Media restore

    private struct MediaRestoreTarget {
        let entry: MediaManifestEntry
        let candidate: RestoredMediaCandidate?
        let asset: MediaAsset?
        let assetSnapshot: MediaManifestEntry?
        let pendingDownloadURL: URL?
        let requiresRecoveryNormalization: Bool
    }

    private struct RestoredMediaMetadata: Sendable {
        let duration: Double
        let sourceWidth: Int?
        let sourceHeight: Int?
        let sourceFPS: Double?
        let hasAudio: Bool
    }

    private var mediaRestoreTask: Task<Void, Never>?
    private var mediaRestoreRevision = UUID()
    private var pendingMediaRestoreStates: [ObjectIdentifier: MediaManifestEntry] = [:]
    var mediaRestoreScanner: @Sendable ([URL]) async throws -> Set<URL> = { urls in
        try await VideoProject.existingMediaURLs(urls)
    }
    var restoredMetadataLoader: @MainActor (MediaAsset) async -> Bool = { asset in
        await asset.loadMetadata(includeThumbnail: false)
    }

    func cancelDocumentBackgroundWork() {
        editorViewModel.cancelAudioMix()
        editorViewModel.cancelProductionRuns()
        thumbnailTask?.cancel()
        thumbnailRetryTask?.cancel()
        mediaRestoreTask?.cancel()
        cachedThumbnail = nil
    }

    func restoreAssetsFromManifest() {
        let coordinator = editorViewModel.projectPackageCoordinator
        guard !coordinator.isClosing, !coordinator.isClosed else { return }
        let previousTask = mediaRestoreTask
        previousTask?.cancel()
        let revision = UUID()
        mediaRestoreRevision = revision
        let documentURL = fileURL
        let projectURL = editorViewModel.projectURL
        let entries = editorViewModel.mediaManifest.entries
        let expectedURLs = MediaResolver.expectedURLMap(entries: entries, projectURL: projectURL)
        let existingAssets = editorViewModel.mediaAssetsById
        let existingIdentities = Set(existingAssets.values.map(ObjectIdentifier.init))
        pendingMediaRestoreStates = pendingMediaRestoreStates.filter { existingIdentities.contains($0.key) }
        var restoredAssets: [MediaAsset] = []
        var targets: [MediaRestoreTarget] = []
        var seen: Set<String> = []
        restoredAssets.reserveCapacity(entries.count)
        for entry in entries where seen.insert(entry.id).inserted {
            let candidate = expectedURLs[entry.id].map { RestoredMediaCandidate(id: entry.id, name: entry.name, url: $0) }
            let existing = existingAssets[entry.id]
            let asset = existing ?? candidate.map { MediaAsset(entry: entry, resolvedURL: $0.url) }
            let snapshot = asset?.toManifestEntry(projectURL: projectURL)
            if existing == nil, let asset, let snapshot {
                restoredAssets.append(asset)
                pendingMediaRestoreStates[ObjectIdentifier(asset)] = snapshot
            }
            targets.append(MediaRestoreTarget(
                entry: entry, candidate: candidate, asset: asset,
                assetSnapshot: snapshot, pendingDownloadURL: asset?.pendingDownloadURL,
                requiresRecoveryNormalization: asset.map { pendingMediaRestoreStates[ObjectIdentifier($0)] == snapshot } ?? false
            ))
        }
        if !restoredAssets.isEmpty { editorViewModel.mediaAssets.append(contentsOf: restoredAssets) }
        let scanner = mediaRestoreScanner
        let loader = restoredMetadataLoader
        let urls = targets.compactMap { $0.candidate?.url }
        let timelines = editorViewModel.timelines
        mediaRestoreTask = coordinator.startMutation { [weak self] lease in
            guard let self else { return }
            defer { if mediaRestoreRevision == revision { mediaRestoreTask = nil } }
            if let previousTask {
                await previousTask.value
                try Task.checkCancellation()
                try coordinator.validate(lease)
                guard isCurrentMediaRestore(revision, documentURL: documentURL, projectURL: projectURL) else { return }
            }
            let scan = try await Self.scanRestoredMedia(urls, timelines: timelines, scan: scanner)
            try Task.checkCancellation()
            try coordinator.validate(lease)
            guard isCurrentMediaRestore(revision, documentURL: documentURL, projectURL: projectURL) else { return }
            let currentEntries = mediaRestoreEntriesByID()
            var missingRefs = editorViewModel.missingMediaRefs
            var updates: [MediaAsset] = []
            var hydration: [MediaAsset] = []
            for target in targets {
                guard isCurrentMediaRestoreTarget(target, entries: currentEntries, projectURL: projectURL) else { continue }
                let exists = target.candidate.map { scan.existingURLs.contains($0.url) } ?? false
                guard let asset = target.asset else {
                    missingRefs.insert(target.entry.id)
                    continue
                }
                let interruptedImport = target.requiresRecoveryNormalization && !exists
                    && asset.importInput != nil && asset.generationStatus == .downloading
                if target.requiresRecoveryNormalization {
                    let oldStatus = asset.generationStatus
                    if asset.importInput != nil, oldStatus == .downloading {
                        asset.generationStatus = exists ? .none : .failed("Import interrupted")
                    } else if !exists, asset.isRecoveringGeneration {
                        asset.generationStatus = .generating
                    } else if exists, oldStatus != .none, !asset.canResumeGeneration {
                        asset.generationStatus = .none
                    }
                    if oldStatus != asset.generationStatus { updates.append(asset) }
                }
                pendingMediaRestoreStates.removeValue(forKey: ObjectIdentifier(asset))
                if exists || asset.isRecoveringGeneration || asset.isGenerating || interruptedImport {
                    missingRefs.remove(asset.id)
                } else {
                    missingRefs.insert(asset.id)
                }
                if exists, scan.usedRefs.contains(asset.id), !asset.isGenerating { hydration.append(asset) }
            }
            editorViewModel.updateManifestMetadata(for: updates)
            if missingRefs != editorViewModel.missingMediaRefs { editorViewModel.missingMediaRefs = missingRefs }
            var hydrationManifest = editorViewModel.mediaManifest
            var hydrationEntries = mediaRestoreEntriesByID()
            let hydrationTargets = hydration.compactMap { asset -> MediaRestoreTarget? in
                guard let entry = hydrationEntries[asset.id] else { return nil }
                return MediaRestoreTarget(
                    entry: entry, candidate: RestoredMediaCandidate(id: asset.id, name: asset.name, url: asset.url), asset: asset,
                    assetSnapshot: asset.toManifestEntry(projectURL: projectURL), pendingDownloadURL: asset.pendingDownloadURL,
                    requiresRecoveryNormalization: false
                )
            }
            var hydrated: [(target: MediaRestoreTarget, metadata: RestoredMediaMetadata)] = []
            for target in hydrationTargets {
                try Task.checkCancellation()
                guard isCurrentMediaRestore(revision, documentURL: documentURL, projectURL: projectURL) else { return }
                if hydrationManifest != editorViewModel.mediaManifest {
                    hydrationManifest = editorViewModel.mediaManifest
                    hydrationEntries = mediaRestoreEntriesByID()
                }
                guard isCurrentMediaRestoreTarget(target, entries: hydrationEntries, projectURL: projectURL),
                      let asset = target.asset, let state = target.assetSnapshot,
                      isMediaUsedOnTimeline(asset.id), !asset.isGenerating else { continue }
                let temporary = MediaAsset(entry: state, resolvedURL: asset.url)
                let loaded = await loader(temporary)
                try Task.checkCancellation()
                try coordinator.validate(lease)
                guard isCurrentMediaRestore(revision, documentURL: documentURL, projectURL: projectURL) else { return }
                if hydrationManifest != editorViewModel.mediaManifest {
                    hydrationManifest = editorViewModel.mediaManifest
                    hydrationEntries = mediaRestoreEntriesByID()
                }
                guard loaded, isCurrentMediaRestoreTarget(target, entries: hydrationEntries, projectURL: projectURL),
                      isMediaUsedOnTimeline(asset.id) else { continue }
                hydrated.append((target, RestoredMediaMetadata(
                    duration: temporary.duration, sourceWidth: temporary.sourceWidth, sourceHeight: temporary.sourceHeight,
                    sourceFPS: temporary.sourceFPS, hasAudio: temporary.hasAudio
                )))
            }
            var metadataUpdates: [MediaAsset] = []
            for result in hydrated {
                guard isCurrentMediaRestoreTarget(result.target, entries: hydrationEntries, projectURL: projectURL),
                      let asset = result.target.asset, isMediaUsedOnTimeline(asset.id) else { continue }
                asset.duration = result.metadata.duration
                asset.sourceWidth = result.metadata.sourceWidth
                asset.sourceHeight = result.metadata.sourceHeight
                asset.sourceFPS = result.metadata.sourceFPS
                asset.hasAudio = result.metadata.hasAudio
                metadataUpdates.append(asset)
                editorViewModel.prepareMediaVisuals(for: asset)
            }
            editorViewModel.updateManifestMetadata(for: metadataUpdates)
            editorViewModel.generationService.resumePendingGenerations(editor: editorViewModel)
            Log.project.notice("restore complete entries=\(entries.count) missing=\(editorViewModel.missingMediaRefs.count)")
        } onFailure: { [weak self] error in
            guard let self, mediaRestoreRevision == revision else { return }
            mediaRestoreTask = nil
            if !(error is CancellationError) { Log.project.warning("restore scan failed: \(error.localizedDescription)") }
        }
    }

    @concurrent
    private static func scanRestoredMedia(
        _ urls: [URL], timelines: [Timeline], scan: @Sendable ([URL]) async throws -> Set<URL>
    ) async throws -> (existingURLs: Set<URL>, usedRefs: Set<String>) {
        var usedRefs: Set<String> = []
        for timeline in timelines {
            for track in timeline.tracks {
                for clip in track.clips {
                    try Task.checkCancellation()
                    usedRefs.insert(clip.mediaRef)
                }
            }
        }
        let existingURLs = try await scan(urls)
        try Task.checkCancellation()
        return (existingURLs, usedRefs)
    }

    @concurrent
    private static func existingMediaURLs(_ urls: [URL]) async throws -> Set<URL> {
        var existing: Set<URL> = []
        for url in urls {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: url.path) { existing.insert(url) }
        }
        return existing
    }

    private func isCurrentMediaRestore(_ revision: UUID, documentURL: URL?, projectURL: URL?) -> Bool {
        let coordinator = editorViewModel.projectPackageCoordinator
        return !coordinator.isClosing && !coordinator.isClosed && mediaRestoreRevision == revision
            && fileURL == documentURL && editorViewModel.projectURL == projectURL
    }

    private func mediaRestoreEntriesByID() -> [String: MediaManifestEntry] {
        var entries: [String: MediaManifestEntry] = [:]
        for entry in editorViewModel.mediaManifest.entries where entries[entry.id] == nil { entries[entry.id] = entry }
        return entries
    }

    private func isCurrentMediaRestoreTarget(
        _ target: MediaRestoreTarget, entries: [String: MediaManifestEntry], projectURL: URL?
    ) -> Bool {
        guard entries[target.entry.id] == target.entry else { return false }
        let current = editorViewModel.mediaAssetsById[target.entry.id]
        guard current === target.asset else { return false }
        return current?.url == target.candidate?.url && current?.toManifestEntry(projectURL: projectURL) == target.assetSnapshot
            && current?.pendingDownloadURL == target.pendingDownloadURL
    }

    private func isMediaUsedOnTimeline(_ id: String) -> Bool {
        editorViewModel.timelines.contains { timeline in
            timeline.tracks.contains { track in track.clips.contains { $0.mediaRef == id } }
        }
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
        let host = NSHostingController(rootView: view.appLocalization().tint(AppTheme.Accent.primary))
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
