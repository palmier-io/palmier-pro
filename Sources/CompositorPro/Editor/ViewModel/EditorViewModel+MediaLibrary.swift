import AppKit
import AVFoundation

enum MediaPanelItemKey {
    static let folderPrefix = "folder-"
    static let timelinePrefix = "timeline-"

    static func folder(_ id: String) -> String {
        folderPrefix + id
    }

    static func folderId(from key: String) -> String? {
        guard key.hasPrefix(folderPrefix) else { return nil }
        return String(key.dropFirst(folderPrefix.count))
    }

    static func timeline(_ id: String) -> String {
        timelinePrefix + id
    }

    static func timelineId(from key: String) -> String? {
        guard key.hasPrefix(timelinePrefix) else { return nil }
        return String(key.dropFirst(timelinePrefix.count))
    }
}

private struct MediaImportPlan: Sendable {
    enum Parent: Sendable {
        case existingFolderId(String?)
        case plannedFolder(Int)
    }

    struct Folder: Sendable {
        let name: String
        let parent: Parent
    }

    struct File: Sendable {
        let url: URL
        let type: ClipType
        let name: String
        let parent: Parent
    }

    struct Rejection: Sendable {
        enum Reason: Sendable {
            case unsupportedType
            case notLottie
            case unreadable
        }

        let name: String
        let reason: Reason

        @MainActor var message: String {
            switch reason {
            case .unsupportedType:
                L10n.string("Can't import \"\(name)\" — unsupported file type.")
            case .notLottie:
                L10n.string("Can't import \"\(name)\" — not a Lottie animation.")
            case .unreadable:
                L10n.string("Can't read \"\(name)\" — it may be missing or you may not have permission.")
            }
        }
    }

    var folders: [Folder] = []
    var files: [File] = []
    var rejections: [Rejection] = []
}

private enum MediaImportScanner {
    struct Root: Sendable {
        let url: URL
        let parentFolderId: String?
    }

    enum EntryKind: Sendable {
        case directory
        case file
        case unreadable
    }

    static func scan(roots: [Root]) -> MediaImportPlan {
        var plan = MediaImportPlan()
        for root in roots {
            let parent = MediaImportPlan.Parent.existingFolderId(root.parentFolderId)
            switch kind(of: root.url) {
            case .directory: scanFolder(at: root.url, parent: parent, into: &plan)
            case .file: scanFile(at: root.url, parent: parent, into: &plan)
            case .unreadable: reject(root.url, reason: .unreadable, into: &plan)
            }
        }
        return plan
    }

    /// A path that is merely gone still imports — offline and relink flows depend on it — so
    /// only a stat that fails for any other reason counts as unreadable.
    static func kind(of url: URL) -> EntryKind {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes[.type] as? FileAttributeType) == .typeDirectory ? .directory : .file
        } catch let error as CocoaError {
            // Foundation reports a missing path as fileReadNoSuchFile here, not fileNoSuchFile.
            return [.fileNoSuchFile, .fileReadNoSuchFile].contains(error.code) ? .file : .unreadable
        } catch {
            return .unreadable
        }
    }

    private static func scan(entries: [URL], parent: MediaImportPlan.Parent, into plan: inout MediaImportPlan) {
        let sorted = entries.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        for entry in sorted {
            switch kind(of: entry) {
            case .directory: scanFolder(at: entry, parent: parent, into: &plan)
            case .file: scanFile(at: entry, parent: parent, into: &plan)
            case .unreadable: reject(entry, reason: .unreadable, into: &plan)
            }
        }
    }

    private static func scanFolder(
        at url: URL,
        parent: MediaImportPlan.Parent,
        into plan: inout MediaImportPlan
    ) {
        guard let entries = directoryEntries(at: url) else {
            reject(url, reason: .unreadable, into: &plan)
            return
        }
        let folderIndex = plan.folders.count
        plan.folders.append(.init(name: url.lastPathComponent, parent: parent))
        scan(entries: entries, parent: .plannedFolder(folderIndex), into: &plan)
    }

    private static func directoryEntries(at url: URL) -> [URL]? {
        try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
    }

    private static func scanFile(
        at url: URL,
        parent: MediaImportPlan.Parent,
        into plan: inout MediaImportPlan
    ) {
        guard let type = ClipType(fileExtension: url.pathExtension.lowercased()) else {
            reject(url, reason: .unsupportedType, into: &plan)
            return
        }
        if type == .lottie, !LottieVideoGenerator.isLottie(at: url) {
            reject(url, reason: .notLottie, into: &plan)
            return
        }
        plan.files.append(.init(
            url: url,
            type: type,
            name: url.deletingPathExtension().lastPathComponent,
            parent: parent
        ))
    }

    private static func reject(
        _ url: URL,
        reason: MediaImportPlan.Rejection.Reason,
        into plan: inout MediaImportPlan
    ) {
        plan.rejections.append(.init(name: url.lastPathComponent, reason: reason))
    }
}

