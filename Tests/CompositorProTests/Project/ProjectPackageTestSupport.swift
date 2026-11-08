import AppKit
import Foundation
import Testing
@testable import CompositorPro

@MainActor
final class PackageTestSignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !signaled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        signaled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

struct PackageTestFixture: Sendable {
    let root: URL
    let io: ProjectPackageIO
    let registry: ProjectRegistry

    var package: URL { root.appendingPathComponent("Proof.palmier", isDirectory: true) }

    func stage(_ data: Data = Data("MEDIA".utf8)) async throws -> URL {
        let url = root.appendingPathComponent("stage-\(UUID().uuidString)")
        return try await io.perform {
            try data.write(to: url)
            return url
        }
    }

    func contents(of url: URL) async throws -> Data {
        try await io.perform { try Data(contentsOf: url) }
    }

    func exists(_ url: URL) async throws -> Bool {
        try await io.perform { FileManager.default.fileExists(atPath: url.path) }
    }

    func readPackage(at url: URL? = nil) async throws -> ProjectPackageContents {
        let target = url ?? package
        return try await io.perform { try VideoProject.readProjectPackage(at: target) }
    }

    @MainActor func document() -> VideoProject {
        let document = VideoProject(registry: registry)
        document.fileURL = package
        document.fileType = VideoProject.typeIdentifier
        document.editorViewModel.projectURL = package
        return document
    }
}

@MainActor
func withPackageTestFixture<T>(_ body: @MainActor (PackageTestFixture) async throws -> T) async throws -> T {
    let io = ProjectPackageIO()
    let root = try await io.perform {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PackageProof-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    let registry = ProjectRegistry(fileURL: root.appendingPathComponent("registry.json"))
    let fixture = PackageTestFixture(root: root, io: io, registry: registry)
    let value: T
    do {
        try await registry.waitUntilLoaded()
        value = try await body(fixture)
        try await registry.flush()
    } catch {
        do {
            try await Task { @MainActor in try await registry.flush() }.value
            try await io.remove([root])
        }
        catch let cleanup { throw ProjectPackageCleanupError(operationError: error, cleanupError: cleanup) }
        throw error
    }
    try await io.remove([root])
    return value
}

@MainActor
func savePackageTestDocument(
    _ document: VideoProject, to url: URL? = nil,
    operation: NSDocument.SaveOperationType = .saveOperation
) async throws {
    let target = try #require(url ?? document.fileURL)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        document.save(to: target, ofType: VideoProject.typeIdentifier, for: operation) { error in
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume() }
        }
    }
}
