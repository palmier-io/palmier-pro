import AppKit
import Foundation
import Testing
@testable import CompositorPro

@Suite("Native project Save As", .serialized)
@MainActor
struct ProjectPackageSaveAsTests {
    @Test func saveAsCopiesAdmittedMediaAndRebasesQueuedInstallation() async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let editor = document.editorViewModel
            let coordinator = editor.projectPackageCoordinator
            fixture.registry.register(fixture.package)
            try await fixture.registry.flush()
            let projectID = try #require(fixture.registry.id(for: fixture.package))
            editor.refreshProjectId()
            #expect(editor.projectRegistry === fixture.registry)
            #expect(editor.projectId == projectID.uuidString)
            let destination = fixture.root.appendingPathComponent("Copy.compositorpro", isDirectory: true)
            let before = try await fixture.stage(Data("before".utf8))
            let after = try await fixture.stage(Data("after".utf8))
            let admitted = PackageTestSignal()
            let finish = PackageTestSignal()
            let first = Task {
                try await coordinator.withMutation { lease in
                    admitted.signal()
                    await finish.wait()
                    _ = try await editor.commitStagedProjectMedia(before, filename: "before.mp4", lease: lease) { url in
                        editor.importMediaAsset(MediaAsset(id: "before", url: url, type: .video, name: "Before"))
                    }
                }
            }
            await admitted.wait()
            let saved = PackageTestSignal()
            var saveError: Error?
            document.save(to: destination, ofType: VideoProject.typeIdentifier, for: .saveAsOperation) { error in
                saveError = error
                saved.signal()
            }
            let entered = PackageTestSignal()
            let second = Task {
                entered.signal()
                return try await coordinator.withMutation { lease in
                    try await editor.commitStagedProjectMedia(after, filename: "after.mp4", lease: lease) { url in
                        editor.importMediaAsset(MediaAsset(id: "after", url: url, type: .video, name: "After"))
                    }
                }
            }
            await entered.wait()
            finish.signal()
            try await first.value
            await saved.wait()
            #expect(saveError == nil)
            #expect(document.fileURL == destination)
            #expect(editor.projectURL == destination)
            #expect(fixture.registry.id(for: destination) == projectID)
            #expect(editor.projectId == projectID.uuidString)
            let registryBytes = try await fixture.contents(of: fixture.root.appendingPathComponent("registry.json"))
            let persistedEntries = try await fixture.io.perform {
                try JSONDecoder().decode([ProjectEntry].self, from: registryBytes)
            }
            #expect(persistedEntries.first?.url == destination)
            #expect(try await second.value == destination.appendingPathComponent("media/after.mp4"))
            try await savePackageTestDocument(document)
            let copy = try await fixture.readPackage(at: destination)
            #expect(Set(copy.manifest?.entries.map(\.id) ?? []) == ["before", "after"])
            #expect(editor.mediaAssetsById["before"]?.url == destination.appendingPathComponent("media/before.mp4"))
            #expect(try await fixture.contents(of: destination.appendingPathComponent("media/before.mp4")) == Data("before".utf8))
            #expect(try await fixture.contents(of: destination.appendingPathComponent("media/after.mp4")) == Data("after".utf8))
            #expect(try await !fixture.exists(fixture.package.appendingPathComponent("media/after.mp4")))
        }
    }

    @Test func registryFailureIsReportedAfterSafeSaveAndReleasesAdmission() async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            try await savePackageTestDocument(document)
            fixture.registry.register(fixture.package)
            try await fixture.registry.flush()
            let registryURL = fixture.root.appendingPathComponent("registry.json")
            let backup = fixture.root.appendingPathComponent("registry-backup.json")
            let destination = fixture.root.appendingPathComponent("Copy.compositorpro", isDirectory: true)
            try await fixture.io.perform {
                try FileManager.default.moveItem(at: registryURL, to: backup)
                try FileManager.default.createDirectory(at: registryURL, withIntermediateDirectories: false)
            }
            await #expect(throws: ProjectRegistryPersistenceError.self) {
                try await savePackageTestDocument(document, to: destination, operation: .saveAsOperation)
            }
            #expect(document.fileURL == destination)
            #expect(try await fixture.readPackage(at: destination).projectFile.timelines.count == 1)
            try await document.editorViewModel.projectPackageCoordinator.withMutation { _ in }
            try await fixture.io.perform {
                try FileManager.default.removeItem(at: registryURL)
                try FileManager.default.moveItem(at: backup, to: registryURL)
            }
            try await fixture.registry.flush()
            #expect(fixture.registry.id(for: destination) != nil)
        }
    }
}
