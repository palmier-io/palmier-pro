import AppKit
import Foundation
import Testing
@testable import PalmierPro

@MainActor
private func editor() -> EditorViewModel {
    let e = EditorViewModel()
    e.timeline = Fixtures.timeline()
    return e
}

@MainActor
private func asset(name: String, folderId: String? = nil) -> MediaAsset {
    let url = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-\(name).mp4")
    let a = MediaAsset(url: url, type: .video, name: name)
    a.folderId = folderId
    return a
}

@Suite("EditorViewModel — folder reads")
@MainActor
struct FolderReadTests {

    @Test func subfoldersReturnsImmediateChildrenSortedByName() {
        let e = editor()
        let root = e.createFolder(name: "Root")
        _ = e.createFolder(name: "Beta", in: root)
        _ = e.createFolder(name: "alpha", in: root)
        _ = e.createFolder(name: "Gamma", in: root)
        // Grand-child should not appear in root's subfolders.
        let alphaId = e.subfolders(of: root).first(where: { $0.name == "alpha" })!.id
        _ = e.createFolder(name: "Nested", in: alphaId)

        let names = e.subfolders(of: root).map(\.name)
        #expect(names == ["alpha", "Beta", "Gamma"])
    }

    @Test func folderPathWalksFromRootToTarget() {
        let e = editor()
        let a = e.createFolder(name: "A")
        let b = e.createFolder(name: "B", in: a)
        let c = e.createFolder(name: "C", in: b)
        #expect(e.folderPath(for: c).map(\.name) == ["A", "B", "C"])
        #expect(e.folderPath(for: nil).isEmpty)
    }

    @Test func assetsInFiltersByFolderId() {
        let e = editor()
        let folderId = e.createFolder(name: "Clips")
        let inside = asset(name: "in", folderId: folderId)
        let outside = asset(name: "out", folderId: nil)
        e.importMediaAsset(inside)
        e.importMediaAsset(outside)

        #expect(e.assetsIn(folderId: folderId).map(\.name) == ["in"])
        #expect(e.assetsIn(folderId: nil).map(\.name) == ["out"])
    }

    @Test func importFinderItemsMirrorsFolderTree() async throws {
        let e = editor()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-import-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("Nested", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("root.mp4"))
        try Data().write(to: nested.appendingPathComponent("child.wav"))
        try Data().write(to: nested.appendingPathComponent("ignored.txt"))

        let summary = try await e.importFinderItems([root], into: nil)

        #expect(summary.assetCount == 2)
        #expect(summary.folderCount == 2)
        let rootFolder = try #require(e.folders.first { $0.name == root.lastPathComponent })
        let nestedFolder = try #require(e.folders.first { $0.name == "Nested" })
        #expect(nestedFolder.parentFolderId == rootFolder.id)
        #expect(e.assetsIn(folderId: rootFolder.id).map(\.name) == ["root"])
        #expect(e.assetsIn(folderId: nestedFolder.id).map(\.name) == ["child"])
    }

    @Test func importFinderItemsDoesNotCreateRootFolderWhenDirectoryCannotBeRead() async throws {
        let e = editor()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-import-denied-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }

        let summary = try await e.importFinderItems([root], into: nil)

        #expect(summary.assetCount == 0)
        #expect(summary.folderCount == 0)
        #expect(e.folders.isEmpty)
    }
}

@Suite("EditorViewModel — deleteFolders")
@MainActor
struct DeleteFoldersTests {

    @Test func deleteCascadesIntoDescendants() {
        let e = editor()
        let parent = e.createFolder(name: "Parent")
        let child = e.createFolder(name: "Child", in: parent)
        let grand = e.createFolder(name: "Grand", in: child)

        e.deleteFolders(ids: [parent])

        #expect(e.folder(id: parent) == nil)
        #expect(e.folder(id: child) == nil)
        #expect(e.folder(id: grand) == nil)
    }

