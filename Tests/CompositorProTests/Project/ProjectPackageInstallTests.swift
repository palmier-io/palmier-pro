import Foundation
import Testing
@testable import CompositorPro

@Suite("Project package installation")
@MainActor
struct ProjectPackageInstallTests {
    @Test func directoryHintChangeDuringInstallationDoesNotCancelSamePackage() async throws {
        try await withPackageTestFixture { fixture in
            let editor = fixture.document().editorViewModel
            let initial = URL(fileURLWithPath: fixture.package.path, isDirectory: false)
            editor.projectURL = initial
            let stage = try await fixture.stage()
            var published: URL?
            let installed = try await editor.projectPackageCoordinator.withMutation { lease in
                try await editor.commitStagedProjectMedia(stage, filename: "directory-hint.mp4", lease: lease, validate: {
                    editor.projectURL = fixture.package
                }) { published = $0 }
            }
            #expect(published == installed)
            #expect(try await fixture.contents(of: installed) == Data("MEDIA".utf8))
            let stageExists = try await fixture.exists(stage)
            #expect(!stageExists)
        }
    }

    @Test func successfulInstallationPublishesOnlyAfterStageCleanup() async throws {
        try await withPackageTestFixture { fixture in
            let editor = fixture.document().editorViewModel
            let stage = try await fixture.stage()
            var published: URL?
            let destination = try await editor.projectPackageCoordinator.withMutation { lease in
                try await editor.commitStagedProjectMedia(stage, filename: "new.mp4", lease: lease) { published = $0 }
            }
            #expect(published == destination)
            #expect(try await fixture.contents(of: destination) == Data("MEDIA".utf8))
            #expect(try await !fixture.exists(stage))
            let siblings = try await fixture.io.perform { try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) }
            #expect(!siblings.contains(where: { $0.hasPrefix(".compositor-stage-") }))
        }
    }

    @Test func staleValidationAfterInstallationRollsBackWithoutPublication() async throws {
        try await withPackageTestFixture { fixture in
            let editor = fixture.document().editorViewModel
            let stage = try await fixture.stage()
            var validations = 0
            var published = false
            await #expect(throws: CancellationError.self) {
                try await editor.projectPackageCoordinator.withMutation { lease in
                    try await editor.commitStagedProjectMedia(stage, filename: "stale.mp4", lease: lease, validate: {
                        validations += 1
                        if validations == 3 { throw CancellationError() }
                    }) { _ in published = true }
                }
            }
            #expect(validations == 3)
            #expect(!published)
            #expect(try await !fixture.exists(stage))
            #expect(try await !fixture.exists(fixture.package.appendingPathComponent("media/stale.mp4")))
            let siblings = try await fixture.io.perform { try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) }
            #expect(!siblings.contains(where: { $0.hasPrefix(".compositor-stage-") }))
        }
    }

    @Test func cancellationDuringInstallationRollsBackBeforeLeaseEnds() async throws {
        try await withPackageTestFixture { fixture in
            let editor = fixture.document().editorViewModel
            let stage = try await fixture.stage()
            var validations = 0
            var published = false
            var mutation: Task<URL, Error>?
            mutation = Task {
                try await editor.projectPackageCoordinator.withMutation { lease in
                    try await editor.commitStagedProjectMedia(stage, filename: "cancelled.mp4", lease: lease, validate: {
                        validations += 1
                        if validations == 2 { mutation?.cancel() }
                    }) { _ in published = true }
                }
            }
            let running = try #require(mutation)
            await #expect(throws: CancellationError.self) { try await running.value }
            await editor.projectPackageCoordinator.waitUntilIdle()
            #expect(!published)
            #expect(try await !fixture.exists(stage))
            #expect(try await !fixture.exists(fixture.package.appendingPathComponent("media/cancelled.mp4")))
        }
    }

    @Test func collisionPreservesExistingBytesAndRemovesOwnedStage() async throws {
        try await withPackageTestFixture { fixture in
            let editor = fixture.document().editorViewModel
            let destination = fixture.package.appendingPathComponent("media/existing.mp4")
            try await fixture.io.perform {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("ORIGINAL".utf8).write(to: destination)
            }
            let stage = try await fixture.stage()
            await #expect(throws: CocoaError.self) {
                try await editor.projectPackageCoordinator.withMutation { lease in
                    try await editor.commitStagedProjectMedia(stage, filename: "existing.mp4", lease: lease) { _ in
                        Issue.record("Collision published")
                    }
                }
            }
            #expect(try await fixture.contents(of: destination) == Data("ORIGINAL".utf8))
            #expect(try await !fixture.exists(stage))
        }
    }

    @Test(arguments: ["", ".", "..", "../escape.mp4", "nested/file.mp4", "bad\\file.mp4", "bad\0file.mp4"])
    func invalidFilenameIsRejectedWithoutPackageOutput(filename: String) async throws {
        try await withPackageTestFixture { fixture in
            let editor = fixture.document().editorViewModel
            let stage = try await fixture.stage()
            await #expect(throws: CocoaError.self) {
                try await editor.projectPackageCoordinator.withMutation { lease in
                    try await editor.commitStagedProjectMedia(stage, filename: filename, lease: lease) { _ in Issue.record("Invalid name published") }
                }
            }
            #expect(try await !fixture.exists(stage))
            #expect(try await !fixture.exists(fixture.package))
        }
    }

    @Test(arguments: [Int64(0), Int64(-1), Int64(4)])
    func invalidOrExceededSizeLimitCleansStage(limit: Int64) async throws {
        try await withPackageTestFixture { fixture in
            let editor = fixture.document().editorViewModel
            let stage = try await fixture.stage()
            await #expect(throws: (any Error).self) {
                try await editor.projectPackageCoordinator.withMutation { lease in
                    try await editor.commitStagedProjectMedia(stage, filename: "large.mp4", maxBytes: limit, lease: lease) { _ in Issue.record("Oversized media published") }
                }
            }
            #expect(try await !fixture.exists(stage))
            #expect(try await !fixture.exists(fixture.package))
        }
    }

    @Test func emptyStageIsRejectedAndRemoved() async throws {
        try await withPackageTestFixture { fixture in
            let editor = fixture.document().editorViewModel
            let stage = try await fixture.stage(Data())
            await #expect(throws: CocoaError.self) {
                try await editor.projectPackageCoordinator.withMutation { lease in
                    try await editor.commitStagedProjectMedia(stage, filename: "empty.mp4", lease: lease) { _ in Issue.record("Empty stage published") }
                }
            }
            #expect(try await !fixture.exists(stage))
        }
    }

    @Test func livePackageFileCannotBecomeTransactionOwnedStage() async throws {
        try await withPackageTestFixture { fixture in
            let editor = fixture.document().editorViewModel
            let original = fixture.package.appendingPathComponent("media/original.mp4")
            try await fixture.io.perform {
                try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("ORIGINAL".utf8).write(to: original)
            }
            await #expect(throws: CocoaError.self) {
                try await editor.projectPackageCoordinator.withMutation { lease in
                    try await editor.commitStagedProjectMedia(original, filename: "new.mp4", lease: lease) { _ in Issue.record("Live file published") }
                }
            }
            #expect(try await fixture.contents(of: original) == Data("ORIGINAL".utf8))
            #expect(try await !fixture.exists(fixture.package.appendingPathComponent("media/new.mp4")))
        }
    }

    @Test func deletingLibraryRecordRetainsInstalledBackingBytesForUndo() async throws {
        try await withPackageTestFixture { fixture in
            let editor = fixture.document().editorViewModel
            let stage = try await fixture.stage()
            let before = editor.mediaLibraryUndoSnapshot()
            var imported: MediaAsset?
            let destination = try await editor.projectPackageCoordinator.withMutation { lease in
                try await editor.commitStagedProjectMedia(stage, filename: "retained.mp4", lease: lease) { url in
                    let asset = MediaAsset(id: "retained", url: url, type: .video, name: "Retained")
                    imported = asset
                    editor.importMediaAsset(asset)
                }
            }
            let after = editor.mediaLibraryUndoSnapshot()
            editor.restoreMediaLibraryUndoSnapshot(before, actionName: "Import")
            #expect(editor.mediaAssetsById["retained"] == nil)
            #expect(try await fixture.contents(of: destination) == Data("MEDIA".utf8))
            editor.restoreMediaLibraryUndoSnapshot(after, actionName: "Import")
            #expect(editor.mediaAssetsById["retained"] === imported)
            #expect(try await fixture.contents(of: destination) == Data("MEDIA".utf8))
        }
    }

    @Test(arguments: [false, true])
    func refusedLeaseNeverDeletesLiveSource(cancelled: Bool) async throws {
        try await withPackageTestFixture { fixture in
            let editor = fixture.document().editorViewModel
            let original = fixture.package.appendingPathComponent("media/original.mp4")
            try await fixture.io.perform {
                try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("ORIGINAL".utf8).write(to: original)
            }
            let other = ProjectPackageCoordinator()
            try await other.withMutation { lease in
                let task = Task {
                    if cancelled { withUnsafeCurrentTask { $0?.cancel() } }
                    return try await editor.commitStagedProjectMedia(original, filename: "invalid.mp4", lease: lease) { _ in
                        Issue.record("Refused lease published")
                    }
                }
                await #expect(throws: (any Error).self) { try await task.value }
            }
            #expect(try await fixture.contents(of: original) == Data("ORIGINAL".utf8))
            #expect(try await !fixture.exists(fixture.package.appendingPathComponent("media/invalid.mp4")))
        }
    }

    @Test func symlinkedParentCannotTransferOwnershipOfLiveSource() async throws {
        try await withPackageTestFixture { fixture in
            let editor = fixture.document().editorViewModel
            let original = fixture.package.appendingPathComponent("media/original.mp4")
            let alias = fixture.root.appendingPathComponent("alias", isDirectory: true)
            try await fixture.io.perform {
                try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("ORIGINAL".utf8).write(to: original)
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.package)
            }
            await #expect(throws: CocoaError.self) {
                try await editor.projectPackageCoordinator.withMutation { lease in
                    try await editor.commitStagedProjectMedia(alias.appendingPathComponent("media/original.mp4"),
                        filename: "invalid.mp4", lease: lease) { _ in Issue.record("Aliased live file published") }
                }
            }
            #expect(try await fixture.contents(of: original) == Data("ORIGINAL".utf8))
        }
    }
}