extension EditorViewModel {

    func commitStagedProjectMedia(
        _ stagedURL: URL,
        filename: String,
        maxBytes: Int64? = nil,
        lease: ProjectPackageCoordinator.MutationLease,
        validate: @MainActor () throws -> Void = {},
        publish: @MainActor (URL) -> Void
    ) async throws -> URL {
        let coordinator = projectPackageCoordinator
        var prepared: URL?
        var installed: URL?
        var ownsStage = false
        do {
            let package = projectURL
            ownsStage = try await coordinator.io.perform {
                guard let package else { return true }
                let targetPath = package.resolvingSymlinksInPath().standardizedFileURL.path
                let stagePath = stagedURL.resolvingSymlinksInPath().standardizedFileURL.path
                return stagePath != targetPath && !stagePath.hasPrefix(targetPath + "/")
            }
            guard ownsStage else { throw CocoaError(.fileWriteInvalidFileName) }
            try Task.checkCancellation()
            try coordinator.validate(lease)
            guard let target = projectURL?.standardizedFileURL else { throw CocoaError(.fileNoSuchFile) }
            guard !filename.isEmpty, filename != ".", filename != "..",
                  !filename.contains("/"), !filename.contains("\\"), !filename.contains("\0") else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            try validate()
            let destination = target.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
                .appendingPathComponent(filename, isDirectory: false)
            let preparedURL = try await coordinator.io.prepare(stagedURL, for: target, maxBytes: maxBytes)
            prepared = preparedURL
            try Task.checkCancellation()
            try coordinator.validate(lease)
            guard projectURL?.standardizedFileURL.path == target.path else { throw CancellationError() }
            try validate()
            try await coordinator.io.install(preparedURL, to: destination)
            installed = destination
            try await coordinator.io.remove([stagedURL, preparedURL])
            prepared = nil
            try Task.checkCancellation()
            try coordinator.validate(lease)
            guard projectURL?.standardizedFileURL.path == target.path else { throw CancellationError() }
            try validate()
            publish(destination)
            return destination
        } catch {
            do {
                try await coordinator.io.remove((ownsStage ? [stagedURL] : []) + [prepared, installed].compactMap { $0 })
            } catch let cleanup {
                throw ProjectPackageCleanupError(operationError: error, cleanupError: cleanup)
            }
            throw error
        }
    }

    func rebaseProjectURL(from oldURL: URL, to newURL: URL) {
        guard projectURL?.standardizedFileURL == oldURL.standardizedFileURL else { return }
        let oldPrefix = oldURL.standardizedFileURL.path + "/"
        let newRoot = newURL.standardizedFileURL
        for asset in mediaAssets {
            let path = asset.url.standardizedFileURL.path
            guard path.hasPrefix(oldPrefix) else { continue }
            asset.relocate(to: newRoot.appendingPathComponent(String(path.dropFirst(oldPrefix.count))))
        }
        projectURL = newRoot
        refreshMissingMediaCache()
    }

    func importMediaAsset(_ asset: MediaAsset, skipAppend: Bool = false) {
        if !skipAppend, !mediaAssets.contains(where: { $0.id == asset.id }) {
            mediaAssets.append(asset)
        }
        updateManifestMetadata(for: [asset])
        Log.project.notice(
            "media imported asset=\(asset.id.prefix(8)) type=\(asset.type.rawValue)",
            telemetry: "Media asset imported",
            data: [
                "assetId": Telemetry.shortId(asset.id),
                "type": asset.type.rawValue,
                "skipAppend": skipAppend,
                "media": mediaAssets.count,
                "manifestEntries": mediaManifest.entries.count
            ]
        )
    }

    /// Resolve a drag pasteboard payload (one `palmier-asset://<id>` per line).
    func assetsFromDragPayload(_ payload: String) -> [MediaAsset] {
        payload.split(separator: "\n").compactMap { line in
            guard let id = MediaTab.assetId(fromDragString: String(line)) else { return nil }
            return mediaAssets.first { $0.id == id }
        }
    }