    @Test func deleteRemovesAssetsAndReferencingClips() {
        let e = editor()
        let folder = e.createFolder(name: "Trash")
        let a = asset(name: "doomed", folderId: folder)
        e.importMediaAsset(a)
        // Place a clip on the timeline that references the asset.
        let clip = Fixtures.clip(id: "c1", mediaRef: a.id, start: 0, duration: 30)
        e.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        e.deleteFolders(ids: [folder])

        #expect(e.mediaAssets.contains(where: { $0.id == a.id }) == false)
        #expect(e.mediaManifest.entries.contains(where: { $0.id == a.id }) == false)
        // Empty track is pruned after the only clip referencing the deleted asset goes.
        #expect(e.timeline.tracks.flatMap(\.clips).contains(where: { $0.id == "c1" }) == false)
    }

    @Test func deleteSubtractsFromSelectedFolderIds() {
        let e = editor()
        let a = e.createFolder(name: "A")
        let b = e.createFolder(name: "B")
        e.selectedFolderIds = [a, b]

        e.deleteFolders(ids: [a])

        #expect(e.selectedFolderIds == [b])
    }

    @Test func deleteEmptySetIsNoOp() {
        let e = editor()
        _ = e.createFolder(name: "Keep")
        let before = e.folders.count
        e.deleteFolders(ids: [])
        #expect(e.folders.count == before)
    }
}

@Suite("EditorViewModel — moveAssetsToFolder & moveFoldersToFolder")
@MainActor
struct MoveFoldersTests {

    @Test func moveAssetsUpdatesAssetAndManifestEntry() {
        let e = editor()
        let dest = e.createFolder(name: "Dest")
        let a = asset(name: "x", folderId: nil)
        e.importMediaAsset(a)

        e.moveAssetsToFolder(assetIds: [a.id], folderId: dest)

        #expect(e.mediaAssets.first(where: { $0.id == a.id })?.folderId == dest)
        #expect(e.mediaManifest.entries.first(where: { $0.id == a.id })?.folderId == dest)
    }

    @Test func moveFoldersRejectsCycleIntoOwnDescendant() {
        let e = editor()
        let parent = e.createFolder(name: "Parent")
        let child = e.createFolder(name: "Child", in: parent)

        // Attempting to make `parent` a child of its own descendant `child` must be ignored.
        e.moveFoldersToFolder(folderIds: [parent], parentFolderId: child)

        #expect(e.folder(id: parent)?.parentFolderId == nil)
        #expect(e.folder(id: child)?.parentFolderId == parent)
    }

    @Test func moveFoldersRejectsSelfParent() {
        let e = editor()
        let f = e.createFolder(name: "Solo")
        e.moveFoldersToFolder(folderIds: [f], parentFolderId: f)
        #expect(e.folder(id: f)?.parentFolderId == nil)
    }

    @Test func moveAssetsToNilReparentsToRoot() {
        let e = editor()
        let folder = e.createFolder(name: "Box")
        let a = asset(name: "x", folderId: folder)
        e.importMediaAsset(a)

        e.moveAssetsToFolder(assetIds: [a.id], folderId: nil)

        #expect(e.mediaAssets.first(where: { $0.id == a.id })?.folderId == nil)
        #expect(e.mediaManifest.entries.first(where: { $0.id == a.id })?.folderId == nil)
    }
}

@Suite("EditorViewModel — folder edge cases")
@MainActor
struct FolderEdgeCaseTests {

    /// A cycle in `parentFolderId` shouldn't exist in practice, but if a corrupted
    /// manifest produces one, folderPath must terminate rather than spin forever.
    @Test func folderPathTerminatesOnCycle() {
        let e = editor()
        let a = MediaFolder(id: "A", name: "A", parentFolderId: "B")
        let b = MediaFolder(id: "B", name: "B", parentFolderId: "A")
        e.mediaManifest.folders = [a, b]

        let path = e.folderPath(for: "A")
        // Both folders appear exactly once, in some valid order.
        #expect(Set(path.map(\.id)) == ["A", "B"])
        #expect(path.count == 2)
    }

