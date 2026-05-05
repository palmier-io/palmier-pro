import Foundation

extension EditorViewModel {

    private typealias ParentChange = (id: String, newValue: String?)

    // MARK: - Reads

    var folders: [MediaFolder] { mediaManifest.folders }

    func folder(id: String) -> MediaFolder? {
        mediaManifest.folders.first(where: { $0.id == id })
    }

    func subfolders(of parentFolderId: String?) -> [MediaFolder] {
        mediaManifest.folders
            .filter { $0.parentFolderId == parentFolderId }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func assetsIn(folderId: String?) -> [MediaAsset] {
        mediaAssets.filter { $0.folderId == folderId }
    }

    func folderPath(for folderId: String?) -> [MediaFolder] {
        MediaFolderIndex(mediaManifest.folders).path(for: folderId)
    }

    private func assetIds(inFolderIds folderIds: Set<String>) -> Set<String> {
        Set(mediaAssets
            .filter { asset in asset.folderId.map { folderIds.contains($0) } ?? false }
            .map(\.id))
    }

    private func clipIdsReferencingAssets(_ assetIds: Set<String>) -> Set<String> {
        Set(timeline.tracks
            .flatMap(\.clips)
            .filter { assetIds.contains($0.mediaRef) }
            .map(\.id))
    }

    // MARK: - Mutations

    @discardableResult
    func createFolder(name: String, in parentFolderId: String? = nil) -> String {
        let folder = MediaFolder(name: name, parentFolderId: parentFolderId)
        let id = folder.id
        mediaManifest.folders.append(folder)
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.deleteFolders(ids: [id])
        }
        undoManager?.setActionName("New Folder")
        return id
    }

    func renameFolder(id: String, name: String) {
        guard let idx = mediaManifest.folders.firstIndex(where: { $0.id == id }) else { return }
        let oldName = mediaManifest.folders[idx].name
        guard oldName != name else { return }
        mediaManifest.folders[idx].name = name
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.renameFolder(id: id, name: oldName)
        }
        undoManager?.setActionName("Rename Folder")
    }

    func deleteFolders(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let allFolderIds = MediaFolderIndex(mediaManifest.folders).idsIncludingDescendants(ids)
        guard mediaManifest.folders.contains(where: { allFolderIds.contains($0.id) }) else { return }

        let before = mediaLibraryUndoSnapshot()
        let assetIdsToDelete = assetIds(inFolderIds: allFolderIds)
        let clipIdsToRemove = clipIdsReferencingAssets(assetIdsToDelete)

        if !clipIdsToRemove.isEmpty {
            selectedClipIds.subtract(clipIdsToRemove)
            for i in timeline.tracks.indices {
                timeline.tracks[i].clips.removeAll { clipIdsToRemove.contains($0.id) }
            }
            pruneEmptyTracks()
        }

        mediaAssets.removeAll { assetIdsToDelete.contains($0.id) }
        mediaManifest.entries.removeAll { assetIdsToDelete.contains($0.id) }
        mediaManifest.folders.removeAll { allFolderIds.contains($0.id) }
        selectedFolderIds.subtract(allFolderIds)
        selectedMediaAssetIds.subtract(assetIdsToDelete)
        for id in assetIdsToDelete { closePreviewTab(id: id) }

        undoManager?.registerUndo(withTarget: self) { vm in
            vm.restoreMediaLibraryUndoSnapshot(before, actionName: "Delete Folder")
        }
        undoManager?.setActionName("Delete Folder")
        if !clipIdsToRemove.isEmpty {
            notifyTimelineChanged()
        }
    }

    func moveAssetsToFolder(assetIds: Set<String>, folderId: String?) {
        guard !assetIds.isEmpty else { return }
        var changes: [ParentChange] = []
        for id in assetIds {
            guard let asset = mediaAssets.first(where: { $0.id == id }) else { continue }
            if asset.folderId == folderId { continue }
            changes.append((id, folderId))
        }
        guard !changes.isEmpty else { return }
        applyParentChanges(
            changes, actionName: "Move to Folder",
            get: { vm, id in vm.mediaAssets.first(where: { $0.id == id })?.folderId },
            set: { vm, id, value in vm.setAssetFolderId(value, forAssetId: id) }
        )
    }

    func moveFoldersToFolder(folderIds: Set<String>, parentFolderId: String?) {
        guard !folderIds.isEmpty else { return }
        let folderIndex = MediaFolderIndex(mediaManifest.folders)
        var changes: [ParentChange] = []
        for id in folderIds {
            guard let folder = folderIndex.folder(id: id) else { continue }
            if folder.parentFolderId == parentFolderId { continue }
            if let target = parentFolderId, folderIndex.isDescendant(folderId: target, of: id) { continue }
            if id == parentFolderId { continue }
            changes.append((id, parentFolderId))
        }
        guard !changes.isEmpty else { return }
        applyParentChanges(
            changes, actionName: "Move Folder",
            get: { vm, id in vm.folder(id: id)?.parentFolderId },
            set: { vm, id, value in vm.setFolderParent(value, forFolderId: id) }
        )
    }

    // MARK: - Internal write helpers (private — keeps manifest in sync)

    private func setAssetFolderId(_ folderId: String?, forAssetId id: String) {
        if let idx = mediaAssets.firstIndex(where: { $0.id == id }) {
            mediaAssets[idx].folderId = folderId
        }
        if let idx = mediaManifest.entries.firstIndex(where: { $0.id == id }) {
            mediaManifest.entries[idx].folderId = folderId
        }
    }

    private func setFolderParent(_ parent: String?, forFolderId id: String) {
        if let idx = mediaManifest.folders.firstIndex(where: { $0.id == id }) {
            mediaManifest.folders[idx].parentFolderId = parent
        }
    }

    /// Swap-undo: snapshots priors, writes new values, undo re-invokes with inverse.
    private func applyParentChanges(
        _ changes: [ParentChange],
        actionName: String,
        get: @escaping (EditorViewModel, String) -> String?,
        set: @escaping (EditorViewModel, String, String?) -> Void
    ) {
        var inverse: [ParentChange] = []
        for change in changes {
            inverse.append((change.id, get(self, change.id)))
            set(self, change.id, change.newValue)
        }
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.applyParentChanges(inverse, actionName: actionName, get: get, set: set)
        }
        undoManager?.setActionName(actionName)
    }

    private func mediaLibraryUndoSnapshot() -> MediaLibraryUndoSnapshot {
        MediaLibraryUndoSnapshot(
            timeline: timeline,
            mediaManifest: mediaManifest,
            mediaAssets: mediaAssets,
            selectedClipIds: selectedClipIds,
            selectedMediaAssetIds: selectedMediaAssetIds,
            selectedFolderIds: selectedFolderIds,
            previewTabs: previewTabs,
            activePreviewTabId: activePreviewTabId,
            sourcePlayheadFrame: sourcePlayheadFrame
        )
    }

    private func restoreMediaLibraryUndoSnapshot(_ snapshot: MediaLibraryUndoSnapshot, actionName: String) {
        let redo = mediaLibraryUndoSnapshot()
        timeline = snapshot.timeline
        mediaManifest = snapshot.mediaManifest
        mediaAssets = snapshot.mediaAssets
        selectedClipIds = snapshot.selectedClipIds
        selectedMediaAssetIds = snapshot.selectedMediaAssetIds
        selectedFolderIds = snapshot.selectedFolderIds
        previewTabs = snapshot.previewTabs
        activePreviewTabId = snapshot.activePreviewTabId
        sourcePlayheadFrame = snapshot.sourcePlayheadFrame
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.restoreMediaLibraryUndoSnapshot(redo, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        videoEngine?.activateTab(activePreviewTab)
        notifyTimelineChanged()
    }
}