    func timelineIdsFromDragPayload(_ payload: String) -> [String] {
        payload.split(separator: "\n").compactMap { line in
            guard let id = MediaTab.timelineId(fromDragString: String(line)) else { return nil }
            return timeline(for: id)?.id
        }
    }

    /// Source-second ranges carried by search-moment drags, keyed by asset id.
    func segmentsFromDragPayload(_ payload: String) -> [String: ClosedRange<Double>] {
        var segments: [String: ClosedRange<Double>] = [:]
        for line in payload.split(separator: "\n") {
            guard let id = MediaTab.assetId(fromDragString: String(line)),
                  let segment = MediaTab.assetSegment(fromDragString: String(line)) else { continue }
            segments[id] = segment
        }
        return segments
    }

    func dismissMediaPanelToast() {
        mediaPanelToast = nil
    }

    @discardableResult
    func addMediaAsset(from url: URL, folderId: String? = nil, finalize: Bool = true) -> MediaAsset? {
        guard let type = ClipType(fileExtension: url.pathExtension.lowercased()) else {
            reportMediaRejection(.init(name: url.lastPathComponent, reason: .unsupportedType))
            return nil
        }
        if type == .lottie, !LottieVideoGenerator.isLottie(at: url) {
            reportMediaRejection(.init(name: url.lastPathComponent, reason: .notLottie))
            return nil
        }
        return addMediaAsset(from: url, type: type, folderId: folderId, finalize: finalize)
    }

    private func reportMediaRejection(_ rejection: MediaImportPlan.Rejection) {
        mediaPanelToast = MediaPanelToast(message: rejection.message)
    }

    /// A Finder drop or open-panel import that failed outright still has to say so.
    func reportMediaImportFailure(_ error: Error) {
        Log.project.error(
            "media import failed: \(error.localizedDescription)",
            telemetry: "Media import failed"
        )
        mediaPanelToast = MediaPanelToast(message: L10n.string("Import failed — \(error.localizedDescription)"))
    }

    @discardableResult
    func addMediaAsset(from url: URL, type: ClipType, folderId: String? = nil, finalize: Bool = true) -> MediaAsset {
        let name = url.deletingPathExtension().lastPathComponent
        let asset = MediaAsset(url: url, type: type, name: name)
        asset.importInput = MediaImportInput(sourcePath: url.path, createdAt: Date())
        asset.folderId = folderId
        importMediaAsset(asset)
        if finalize {
            projectPackageCoordinator.startMutation { _ in
                await self.finalizeImportedAsset(asset)
            } onFailure: { error in
                if !(error is CancellationError) { self.reportMediaImportFailure(error) }
            }
        }
        return asset
    }

    struct MediaImportSummary: Sendable {
        var assetCount: Int
        var folderCount: Int
        var assets: [MediaAsset] = []
    }