    /// Passing both an ancestor and one of its descendants should delete the
    /// whole subtree exactly once (the descendant is also reachable via cascade).
    @Test func deleteHandlesOverlappingAncestorAndDescendant() {
        let e = editor()
        let parent = e.createFolder(name: "Parent")
        let child = e.createFolder(name: "Child", in: parent)
        let other = e.createFolder(name: "Other")

        e.deleteFolders(ids: [parent, child])

        #expect(e.folder(id: parent) == nil)
        #expect(e.folder(id: child) == nil)
        #expect(e.folder(id: other) != nil)
    }

    @Test func deleteSubtractsFromSelectedMediaAssetIds() {
        let e = editor()
        let folder = e.createFolder(name: "Doomed")
        let inside = asset(name: "in", folderId: folder)
        let outside = asset(name: "out", folderId: nil)
        e.importMediaAsset(inside)
        e.importMediaAsset(outside)
        e.selectedMediaAssetIds = [inside.id, outside.id]

        e.deleteFolders(ids: [folder])

        #expect(e.selectedMediaAssetIds == [outside.id])
    }

    @Test func renameFolderIgnoresUnknownId() {
        let e = editor()
        let real = e.createFolder(name: "Real")
        let before = e.folders.count

        e.renameFolder(id: "not-a-real-id", name: "Whatever")

        #expect(e.folders.count == before)
        #expect(e.folder(id: real)?.name == "Real")
    }
}

// MARK: - Drag payload contract

/// Locks in the `palmier-asset://` / `palmier-folder://` sentinel schemes that
/// keep in-panel drags distinguishable from Finder file URLs. The 35586d4 fix
/// switched the asset payload from a raw file:// URL to this scheme — if it
/// reverts, the file-URL conformance check in handleProviderDrop would
/// re-route in-panel asset drags as Finder drops (duplicate imports).
@Suite("MediaTab — drag payload contract")
@MainActor
struct DragPayloadContractTests {

    @Test func assetStringRoundTrips() {
        let id = "asset-123"
        let line = MediaTab.assetDragString(forAssetId: id)
        #expect(MediaTab.assetId(fromDragString: line) == id)
    }

    @Test func folderStringRoundTrips() {
        let id = "folder-abc"
        let line = MediaTab.folderDragString(forFolderId: id)
        #expect(MediaTab.folderId(fromDragString: line) == id)
    }

    @Test func sentinelsDoNotCrossDecode() {
        let assetLine = MediaTab.assetDragString(forAssetId: "x")
        let folderLine = MediaTab.folderDragString(forFolderId: "y")
        #expect(MediaTab.folderId(fromDragString: assetLine) == nil)
        #expect(MediaTab.assetId(fromDragString: folderLine) == nil)
    }

    @Test func fileURLDoesNotDecodeAsAssetOrFolder() {
        let line = "file:///tmp/foo.mp4"
        #expect(MediaTab.assetId(fromDragString: line) == nil)
        #expect(MediaTab.folderId(fromDragString: line) == nil)
    }
}

// MARK: - resolveTextDrop routing

@Suite("MediaTab — resolveTextDrop")
@MainActor
struct ResolveTextDropTests {

    @Test func routesSingleAssetIntoDestinationFolder() {
        let e = editor()
        let dest = e.createFolder(name: "Dest")
        let a = asset(name: "x", folderId: nil)
        e.importMediaAsset(a)
        let payload = MediaTab.assetDragString(forAssetId: a.id)

        MediaTab.resolveTextDrop(payload, into: dest, editor: e)

        #expect(e.mediaAssets.first(where: { $0.id == a.id })?.folderId == dest)
    }

    @Test func routesSingleFolderUnderDestinationParent() {
        let e = editor()
        let parent = e.createFolder(name: "Parent")
        let child = e.createFolder(name: "Child")
        let payload = MediaTab.folderDragString(forFolderId: child)

        MediaTab.resolveTextDrop(payload, into: parent, editor: e)

        #expect(e.folder(id: child)?.parentFolderId == parent)
    }

