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

    var folders: [Folder] = []
    var files: [File] = []
    var rejectedUnsupportedNames: [String] = []
    var rejectedLottieNames: [String] = []
}

private enum MediaImportScanner {
    struct Root: Sendable {
        let url: URL
        let parentFolderId: String?
    }

    static func scan(roots: [Root]) -> MediaImportPlan {
        var plan = MediaImportPlan()
        for root in roots {
            let parent = MediaImportPlan.Parent.existingFolderId(root.parentFolderId)
            if isDirectory(root.url) {
                scanFolder(at: root.url, parent: parent, into: &plan)
            } else {
                scanFile(at: root.url, parent: parent, isRootItem: true, into: &plan)
            }
        }
        return plan
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    private static func scan(entries: [URL], parent: MediaImportPlan.Parent, into plan: inout MediaImportPlan) {
        let sorted = entries.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        for entry in sorted {
            if isDirectory(entry) {
                scanFolder(at: entry, parent: parent, into: &plan)
            } else {
                scanFile(at: entry, parent: parent, isRootItem: false, into: &plan)
            }
        }
    }

    private static func scanFolder(
        at url: URL,
        parent: MediaImportPlan.Parent,
        into plan: inout MediaImportPlan
    ) {
        guard let entries = directoryEntries(at: url) else { return }
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
        isRootItem: Bool,
        into plan: inout MediaImportPlan
    ) {
        guard let type = ClipType(fileExtension: url.pathExtension.lowercased()) else {
            if isRootItem { plan.rejectedUnsupportedNames.append(url.lastPathComponent) }
            return
        }
        if type == .lottie, !LottieVideoGenerator.isLottie(at: url) {
            plan.rejectedLottieNames.append(url.lastPathComponent)
            return
        }
        plan.files.append(.init(
            url: url,
            type: type,
            name: url.deletingPathExtension().lastPathComponent,
            parent: parent
        ))
    }
}

extension EditorViewModel {

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
    func addMediaAsset(from url: URL, folderId: String? = nil) -> MediaAsset? {
        guard let type = ClipType(fileExtension: url.pathExtension.lowercased()) else {
            mediaPanelToast = "Can't import \"\(url.lastPathComponent)\" — unsupported file type."
            return nil
        }
        if type == .lottie, !LottieVideoGenerator.isLottie(at: url) {
            mediaPanelToast = "Can't import \"\(url.lastPathComponent)\" — not a Lottie animation."
            return nil
        }
        return addMediaAsset(from: url, type: type, folderId: folderId)
    }

    @discardableResult
    private func addMediaAsset(from url: URL, type: ClipType, folderId: String? = nil) -> MediaAsset {
        let name = url.deletingPathExtension().lastPathComponent
        let asset = MediaAsset(url: url, type: type, name: name)
        asset.folderId = folderId
        importMediaAsset(asset)
        Task { await finalizeImportedAsset(asset) }
        return asset
    }

    struct MediaImportSummary: Sendable {
        var assetCount: Int
        var folderCount: Int
    }

    /// Import files and folders from the open panel or a Finder drop as one undo step
    @discardableResult
    func importFinderItems(_ urls: [URL], into folderId: String?) async -> MediaImportSummary {
        let previous = mediaImportTail
        mediaImportSequence &+= 1
        let sequence = mediaImportSequence
        let task = Task { @MainActor in
            _ = await previous?.value
            return await performFinderImport(urls, into: folderId)
        }
        mediaImportTail = task

        let summary = await task.value
        if mediaImportSequence == sequence {
            mediaImportTail = nil
        }
        return summary
    }

    @discardableResult
    private func performFinderImport(_ urls: [URL], into folderId: String?) async -> MediaImportSummary {
        let before = mediaLibraryUndoSnapshot()
        let roots = urls.map { MediaImportScanner.Root(url: $0, parentFolderId: folderId) }

        let plan = await Task.detached(priority: .userInitiated) {
            MediaImportScanner.scan(roots: roots)
        }.value
        return applyMediaImportPlan(plan, restoringFrom: before)
    }

