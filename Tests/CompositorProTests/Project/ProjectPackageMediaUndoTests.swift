import AppKit
import Foundation
import Testing
@testable import CompositorPro

@Suite("Project package media undo after Save As", .serialized)
@MainActor
struct ProjectPackageMediaUndoTests {
    @Test(arguments: [false, true])
    func deletionUndoResolvesSavedSourceAfterOriginalPackageRemoval(external: Bool) async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let editor = document.editorViewModel
            let data = try await MediaInputIdentityFixtures.imageData()
            let stage = try await fixture.stage(data)
            let asset = MediaAsset(url: stage, type: .image, name: "Retained Image")
            try await editor.projectPackageCoordinator.withMutation { lease in
                if external {
                    editor.importMediaAsset(asset)
                } else {
                    _ = try await editor.commitStagedProjectMedia(stage, filename: "retained.png", lease: lease) { destination in
                        asset.url = destination
                        editor.importMediaAsset(asset)
                    }
                }
                try #require(await editor.finalizeImportedAsset(asset))
            }
            let identity = try #require(asset.inputIdentity)
            let source = try #require(editor.mediaManifest.entries.first).source
            try await savePackageTestDocument(document)
            let undo = UndoManager()
            undo.groupsByEvent = false
            editor.undo.attach(undo)
            editor.deleteMediaAssets(ids: [asset.id])
            #expect(editor.mediaAssets.isEmpty)
            #expect(undo.canUndo)
            let destination = fixture.root.appendingPathComponent("Copy.compositorpro", isDirectory: true)
            try await savePackageTestDocument(document, to: destination, operation: .saveAsOperation)
            try await fixture.io.remove([fixture.package])

            undo.undo()
            let restored = try #require(editor.mediaAssetsById[asset.id])
            let expectedURL = external ? stage : destination.appendingPathComponent("media/retained.png")
            #expect(restored === asset)
            #expect(restored.url == expectedURL)
            #expect(restored.inputIdentity == identity)
            #expect(editor.mediaManifest.entries.first?.source == source)
            #expect(try await fixture.contents(of: restored.url) == data)
            try #require(await editor.finalizeImportedAsset(restored))
            await editor.missingMediaRefreshTask?.value
            #expect(restored.sourceWidth == 2)
            #expect(restored.sourceHeight == 2)
            #expect(restored.inputIdentityVerified)
            #expect(!editor.missingMediaRefs.contains(asset.id))
            try await savePackageTestDocument(document)
            #expect(try await fixture.readPackage(at: destination).manifest?.entries.first?.source == source)

            undo.redo()
            #expect(editor.mediaAssets.isEmpty)
            #expect(try await fixture.contents(of: expectedURL) == data)
            undo.undo()
            #expect(editor.mediaAssetsById[asset.id]?.url == expectedURL)
            #expect(editor.mediaManifest.entries.first?.source == source)
            await editor.missingMediaRefreshTask?.value
        }
    }
}