    @Test func multiLinePayloadRoutesAssetsAndFoldersTogether() {
        let e = editor()
        let dest = e.createFolder(name: "Dest")
        let movableFolder = e.createFolder(name: "Movable")
        let a1 = asset(name: "a1", folderId: nil)
        let a2 = asset(name: "a2", folderId: nil)
        e.importMediaAsset(a1)
        e.importMediaAsset(a2)
        let payload = [
            MediaTab.assetDragString(forAssetId: a1.id),
            MediaTab.folderDragString(forFolderId: movableFolder),
            MediaTab.assetDragString(forAssetId: a2.id),
        ].joined(separator: "\n")

        MediaTab.resolveTextDrop(payload, into: dest, editor: e)

        #expect(e.mediaAssets.first(where: { $0.id == a1.id })?.folderId == dest)
        #expect(e.mediaAssets.first(where: { $0.id == a2.id })?.folderId == dest)
        #expect(e.folder(id: movableFolder)?.parentFolderId == dest)
    }

    @Test func nilDestinationReparentsToRoot() {
        let e = editor()
        let folder = e.createFolder(name: "Box")
        let a = asset(name: "x", folderId: folder)
        e.importMediaAsset(a)
        let payload = MediaTab.assetDragString(forAssetId: a.id)

        MediaTab.resolveTextDrop(payload, into: nil, editor: e)

        #expect(e.mediaAssets.first(where: { $0.id == a.id })?.folderId == nil)
    }

    @Test func unknownAssetIdIsIgnored() {
        let e = editor()
        let dest = e.createFolder(name: "Dest")
        let payload = MediaTab.assetDragString(forAssetId: "ghost-asset")

        MediaTab.resolveTextDrop(payload, into: dest, editor: e)

        // No phantom asset row should be inserted.
        #expect(e.mediaAssets.isEmpty)
    }

    @Test func unrecognizedLinesAreIgnored() {
        let e = editor()
        let dest = e.createFolder(name: "Dest")
        let a = asset(name: "x", folderId: nil)
        e.importMediaAsset(a)
        let payload = [
            "file:///tmp/garbage.mp4",
            "",
            "random nonsense",
            MediaTab.assetDragString(forAssetId: a.id),
        ].joined(separator: "\n")

        MediaTab.resolveTextDrop(payload, into: dest, editor: e)

        // The one valid line routed; the rest were skipped without side effects.
        #expect(e.mediaAssets.first(where: { $0.id == a.id })?.folderId == dest)
    }

    @Test func cycleIntoOwnDescendantIsRejected() {
        let e = editor()
        let parent = e.createFolder(name: "Parent")
        let child = e.createFolder(name: "Child", in: parent)
        // Try to make parent a child of its own descendant.
        let payload = MediaTab.folderDragString(forFolderId: parent)

        MediaTab.resolveTextDrop(payload, into: child, editor: e)

        #expect(e.folder(id: parent)?.parentFolderId == nil)
    }

    @Test func emptyPayloadIsNoOp() {
        let e = editor()
        let dest = e.createFolder(name: "Dest")
        let a = asset(name: "x", folderId: nil)
        e.importMediaAsset(a)

        MediaTab.resolveTextDrop("", into: dest, editor: e)

        #expect(e.mediaAssets.first(where: { $0.id == a.id })?.folderId == nil)
    }
}

// MARK: - moveMediaSelection (keyboard navigation)

/// Arrow-key navigation in the media panel. The model logic in
/// `moveMediaSelection(direction:)` is driven by an `NSEvent` handler in
/// `EditorWindowController`, so the wiring isn't unit-testable — but the
/// step / clamp / selection-routing logic is.
@Suite("EditorViewModel — moveMediaSelection")
@MainActor
struct MoveMediaSelectionTests {

    /// Helper: seed an ordered grid of `count` assets with the given column
    /// width. Returns the asset ids in grid order.
    @discardableResult
    private func seedAssetGrid(_ e: EditorViewModel, count: Int, columns: Int) -> [String] {
        var ids: [String] = []
        for i in 0..<count {
            let a = asset(name: "a\(i)", folderId: nil)
            e.importMediaAsset(a)
            ids.append(a.id)
        }
        e.mediaPanelOrderedItemIds = ids
        e.mediaPanelColumnCount = columns
        return ids
    }