    /// Import files and folders from the open panel or a Finder drop as one undo step
    @discardableResult
    func importFinderItems(
        _ urls: [URL],
        into folderId: String?,
        finalize: Bool = true,
        applying mutation: (@MainActor (@MainActor () -> MediaImportSummary) async throws -> MediaImportSummary)? = nil
    ) async throws -> MediaImportSummary {
        let previous = mediaImportTail
        mediaImportSequence &+= 1
        let sequence = mediaImportSequence
        let task = Task { @MainActor in
            _ = try? await previous?.value
            try Task.checkCancellation()
            return try await performFinderImport(urls, into: folderId, finalize: finalize, applying: mutation)
        }
        mediaImportTail = task

        defer {
            if mediaImportSequence == sequence { mediaImportTail = nil }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    @discardableResult
    private func performFinderImport(
        _ urls: [URL],
        into folderId: String?,
        finalize: Bool,
        applying mutation: (@MainActor (@MainActor () -> MediaImportSummary) async throws -> MediaImportSummary)?
    ) async throws -> MediaImportSummary {
        try await projectPackageCoordinator.withMutation { _ in
            let roots = urls.map { MediaImportScanner.Root(url: $0, parentFolderId: folderId) }
            let plan = try await self.projectPackageCoordinator.io.perform { MediaImportScanner.scan(roots: roots) }
            try Task.checkCancellation()
            if let folderId, self.folder(id: folderId) == nil { throw CocoaError(.fileNoSuchFile) }
            let before = self.mediaLibraryUndoSnapshot()
            let summary: MediaImportSummary
            if let mutation {
                summary = try await mutation { self.applyMediaImportPlan(plan, restoringFrom: before) }
            } else {
                summary = self.applyMediaImportPlan(plan, restoringFrom: before)
            }
            if finalize {
                for asset in summary.assets {
                    try Task.checkCancellation()
                    await self.finalizeImportedAsset(asset, batchManifestUpdate: true)
                }
            }
            self.flushPendingManifestMetadataUpdates()
            return summary
        }
    }

    @discardableResult
    private func applyMediaImportPlan(
        _ plan: MediaImportPlan,
        restoringFrom before: MediaLibraryUndoSnapshot
    ) -> MediaImportSummary {
        let importedAssets = undo.withoutRegistration {
            var folderIds = Array(repeating: "", count: plan.folders.count)
            for (index, folder) in plan.folders.enumerated() {
                let parentId = parentFolderId(for: folder.parent, plannedFolderIds: folderIds)
                folderIds[index] = createFolder(name: folder.name, in: parentId)
            }

            let importedAssets = plan.files.map { file in
                let folderId = parentFolderId(for: file.parent, plannedFolderIds: folderIds)
                let asset = MediaAsset(url: file.url, type: file.type, name: file.name)
                asset.folderId = folderId
                return asset
            }
            if !importedAssets.isEmpty {
                mediaAssets.append(contentsOf: importedAssets)
                mediaManifest.entries.append(contentsOf: importedAssets.map { $0.toManifestEntry(projectURL: projectURL) })
                Log.project.notice(
                    "media import applied assets=\(importedAssets.count) folders=\(plan.folders.count)",
                    telemetry: "Media import applied",
                    data: [
                        "assets": importedAssets.count,
                        "folders": plan.folders.count,
                        "media": mediaAssets.count,
                        "manifestEntries": mediaManifest.entries.count
                    ]
                )
            }
            return importedAssets
        }

        if plan.rejections.count == 1, let rejection = plan.rejections.first {
            reportMediaRejection(rejection)
        } else if plan.rejections.count > 1, let first = plan.rejections.first {
            mediaPanelToast = MediaPanelToast(message: L10n.string(
                "Skipped \(plan.rejections.count) items that can't be imported, starting with \"\(first.name)\"."
            ))
        }

        let summary = MediaImportSummary(
            assetCount: mediaAssets.count - before.mediaAssets.count,
            folderCount: mediaManifest.folders.count - before.mediaManifest.folders.count,
            assets: importedAssets
        )
        guard summary.assetCount != 0 || summary.folderCount != 0 else { return summary }
        undo.register("Import Media", withTarget: self) { vm in
            vm.restoreMediaLibraryUndoSnapshot(before, actionName: "Import Media")
        }
        return summary
    }

    private func parentFolderId(for parent: MediaImportPlan.Parent, plannedFolderIds: [String]) -> String? {
        switch parent {
        case .existingFolderId(let id):
            id
        case .plannedFolder(let index):
            plannedFolderIds[index]
        }
    }

    func dropPlaceholderAssets(for urls: [URL]) -> [MediaAsset] {
        urls.compactMap { url in
            // hasDirectoryPath avoids disk access on the drag-hover path.
            guard !url.hasDirectoryPath,
                  let type = ClipType(fileExtension: url.pathExtension.lowercased()) else { return nil }
            let asset = MediaAsset(
                url: url, type: type,
                name: url.deletingPathExtension().lastPathComponent,
                duration: Defaults.imageDurationSeconds
            )
            asset.hasAudio = type == .video
            return asset
        }
    }

    func importFinderItemsToTimeline(
        _ urls: [URL],
        cursor: TrackDropTarget,
        atFrame: Int,
        ripple: Bool
    ) async {
        do {
            _ = try await importFinderItems(urls, into: mediaPanelCurrentFolderId, finalize: false) { apply in
                let before = self.mediaLibraryUndoSnapshot()
                let summary = self.undo.withoutRegistration { apply() }
                guard summary.assetCount != 0 || summary.folderCount != 0 else { return summary }
                var placeable: [MediaAsset] = []
                for asset in summary.assets {
                    if await self.finalizeImportedAsset(asset, batchManifestUpdate: true) { placeable.append(asset) }
                }
                var captionSpecSets: [[TextClipSpec]] = []
                for asset in placeable where asset.type == .subtitle {
                    guard let url = self.mediaResolver.resolveURL(for: asset.id) else { continue }
                    do {
                        captionSpecSets.append(try await self.subtitleCaptionSpecs(from: url))
                    } catch {
                        self.mediaPanelToast = MediaPanelToast(
                            message: L10n.string("Can't add captions from \"\(asset.name)\" — \(error.localizedDescription)")
                        )
                    }
                }
                guard !Task.isCancelled, summary.assets.allSatisfy({ self.mediaAssetsById[$0.id] === $0 }) else { return summary }
                let operation: @MainActor () -> Void = {
                    self.undo.perform("Add Media") {
                        self.undo.register("Add Media", withTarget: self) { vm in
                            vm.restoreMediaLibraryUndoSnapshot(before, actionName: "Add Media")
                        }
                        if !placeable.isEmpty { self.placeDroppedAssets(placeable, cursor: cursor, atFrame: atFrame, ripple: ripple) }
                        for specs in captionSpecSets { self.placeCaptionTrack(specs, actionName: "Add Media") }
                    }
                }
                if placeable.isEmpty { operation() }
                else { self.addClipsWithSettingsCheck(assets: placeable, operation: operation) }
                return summary
            }
        } catch {
            reportMediaImportFailure(error)
        }
    }

    @discardableResult
    func importPastedImageData(_ data: Data, fileExtension: String = "png") async -> MediaAsset? {
        let filename = "pasted-\(UUID().uuidString).\(fileExtension)"
        do {
            return try await projectPackageCoordinator.withMutation { lease in
                guard let type = ClipType(fileExtension: fileExtension) else { throw CocoaError(.fileReadUnsupportedScheme) }
                let stagedURL = try await self.projectPackageCoordinator.io.perform { try FileIO.stageData(data, pathExtension: fileExtension) }
                var imported: MediaAsset?
                _ = try await self.commitStagedProjectMedia(stagedURL, filename: filename, lease: lease) { destination in
                    imported = self.addMediaAsset(from: destination, type: type, finalize: false)
                }
                if let imported { await self.finalizeImportedAsset(imported) }
                return imported
            }
        } catch {
            reportMediaImportFailure(error)
            return nil
        }
    }

    func fitTextClipToContentIfNeeded(_ clip: inout Clip, canvasW: Double, canvasH: Double) -> Bool {
        guard clip.mediaType == .text else { return false }
        let natural = TextLayout.naturalSize(
            content: clip.textContent ?? " ",
            style: clip.textStyle ?? TextStyle(),
            maxWidth: CGFloat(canvasW) * 0.9,
            canvasHeight: CGFloat(canvasH)
        )
        let needW = Double(natural.width) / canvasW
        let needH = Double(natural.height) / canvasH
        let currentW = clip.transform.width
        let currentH = clip.transform.height
        if abs(needW - currentW) < 0.0001 && abs(needH - currentH) < 0.0001 { return false }
        let tl = clip.transform.topLeft
        let cy = tl.y + currentH / 2
        let alignment = (clip.textStyle ?? TextStyle()).alignment
        let cx: Double
        switch alignment {
        case .left:
            cx = tl.x + needW / 2
        case .right:
            cx = (tl.x + currentW) - needW / 2
        case .center:
            cx = tl.x + currentW / 2
        }
        if var track = clip.scaleTrack, currentW > 0, currentH > 0 {
            for index in track.keyframes.indices {
                track.keyframes[index].value.a *= needW / currentW
                track.keyframes[index].value.b *= needH / currentH
            }
            clip.scaleTrack = track
        }
        clip.transform.centerX = cx
        clip.transform.centerY = cy
        clip.transform.width = needW
        clip.transform.height = needH
        return true
    }

    func clipDisplayLabel(for clip: Clip) -> String {
        if clip.mediaType == .text {
            let content = clip.textContent ?? ""
            if content.isEmpty { return "Text" }
            // Timeline label bar is single-line.
            return content
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
        }
        if let asset = mediaAssetsById[clip.mediaRef], asset.isGenerating {
            return asset.name
        }
        if clip.sourceClipType == .sequence, let nested = timeline(for: clip.mediaRef) {
            return nested.name
        }
        return mediaResolver.displayName(for: clip.mediaRef)
    }

    /// missing on disk or present-but-unloadable (no permission, ejected volume)
    func isMediaOffline(_ mediaRef: String) -> Bool {
        offlineMediaRefs.contains(mediaRef)
            || unprocessableMediaRefs.contains(mediaRef)
            || missingMediaRefs.contains(mediaRef)
    }

    /// Present-but-unpreparable (e.g. failed to encode)
    func isMediaUnprocessable(_ mediaRef: String) -> Bool {
        unprocessableMediaRefs.contains(mediaRef) && !missingMediaRefs.contains(mediaRef)
    }

    /// Recompute `missingMediaRefs` off the main thread, then publish on the main actor.
    func refreshMissingMediaCache() {
        let entries = mediaManifest.entries
        let projectPath = projectURL?.path
        missingMediaRefreshTask?.cancel()
        missingMediaRefreshTask = Task { [weak self] in
            let missing = await Task.detached(priority: .utility) {
                MediaResolver.missingAssetIds(entries: entries, projectPath: projectPath)
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                let recovering = Set(self.mediaAssets.lazy.filter { $0.isGenerating || $0.isRecoveringGeneration }.map(\.id))
                let resolved = missing.subtracting(recovering)
                if self.missingMediaRefs != resolved {
                    self.missingMediaRefs = resolved
                }
                self.missingMediaRefreshTask = nil
            }
        }
    }

    func isClipMediaOffline(_ clip: Clip) -> Bool {
        if clip.sourceClipType == .sequence {
            return timeline(for: clip.mediaRef) == nil
        }
        return clip.mediaType != .text && isMediaOffline(clip.mediaRef)
    }

    func isClipMediaGenerating(_ clip: Clip) -> Bool {
        guard clip.mediaType != .text else { return false }
        return mediaAssetsById[clip.mediaRef]?.isGenerating ?? false
    }

    func renameMediaAsset(id: String, name: String) {
        guard let asset = mediaAssets.first(where: { $0.id == id }) else { return }
        let oldName = asset.name
        asset.name = name
        if let idx = mediaManifest.entries.firstIndex(where: { $0.id == id }) {
            mediaManifest.entries[idx].name = name
        }
        undo.register("Rename Asset", withTarget: self) { vm in
            vm.renameMediaAsset(id: id, name: oldName)
        }
    }

    func updateManifestMetadata(for assets: [MediaAsset]) {
        guard !assets.isEmpty else { return }
        var manifest = mediaManifest
        var indices: [String: Int] = [:]
        for index in manifest.entries.indices {
            indices[manifest.entries[index].id] = index
        }
        for asset in assets {
            let entry = asset.toManifestEntry(projectURL: projectURL)
            if let index = indices[asset.id] {
                manifest.entries[index] = entry
            } else {
                indices[asset.id] = manifest.entries.count
                manifest.entries.append(entry)
            }
        }
        mediaManifest = manifest
    }

    func queueManifestMetadataUpdate(for asset: MediaAsset) {
        pendingManifestMetadataUpdates[asset.id] = asset
        if pendingManifestMetadataUpdates.count >= 64 {
            flushPendingManifestMetadataUpdates()
        } else if pendingManifestMetadataFlushTask == nil {
            pendingManifestMetadataFlushTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(20))
                guard !Task.isCancelled, let self else { return }
                pendingManifestMetadataFlushTask = nil
                flushPendingManifestMetadataUpdates()
            }
        }
    }

