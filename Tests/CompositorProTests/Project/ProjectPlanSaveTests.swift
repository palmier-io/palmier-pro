import AppKit
import Foundation
import Testing
@testable import CompositorPro

private final class PlanSaveProject: VideoProject {
    override func write(to url: URL, ofType typeName: String) throws {
        #expect(!Thread.isMainThread)
        try super.write(to: url, ofType: typeName)
    }
}

@Suite("Project plan saves", .serialized)
@MainActor
struct ProjectPlanSaveTests {
    @Test func nativeSavePersistsCurrentPlanWithIndependentReadback() async throws {
        let root = try await Self.makeDirectory()
        do {
            let document = document(in: root)
            let plan = try #require(document.editorViewModel.editPlans.first)
            try await save(document)
            let saved = try await Self.read(#require(document.fileURL))
            #expect(saved.plans == [plan])
            try await Self.remove(root)
        } catch {
            try await Self.remove(root)
            throw error
        }
    }

    @Test func planEncodingFailureFailsSaveAndPreservesLastSuccessfulPackage() async throws {
        let root = try await Self.makeDirectory()
        do {
            let document = document(in: root)
            let package = try #require(document.fileURL)
            try await save(document)
            let original = try await Self.read(package)
            document.editorViewModel.editPlans[0].shots[0].sourceStartSeconds = .nan
            document.editorViewModel.timeline.name = "Unsaved change"
            await expectInvalidSnapshotSave(document)
            let preserved = try await Self.read(package)
            #expect(preserved.plans == original.plans)
            #expect(preserved.projectFile.timelines == original.projectFile.timelines)
            document.editorViewModel.editPlans[0].shots[0].sourceStartSeconds = nil
            try await save(document)
            let replacement = try await Self.read(package)
            #expect(replacement.projectFile.timelines.first?.name == "Unsaved change")
            try await Self.remove(root)
        } catch {
            try await Self.remove(root)
            throw error
        }
    }

    @Test func manifestEncodingFailureFailsSaveInsteadOfPreservingStaleSuccess() async throws {
        let root = try await Self.makeDirectory()
        do {
            let document = document(in: root)
            let package = try #require(document.fileURL)
            document.editorViewModel.mediaManifest.entries = [.init(id: "still", name: "Still", type: .image,
                source: .external(absolutePath: "/unused.png"), duration: 1)]
            try await save(document)
            let original = try await Self.read(package)
            document.editorViewModel.mediaManifest.entries[0].duration = .infinity
            await expectInvalidSnapshotSave(document)
            let preserved = try await Self.read(package)
            #expect(preserved.manifest == original.manifest)
            #expect(preserved.projectFile.timelines == original.projectFile.timelines)
            try await Self.remove(root)
        } catch {
            try await Self.remove(root)
            throw error
        }
    }

    private func document(in root: URL) -> VideoProject {
        let document = PlanSaveProject()
        document.fileURL = root.appendingPathComponent("Proof.palmier", isDirectory: true)
        document.fileType = VideoProject.typeIdentifier
        let timeline = document.editorViewModel.timeline
        document.editorViewModel.editPlans = [.init(id: "plan", name: "Plan", timelineId: timeline.id,
            fps: timeline.fps, width: timeline.width, height: timeline.height,
            shots: [.init(id: "scene", title: "Scene", startFrame: 0, endFrame: 30)],
            createdAt: Date(timeIntervalSince1970: 10), updatedAt: Date(timeIntervalSince1970: 10))]
        return document
    }

    private func save(_ document: VideoProject) async throws {
        let url = try #require(document.fileURL)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            document.save(to: url, ofType: VideoProject.typeIdentifier, for: .saveOperation) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func expectInvalidSnapshotSave(_ document: VideoProject) async {
        do {
            try await save(document)
            Issue.record("Invalid snapshot unexpectedly saved.")
        } catch {
            let error = error as NSError
            #expect(error.domain == NSCocoaErrorDomain)
            #expect(error.code == CocoaError.Code.coderInvalidValue.rawValue)
        }
    }

    @concurrent private static func makeDirectory() async throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PlanSave-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @concurrent private static func read(_ url: URL) async throws -> ProjectPackageContents {
        try VideoProject.readProjectPackage(at: url)
    }

    @concurrent private static func remove(_ url: URL) async throws {
        try FileManager.default.removeItem(at: url)
    }
}