    @Test func emptyOrderedListIsNoOp() {
        let e = editor()
        e.mediaPanelOrderedItemIds = []

        e.moveMediaSelection(direction: .right)

        #expect(e.selectedMediaAssetIds.isEmpty)
        #expect(e.selectedFolderIds.isEmpty)
        #expect(e.mediaPanelScrollTarget == nil)
    }

    @Test func noSelectionRightSelectsFirstItem() {
        let e = editor()
        let ids = seedAssetGrid(e, count: 4, columns: 4)

        e.moveMediaSelection(direction: .right)

        #expect(e.selectedMediaAssetIds == [ids[0]])
        #expect(e.mediaPanelScrollTarget == ids[0])
    }

    @Test func noSelectionLeftSelectsLastItem() {
        let e = editor()
        let ids = seedAssetGrid(e, count: 4, columns: 4)

        e.moveMediaSelection(direction: .left)

        #expect(e.selectedMediaAssetIds == [ids[3]])
        #expect(e.mediaPanelScrollTarget == ids[3])
    }

    @Test func noSelectionUpSelectsLastItem() {
        let e = editor()
        let ids = seedAssetGrid(e, count: 4, columns: 4)

        e.moveMediaSelection(direction: .up)

        #expect(e.selectedMediaAssetIds == [ids[3]])
    }

    @Test func rightAdvancesToNextItem() {
        let e = editor()
        let ids = seedAssetGrid(e, count: 4, columns: 4)
        e.selectedMediaAssetIds = [ids[1]]

        e.moveMediaSelection(direction: .right)

        #expect(e.selectedMediaAssetIds == [ids[2]])
    }

    @Test func rightAtEndClampsAndDoesNothing() {
        let e = editor()
        let ids = seedAssetGrid(e, count: 4, columns: 4)
        e.selectedMediaAssetIds = [ids[3]]
        e.mediaPanelScrollTarget = nil

        e.moveMediaSelection(direction: .right)

        // Selection unchanged. No scroll target set (early-return on same idx).
        #expect(e.selectedMediaAssetIds == [ids[3]])
        #expect(e.mediaPanelScrollTarget == nil)
    }

    @Test func leftAtStartClampsAndDoesNothing() {
        let e = editor()
        let ids = seedAssetGrid(e, count: 4, columns: 4)
        e.selectedMediaAssetIds = [ids[0]]
        e.mediaPanelScrollTarget = nil

        e.moveMediaSelection(direction: .left)

        #expect(e.selectedMediaAssetIds == [ids[0]])
        #expect(e.mediaPanelScrollTarget == nil)
    }

    @Test func downJumpsByColumnCount() {
        let e = editor()
        // 2 rows of 3: [0 1 2 / 3 4 5]. Down from idx 1 → idx 4.
        let ids = seedAssetGrid(e, count: 6, columns: 3)
        e.selectedMediaAssetIds = [ids[1]]

        e.moveMediaSelection(direction: .down)

        #expect(e.selectedMediaAssetIds == [ids[4]])
    }

    @Test func downAtPartialBottomRowClampsToLast() {
        let e = editor()
        // 5 items in 3-wide grid: [0 1 2 / 3 4]. Down from idx 2 → would be 5,
        // but list ends at 4, so clamp to last.
        let ids = seedAssetGrid(e, count: 5, columns: 3)
        e.selectedMediaAssetIds = [ids[2]]

        e.moveMediaSelection(direction: .down)

        #expect(e.selectedMediaAssetIds == [ids[4]])
    }

    @Test func navigatingOntoFolderClearsAssetSelection() {
        let e = editor()
        let folderId = e.createFolder(name: "F")
        let a = asset(name: "x", folderId: nil)
        e.importMediaAsset(a)
        // Ordered: [folder, asset]. Start on the asset, go left → land on folder.
        e.mediaPanelOrderedItemIds = [MediaPanelItemKey.folder(folderId), a.id]
        e.mediaPanelColumnCount = 2
        e.selectedMediaAssetIds = [a.id]

        e.moveMediaSelection(direction: .left)

        #expect(e.selectedFolderIds == [folderId])
        #expect(e.selectedMediaAssetIds.isEmpty)
    }