    func flushPendingManifestMetadataUpdates() {
        pendingManifestMetadataFlushTask?.cancel()
        pendingManifestMetadataFlushTask = nil
        let assets = pendingManifestMetadataUpdates.values.filter {
            mediaAssetsById[$0.id] === $0
        }
        pendingManifestMetadataUpdates.removeAll(keepingCapacity: true)
        updateManifestMetadata(for: assets)
    }

    @discardableResult
    func finalizeImportedAsset(
        _ asset: MediaAsset,
        batchManifestUpdate: Bool = false,
        loadMetadata: MediaAssetMetadata.Loader = MediaAssetMetadata.load,
        identify: @Sendable (URL) async throws -> MediaInputIdentity = { try await MediaInputIdentityService.shared.identify($0) },
        onTerminalPublication: (@MainActor (MediaAsset.PreparationContext) -> Void)? = nil
    ) async -> Bool {
        Log.project.debug("media finalize start asset=\(asset.id.prefix(8)) type=\(asset.type.rawValue)")
        let context = asset.preparationContext
        let isCurrent: @MainActor () -> Bool = {
            !Task.isCancelled && !self.projectPackageCoordinator.isClosed
                && self.mediaAssetsById[asset.id] === asset && asset.preparationContext == context
        }
        guard isCurrent() else { return false }
        let metadata: MediaAssetMetadata
        do {
            metadata = try await asset.readMetadata(
                thumbnailMaxPixelSize: batchManifestUpdate ? nil : ImageEncoder.maxLongestEdge,
                load: loadMetadata, validate: isCurrent
            )
        } catch is CancellationError {
            return false
        } catch {
            guard isCurrent() else { return false }
            metadata = MediaAssetMetadata(isReadable: false)
        }
        guard isCurrent() else { return false }
        asset.applyMetadata(metadata)
        guard metadata.isReadable else {
            let sourceURL = context.sourceURL
            let exists = await Task.detached(priority: .utility) { FileManager.default.fileExists(atPath: sourceURL.path) }.value
            guard isCurrent() else { return false }
            if exists {
                unprocessableMediaRefs.insert(asset.id)
            } else {
                missingMediaRefs.insert(asset.id)
            }
            if asset.isGenerating || asset.isGenerated || asset.importInput != nil {
                asset.generationStatus = .failed("Could not read media file.")
            }
            recordManifestMetadata(for: asset, batching: batchManifestUpdate)
            onTerminalPublication?(asset.preparationContext)
            Log.project.warning(
                "media finalize unreadable asset=\(asset.id.prefix(8)) type=\(asset.type.rawValue)",
                telemetry: "Media asset finalize unreadable",
                data: ["assetId": Telemetry.shortId(asset.id), "type": asset.type.rawValue]
            )
            refreshMissingMediaCache()
            refreshPreviewForFinalizedAsset(asset)
            return false
        }
        do {
            try await asset.prepareInputIdentity(validate: isCurrent, identify: identify)
        } catch is CancellationError {
            return false
        } catch {
            guard isCurrent() else { return false }
            asset.generationStatus = .failed("Could not identify media file.")
            recordManifestMetadata(for: asset, batching: batchManifestUpdate)
            onTerminalPublication?(asset.preparationContext)
            Log.project.warning("media identity failed asset=\(asset.id) error=\(error.localizedDescription)")
            return false
        }
        guard isCurrent() else { return false }
        if asset.isGenerating || asset.importInput != nil {
            asset.generationStatus = .none
        }
        recordManifestMetadata(for: asset, batching: batchManifestUpdate)
        onTerminalPublication?(asset.preparationContext)
        missingMediaRefs.remove(asset.id)
        offlineMediaRefs.remove(asset.id)
        unprocessableMediaRefs.remove(asset.id)
        refreshMissingMediaCache()
        searchIndex.schedule(asset)
        if !batchManifestUpdate {
            prepareMediaVisuals(for: asset)
        }
        refreshPreviewForFinalizedAsset(asset)
        Log.project.debug(
            "media finalize ok asset=\(asset.id.prefix(8)) type=\(asset.type.rawValue) duration=\(asset.duration)"
        )
        return true
    }