    @discardableResult
    private func applyMediaImportPlan(_ plan: MediaImportPlan, restoringFrom before: MediaLibraryUndoSnapshot) -> MediaImportSummary {
        undoManager?.disableUndoRegistration()

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
        undoManager?.enableUndoRegistration()

        if let name = plan.rejectedUnsupportedNames.last {
            mediaPanelToast = "Can't import \"\(name)\" — unsupported file type."
        } else if let name = plan.rejectedLottieNames.last {
            mediaPanelToast = "Can't import \"\(name)\" — not a Lottie animation."
        }

        let summary = MediaImportSummary(
            assetCount: mediaAssets.count - before.mediaAssets.count,
            folderCount: mediaManifest.folders.count - before.mediaManifest.folders.count
        )
        guard summary.assetCount != 0 || summary.folderCount != 0 else { return summary }
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.restoreMediaLibraryUndoSnapshot(before, actionName: "Import Media")
        }
        undoManager?.setActionName("Import Media")
        for asset in importedAssets {
            Task { await finalizeImportedAsset(asset, batchManifestUpdate: true) }
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

    @discardableResult
    func importPastedImageData(_ data: Data, fileExtension: String = "png") async -> MediaAsset? {
        let filename = "pasted-\(UUID().uuidString.prefix(8)).\(fileExtension)"
        let destURL: URL
        if let projectURL {
            let dir = projectURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
            destURL = dir.appendingPathComponent(filename)
        } else {
            destURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        }
        do {
            try await Task.detached(priority: .userInitiated) {
                try FileIO.writeData(data, to: destURL)
            }.value
        } catch {
            Log.project.error("importPastedImageData: write failed \(error.localizedDescription)")
            return nil
        }
        return addMediaAsset(from: destURL)
    }

    func fitTextClipToContent(clipId: String) {
        let canvasW = Double(timeline.width)
        let canvasH = Double(timeline.height)
        guard let loc = findClip(id: clipId) else { return }
        let original = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        var fitted = original
        guard fitTextClipToContentIfNeeded(&fitted, canvasW: canvasW, canvasH: canvasH) else { return }
        if dragBefore[clipId] == nil {
            dragBefore[clipId] = original
        }
        timeline.tracks[loc.trackIndex].clips[loc.clipIndex] = fitted
        videoEngine?.refreshVisuals()
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
        clip.transform = Transform(center: (cx, cy), width: needW, height: needH)
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

    enum MediaSelectionDirection {
        case left, right, up, down

        func step(columnCount: Int) -> Int {
            switch self {
            case .left: -1
            case .right: +1
            case .up: -columnCount
            case .down: +columnCount
            }
        }

        var startsFromEnd: Bool { self == .left || self == .up }
    }

    func moveMediaSelection(direction: MediaSelectionDirection) {
        let ordered = mediaPanelOrderedItemIds
        guard !ordered.isEmpty else { return }
        let selectedKeys = mediaPanelSelectedKeys()

        let next: String
        if let anchor = ordered.last(where: { selectedKeys.contains($0) }),
           let idx = ordered.firstIndex(of: anchor) {
            let raw = idx + direction.step(columnCount: max(1, mediaPanelColumnCount))
            let target = max(0, min(ordered.count - 1, raw))
            guard target != idx else { return }
            next = ordered[target]
        } else {
            next = direction.startsFromEnd ? ordered[ordered.count - 1] : ordered[0]
        }

        selectMediaPanelItem(next)
    }

    private func mediaPanelSelectedKeys() -> Set<String> {
        var keys = selectedMediaAssetIds
        keys.formUnion(selectedFolderIds.map(MediaPanelItemKey.folder))
        keys.formUnion(selectedTimelineIds.map(MediaPanelItemKey.timeline))
        return keys
    }

    func selectMediaPanelItem(_ key: String) {
        if let folderId = MediaPanelItemKey.folderId(from: key) {
            guard folder(id: folderId) != nil else { return }
            mediaPanelScrollTarget = key
            selectedFolderIds = [folderId]
            selectedMediaAssetIds.removeAll()
            selectedTimelineIds.removeAll()
            return
        }
        if let timelineId = MediaPanelItemKey.timelineId(from: key) {
            guard timeline(for: timelineId) != nil else { return }
            mediaPanelScrollTarget = key
            selectedTimelineIds = [timelineId]
            selectedFolderIds.removeAll()
            selectedMediaAssetIds.removeAll()
            return
        }
        guard let asset = mediaAssets.first(where: { $0.id == key }) else { return }
        mediaPanelScrollTarget = key
        selectMediaAsset(asset)
    }

    func renameMediaAsset(id: String, name: String) {
        guard let asset = mediaAssets.first(where: { $0.id == id }) else { return }
        let oldName = asset.name
        asset.name = name
        if let idx = mediaManifest.entries.firstIndex(where: { $0.id == id }) {
            mediaManifest.entries[idx].name = name
        }
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.renameMediaAsset(id: id, name: oldName)
        }
        undoManager?.setActionName("Rename Asset")
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

    /// Text is composited via `CALayer.render` — `AVAssetImageGenerator`
    /// doesn't evaluate `animationTool` on single-frame extraction.
    func captureCurrentFrameToMedia() {
        guard let currentItem = videoEngine?.player.currentItem else {
            Log.project.error("captureCurrentFrameToMedia: no preview item")
            return
        }

        let tab = activePreviewTab
        let isTimelineTab: Bool
        let frame: Int
        let nameBase: String
        switch tab {
        case .timeline:
            isTimelineTab = true
            frame = currentFrame
            nameBase = "Frame"
        case .mediaAsset(let id, _, let type):
            guard type == .video else { return }
            isTimelineTab = false
            frame = sourcePlayheadFrame
            nameBase = mediaAssets.first(where: { $0.id == id })?.name ?? "Frame"
        }

        let asset = currentItem.asset
        let fps = timeline.fps
        let canvas = CGSize(width: timeline.width, height: timeline.height)
        let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))

        let videoComposition = isTimelineTab ? currentItem.videoComposition : nil

        Task.detached {
            guard (try? await asset.loadTracks(withMediaType: .video).first) != nil else {
                Log.project.error("captureCurrentFrameToMedia: no video track")
                return
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            if let videoComposition {
                generator.videoComposition = videoComposition
                generator.maximumSize = canvas
            }

            let videoCG: CGImage
            do {
                videoCG = try await generator.image(at: time).image
            } catch {
                Log.project.error("captureCurrentFrameToMedia: generate failed \(error.localizedDescription)")
                return
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                // The timeline videoComposition already composites text via CustomVideoCompositor.
                let rep = NSBitmapImageRep(cgImage: videoCG)
                guard let data = rep.representation(using: .png, properties: [:]) else {
                    Log.project.error("captureCurrentFrameToMedia: png encode failed")
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self,
                          let mediaAsset = await self.importPastedImageData(data, fileExtension: "png") else { return }
                    mediaAsset.name = "\(nameBase) \(frame)"
                    if let idx = self.mediaManifest.entries.firstIndex(where: { $0.id == mediaAsset.id }) {
                        self.mediaManifest.entries[idx].name = mediaAsset.name
                    }
                    self.moveAssetsToFolder(assetIds: [mediaAsset.id], folderId: self.mediaPanelCurrentFolderId)
                }
            }
        }
    }

    @discardableResult
    func finalizeImportedAsset(
        _ asset: MediaAsset,
        batchManifestUpdate: Bool = false
    ) async -> Bool {
        Log.project.debug("media finalize start asset=\(asset.id.prefix(8)) type=\(asset.type.rawValue)")
        let metadataLoaded = await asset.loadMetadata()
        guard metadataLoaded else {
            if FileManager.default.fileExists(atPath: asset.url.path) {
                unprocessableMediaRefs.insert(asset.id)
            } else {
                missingMediaRefs.insert(asset.id)
            }
            if asset.isGenerating || asset.isGenerated || asset.importInput != nil {
                asset.generationStatus = .failed("Could not read media file.")
            }
            recordManifestMetadata(for: asset, batching: batchManifestUpdate)
            Log.project.warning(
                "media finalize unreadable asset=\(asset.id.prefix(8)) type=\(asset.type.rawValue)",
                telemetry: "Media asset finalize unreadable",
                data: ["assetId": Telemetry.shortId(asset.id), "type": asset.type.rawValue]
            )
            refreshMissingMediaCache()
            refreshPreviewForFinalizedAsset(asset)
            return false
        }
        if asset.isGenerating {
            asset.generationStatus = .none
        }
        recordManifestMetadata(for: asset, batching: batchManifestUpdate)
        if FileManager.default.fileExists(atPath: asset.url.path) {
            missingMediaRefs.remove(asset.id)
            offlineMediaRefs.remove(asset.id)
            unprocessableMediaRefs.remove(asset.id)
        }
        refreshMissingMediaCache()
        searchIndex.schedule(asset)
        switch asset.type {
        case .video:
            mediaVisualCache.generateWaveform(for: asset)
            mediaVisualCache.generateVideoThumbnails(for: asset)
        case .audio:
            mediaVisualCache.generateWaveform(for: asset)
        case .image:
            mediaVisualCache.generateImageThumbnail(for: asset)
        case .text, .lottie, .sequence:
            break
        }
        refreshPreviewForFinalizedAsset(asset)
        Log.project.debug(
            "media finalize ok asset=\(asset.id.prefix(8)) type=\(asset.type.rawValue) duration=\(asset.duration)"
        )
        return true
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
           type != .image {
            videoEngine?.previewAsset(asset)
            videoEngine?.seek(to: sourcePlayheadFrame, mode: .exact)
        }
    }

    struct TextClipSpec {
        let trackIndex: Int
        let startFrame: Int
        let durationFrames: Int
        let content: String
        let style: TextStyle
        /// When nil the box is auto-fit to content and centered on the canvas.
        let transform: Transform?
        var captionGroupId: String? = nil
        /// Per-word timing (clip-relative frames) for karaoke animation; empty when unavailable.
        var words: [WordTiming]? = nil
        var animation: TextAnimation? = nil
    }

    /// Batch variant of `addTextClip` for agent flows.
    /// Caller owns undo + track creation.
    @discardableResult
    func placeTextClips(_ specs: [TextClipSpec], clearExistingRegions: Bool = true, refreshVisuals: Bool = true) -> [String] {
        guard !specs.isEmpty else { return [] }
        let canvasW = Double(timeline.width)
        let canvasH = Double(timeline.height)
        var createdIds = [String?](repeating: nil, count: specs.count)

        let indicesByTrack = Dictionary(grouping: specs.indices, by: { specs[$0].trackIndex })
        for (_, indices) in indicesByTrack {
            let ordered = indices.sorted { specs[$0].startFrame < specs[$1].startFrame }
            for i in ordered {
                let spec = specs[i]
                guard timeline.tracks.indices.contains(spec.trackIndex) else { continue }
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
                timeline.tracks[spec.trackIndex].clips.append(clip)
                createdIds[i] = clip.id
            }
        }

        for i in Set(specs.map(\.trackIndex)) where timeline.tracks.indices.contains(i) {
            sortClips(trackIndex: i)
        }
        if refreshVisuals {
            videoEngine?.refreshVisuals()
        }
        return createdIds.compactMap { $0 }
    }

    @discardableResult
    func addTextClip(content: String = "Text", style: TextStyle = TextStyle()) -> String? {
        let durationFrames = max(1, secondsToFrame(seconds: Defaults.textDurationSeconds, fps: timeline.fps))

        // Index 0 is the topmost slot in the timeline UI.
        let trackIdx = insertTrack(at: 0, type: .video)

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

        timeline.tracks[trackIdx].clips.append(clip)
        sortClips(trackIndex: trackIdx)

        undoManager?.registerUndo(withTarget: self) { vm in
            if let loc = vm.findClip(id: clipId) {
                vm.timeline.tracks[loc.trackIndex].clips.remove(at: loc.clipIndex)
                vm.videoEngine?.refreshVisuals()
            }
        }
        undoManager?.setActionName("Add Text")

        selectedClipIds = [clipId]
        videoEngine?.refreshVisuals()
        return clipId
    }
}