    @Test func navigatingOntoAssetClearsFolderSelection() {
        let e = editor()
        let folderId = e.createFolder(name: "F")
        let a = asset(name: "x", folderId: nil)
        e.importMediaAsset(a)
        e.mediaPanelOrderedItemIds = [MediaPanelItemKey.folder(folderId), a.id]
        e.mediaPanelColumnCount = 2
        e.selectedFolderIds = [folderId]

        e.moveMediaSelection(direction: .right)

        #expect(e.selectedMediaAssetIds == [a.id])
        #expect(e.selectedFolderIds.isEmpty)
    }

    @Test func ghostSelectionDoesNotAnchorNavigation() {
        let e = editor()
        let ids = seedAssetGrid(e, count: 4, columns: 4)
        // A selection id that isn't in the ordered list (e.g., a stale selection
        // from a previous filter) shouldn't anchor navigation — fall back to
        // the no-selection branch.
        e.selectedMediaAssetIds = ["ghost-id"]

        e.moveMediaSelection(direction: .right)

        #expect(e.selectedMediaAssetIds == [ids[0]])
    }
}

// MARK: - handlePanelFinderDrop

@Suite("MediaTab — handlePanelFinderDrop")
@MainActor
struct HandlePanelFinderDropTests {

    @Test func addsAssetAtRootWhenDestinationIsNil() async {
        let e = editor()
        let url = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-clip.mp4")

        await MediaTab.handlePanelFinderDrop(urls: [url], into: nil, editor: e)

        #expect(e.mediaAssets.count == 1)
        #expect(e.mediaAssets.first?.folderId == nil)
    }

    @Test func addsAssetAndMovesIntoDestinationFolder() async {
        let e = editor()
        let dest = e.createFolder(name: "Dest")
        let url = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-clip.mp4")

        await MediaTab.handlePanelFinderDrop(urls: [url], into: dest, editor: e)

        #expect(e.mediaAssets.count == 1)
        #expect(e.mediaAssets.first?.folderId == dest)
    }

    @Test func skipsUnsupportedFileExtensions() async {
        let e = editor()
        let url = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-readme.txt")

        await MediaTab.handlePanelFinderDrop(urls: [url], into: nil, editor: e)

        #expect(e.mediaAssets.isEmpty)
    }

    @Test func addsMultipleAssetsIntoDestination() async {
        let e = editor()
        let dest = e.createFolder(name: "Dest")
        let urls = (0..<3).map { _ in
            URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-clip.mp4")
        }

        await MediaTab.handlePanelFinderDrop(urls: urls, into: dest, editor: e)

        #expect(e.mediaAssets.count == 3)
        #expect(e.mediaAssets.allSatisfy { $0.folderId == dest })
    }
}

// MARK: - clipboardHasImportableMedia

/// Drives Edit > Paste menu validation. Uses a unique pasteboard per test so
/// parallel tests don't collide on `NSPasteboard.general`.
@Suite("MediaTab — clipboardHasImportableMedia")
@MainActor
struct ClipboardProbeTests {

    private func freshPasteboard() -> NSPasteboard {
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        return pb
    }

    @Test func emptyPasteboardIsFalse() {
        let pb = freshPasteboard()
        #expect(MediaTab.clipboardHasImportableMedia(pasteboard: pb) == false)
    }

    @Test func textOnlyIsFalse() {
        let pb = freshPasteboard()
        pb.setString("hello", forType: .string)
        #expect(MediaTab.clipboardHasImportableMedia(pasteboard: pb) == false)
    }

    @Test func pngIsTrue() {
        let pb = freshPasteboard()
        pb.setData(Data([0]), forType: .png)
        #expect(MediaTab.clipboardHasImportableMedia(pasteboard: pb))
    }

    @Test func tiffIsTrue() {
        let pb = freshPasteboard()
        pb.setData(Data([0]), forType: .tiff)
        #expect(MediaTab.clipboardHasImportableMedia(pasteboard: pb))
    }

    @Test func fileURLIsTrue() {
        let pb = freshPasteboard()
        pb.writeObjects([URL(fileURLWithPath: "/tmp/x.mp4") as NSURL])
        #expect(MediaTab.clipboardHasImportableMedia(pasteboard: pb))
    }
}