    func prepareMediaVisuals(for asset: MediaAsset) {
        switch asset.type {
        case .video:
            mediaVisualCache.generateWaveform(for: asset)
            mediaVisualCache.generateVideoThumbnails(for: asset)
        case .audio:
            mediaVisualCache.generateWaveform(for: asset)
        case .image:
            mediaVisualCache.generateImageThumbnail(for: asset)
        case .text, .lottie, .sequence, .subtitle:
            break
        }
    }

    private func recordManifestMetadata(for asset: MediaAsset, batching: Bool) {
        if batching {
            queueManifestMetadataUpdate(for: asset)
        } else {
            updateManifestMetadata(for: [asset])
        }
    }

    private func refreshPreviewForFinalizedAsset(_ asset: MediaAsset) {
        let usedOnTimeline = ([timeline] + timeline.reachableTimelines(resolve: timeline(for:))).contains { t in
            t.tracks.contains { $0.clips.contains { $0.mediaRef == asset.id } }
        }
        if usedOnTimeline {
            timelineRenderRevision &+= 1
            videoEngine?.rebuild()
        }
        if case .mediaAsset(let id, _, let type) = activePreviewTab,
           id == asset.id,
           type != .image, type != .subtitle {
            videoEngine?.previewAsset(asset)
            videoEngine?.seek(to: sourcePlayheadFrame, mode: .exact)
        }
    }