private struct MediaLibraryUndoSnapshot {
    let timeline: Timeline
    let mediaManifest: MediaManifest
    let mediaAssets: [MediaAsset]
    let selectedClipIds: Set<String>
    let selectedMediaAssetIds: Set<String>
    let selectedFolderIds: Set<String>
    let previewTabs: [PreviewTab]
    let activePreviewTabId: String
    let sourcePlayheadFrame: Int
}

// Cached lookup tables for folder path and descendant traversal.
private struct MediaFolderIndex {
    private let byId: [String: MediaFolder]
    private let childrenByParent: [String?: [MediaFolder]]

    init(_ folders: [MediaFolder]) {
        var byId: [String: MediaFolder] = [:]
        for folder in folders {
            byId[folder.id] = folder
        }

        self.byId = byId
        childrenByParent = Dictionary(grouping: folders, by: \.parentFolderId)
    }

    func folder(id: String) -> MediaFolder? {
        byId[id]
    }

    func path(for folderId: String?) -> [MediaFolder] {
        var path: [MediaFolder] = []
        var current = folderId
        var visited: Set<String> = []

        while let id = current, visited.insert(id).inserted, let folder = byId[id] {
            path.append(folder)
            current = folder.parentFolderId
        }

        return Array(path.reversed())
    }

    func isDescendant(folderId: String, of ancestorId: String) -> Bool {
        var current: String? = folderId
        var visited: Set<String> = []

        while let id = current, visited.insert(id).inserted {
            if id == ancestorId { return true }
            current = byId[id]?.parentFolderId
        }

        return false
    }

    func idsIncludingDescendants(_ ids: Set<String>) -> Set<String> {
        var all = ids
        for id in ids {
            collectDescendantIds(of: id, into: &all)
        }
        return all
    }

    private func collectDescendantIds(of folderId: String, into ids: inout Set<String>) {
        for child in childrenByParent[folderId] ?? [] where ids.insert(child.id).inserted {
            collectDescendantIds(of: child.id, into: &ids)
        }
    }
}