// MARK: - handleClipboardPaste

@Suite("MediaTab — handleClipboardPaste")
@MainActor
struct HandleClipboardPasteTests {

    private func freshPasteboard() -> NSPasteboard {
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        return pb
    }

    @Test func pngBytesImportAtRootWhenDestinationIsNil() async {
        let e = editor()
        let pb = freshPasteboard()
        pb.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)

        await MediaTab.handleClipboardPaste(pasteboard: pb, into: nil, editor: e)

        #expect(e.mediaAssets.count == 1)
        #expect(e.mediaAssets.first?.type == .image)
        #expect(e.mediaAssets.first?.url.pathExtension == "png")
        #expect(e.mediaAssets.first?.folderId == nil)
    }

    @Test func pngBytesLandInDestinationFolder() async {
        let e = editor()
        let dest = e.createFolder(name: "Dest")
        let pb = freshPasteboard()
        pb.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)

        await MediaTab.handleClipboardPaste(pasteboard: pb, into: dest, editor: e)

        #expect(e.mediaAssets.first?.folderId == dest)
        #expect(e.mediaManifest.entries.first?.folderId == dest)
    }

    @Test func tiffBytesImportWithTiffExtension() async {
        let e = editor()
        let pb = freshPasteboard()
        pb.setData(Data([0x4D, 0x4D, 0x00, 0x2A]), forType: .tiff)

        await MediaTab.handleClipboardPaste(pasteboard: pb, into: nil, editor: e)

        #expect(e.mediaAssets.count == 1)
        #expect(e.mediaAssets.first?.url.pathExtension == "tiff")
    }

    @Test func fileURLRoutesThroughFinderDrop() async {
        let e = editor()
        let url = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-clip.mp4")
        let pb = freshPasteboard()
        pb.writeObjects([url as NSURL])

        await MediaTab.handleClipboardPaste(pasteboard: pb, into: nil, editor: e)

        #expect(e.mediaAssets.count == 1)
        #expect(e.mediaAssets.first?.type == .video)
    }

    @Test func fileURLLandsInDestinationFolder() async {
        let e = editor()
        let dest = e.createFolder(name: "Dest")
        let url = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-clip.mp4")
        let pb = freshPasteboard()
        pb.writeObjects([url as NSURL])

        await MediaTab.handleClipboardPaste(pasteboard: pb, into: dest, editor: e)

        #expect(e.mediaAssets.first?.folderId == dest)
    }

    /// When both a file URL and raw image bytes are on the pasteboard (Finder
    /// items always carry a TIFF preview alongside the file URL), the URL wins —
    /// avoids creating both the file-imported asset and a duplicate "pasted-*"
    /// image asset for the same payload.
    @Test func fileURLTakesPrecedenceOverImageData() async {
        let e = editor()
        let url = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-clip.mp4")
        let pb = freshPasteboard()
        pb.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        pb.writeObjects([url as NSURL])

        await MediaTab.handleClipboardPaste(pasteboard: pb, into: nil, editor: e)

        #expect(e.mediaAssets.count == 1)
        #expect(e.mediaAssets.first?.type == .video)
    }

    @Test func emptyPasteboardIsNoOp() async {
        let e = editor()
        let pb = freshPasteboard()

        await MediaTab.handleClipboardPaste(pasteboard: pb, into: nil, editor: e)

        #expect(e.mediaAssets.isEmpty)
    }

    @Test func textOnlyPasteboardIsNoOp() async {
        let e = editor()
        let pb = freshPasteboard()
        pb.setString("just some text", forType: .string)

        await MediaTab.handleClipboardPaste(pasteboard: pb, into: nil, editor: e)

        #expect(e.mediaAssets.isEmpty)
    }

    @Test func fileURLWithUnsupportedExtensionIsNoOp() async {
        let e = editor()
        let pb = freshPasteboard()
        pb.writeObjects([URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-readme.txt") as NSURL])

        await MediaTab.handleClipboardPaste(pasteboard: pb, into: nil, editor: e)

        #expect(e.mediaAssets.isEmpty)
    }
}