    struct TextClipSpec: Sendable {
        let trackIndex: Int
        var startFrame: Int
        var durationFrames: Int
        let content: String
        let style: TextStyle
        /// When nil the box is auto-fit to content and centered on the canvas.
        let transform: Transform?
        var captionGroupId: String? = nil
        /// Per-word timing (clip-relative frames) for karaoke animation; empty when unavailable.
        var words: [WordTiming]? = nil
        var animation: TextAnimation? = nil
        var fillMode: TextFillMode? = nil
    }

    /// Batch variant of `addTextClip` for agent flows.
    /// Caller owns undo + track creation.
    @discardableResult
    func placeTextClips(_ specs: [TextClipSpec], clearExistingRegions: Bool = true, refreshVisuals: Bool = true) -> [String] {
        guard !specs.isEmpty else { return [] }
        let canvasW = Double(timeline.width)
        let canvasH = Double(timeline.height)
        var createdIds = [String?](repeating: nil, count: specs.count)
        var batchTimeline = clearExistingRegions ? nil : timeline

        let orderedIndices: [Int]
        if clearExistingRegions {
            orderedIndices = Dictionary(grouping: specs.indices, by: { specs[$0].trackIndex })
                .values.flatMap { indices in
                    indices.sorted { specs[$0].startFrame < specs[$1].startFrame }
                }
        } else {
            orderedIndices = Array(specs.indices)
        }

        for i in orderedIndices {
            let spec = specs[i]
            let trackExists = batchTimeline?.tracks.indices.contains(spec.trackIndex)
                ?? timeline.tracks.indices.contains(spec.trackIndex)
            guard trackExists else { continue }
            let start = max(0, spec.startFrame)
            let duration = max(1, spec.durationFrames)
            if clearExistingRegions {
                clearRegion(trackIndex: spec.trackIndex, start: start, end: start + duration, prune: false)
            }

            let resolved: Transform
            if let t = spec.transform {
                resolved = t
            } else {
                let natural = TextLayout.naturalSize(
                    content: spec.content, style: spec.style, maxWidth: CGFloat(canvasW) * 0.9, canvasHeight: CGFloat(canvasH)
                )
                let w = Double(natural.width) / canvasW
                let h = Double(natural.height) / canvasH
                resolved = Transform(topLeft: ((1 - w) / 2, (1 - h) / 2), width: w, height: h)
            }
            var clip = Clip(
                mediaRef: "",
                mediaType: .text,
                sourceClipType: .text,
                startFrame: start,
                durationFrames: duration,
                transform: resolved
            )
            clip.textContent = spec.content
            clip.textStyle = spec.style
            clip.captionGroupId = spec.captionGroupId
            clip.wordTimings = spec.words
            clip.textAnimation = spec.animation
            if let fillMode = spec.fillMode {
                clip.setTextFillMode(fillMode, footageMatteColor: spec.style.color)
            }
            if batchTimeline != nil {
                batchTimeline!.tracks[spec.trackIndex].clips.append(clip)
            } else {
                timeline.tracks[spec.trackIndex].clips.append(clip)
            }
            createdIds[i] = clip.id
        }

        if var updatedTimeline = batchTimeline {
            guard createdIds.contains(where: { $0 != nil }) else { return [] }
            for i in Set(specs.map(\.trackIndex)) where updatedTimeline.tracks.indices.contains(i) {
                updatedTimeline.tracks[i].clips.sort { $0.startFrame < $1.startFrame }
            }
            timeline = updatedTimeline
        } else {
            for i in Set(specs.map(\.trackIndex)) where timeline.tracks.indices.contains(i) {
                sortClips(trackIndex: i)
            }
        }
        if refreshVisuals {
            videoEngine?.refreshVisuals()
        }
        return createdIds.compactMap { $0 }
    }

    @discardableResult
    func addTextClip(content: String = "Text", style: TextStyle = TextStyle()) -> String? {
        let durationFrames = max(1, secondsToFrame(seconds: Defaults.textDurationSeconds, fps: timeline.fps))
        let canvasW = Double(timeline.width)
        let canvasH = Double(timeline.height)
        let natural = TextLayout.naturalSize(content: content, style: style, maxWidth: CGFloat(canvasW) * 0.9, canvasHeight: CGFloat(canvasH))
        let w = Double(natural.width) / canvasW
        let h = Double(natural.height) / canvasH
        let transform = Transform(topLeft: ((1 - w) / 2, (1 - h) / 2), width: w, height: h)

        var clip = Clip(
            mediaRef: "",
            mediaType: .text,
            sourceClipType: .text,
            startFrame: max(0, currentFrame),
            durationFrames: durationFrames,
            transform: transform
        )
        clip.textContent = content
        clip.textStyle = style
        let clipId = clip.id

        withTimelineSwap(actionName: "Add Text") {
            let trackIdx = insertTrack(at: 0, type: .video)
            timeline.tracks[trackIdx].clips.append(clip)
            sortClips(trackIndex: trackIdx)
        }
        selectedClipIds = [clipId]
        return clipId
    }
}
