import Foundation
import Testing
@testable import CompositorPro

@Suite("Project package reservation")
@MainActor
struct ProjectPackageReservationTests {
    @Test func reservationCreatesNewPackageWithoutReplacingExistingBytes() async throws {
        try await withPackageTestFixture { fixture in
            try await fixture.io.reservePackage(at: fixture.package)
            let marker = fixture.package.appendingPathComponent("keep")
            try await fixture.io.perform { try Data("original".utf8).write(to: marker) }
            await #expect(throws: ProjectError.self) { try await fixture.io.reservePackage(at: fixture.package) }
            #expect(try await fixture.contents(of: marker) == Data("original".utf8))
            let siblings = try await fixture.io.perform {
                try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
            }
            #expect(siblings == ["Proof.compositorpro"])
        }
    }

    @Test func existingNonPackageFileIsNeverRemoved() async throws {
        try await withPackageTestFixture { fixture in
            let original = Data("not a package".utf8)
            try await fixture.io.perform { try original.write(to: fixture.package) }
            await #expect(throws: ProjectError.self) { try await fixture.io.reservePackage(at: fixture.package) }
            #expect(try await fixture.contents(of: fixture.package) == original)
        }
    }

    @Test func concurrentReservationsAdmitExactlyOneOwner() async throws {
        try await withPackageTestFixture { fixture in
            let second = ProjectPackageIO()
            async let first: Result<Void, Error> = reserve(fixture.io, at: fixture.package)
            async let other: Result<Void, Error> = reserve(second, at: fixture.package)
            let results = await [first, other]
            #expect(results.filter { if case .success = $0 { true } else { false } }.count == 1)
            #expect(results.filter { if case .failure(let error) = $0 { error is ProjectError } else { false } }.count == 1)
        }
    }

    @Test(arguments: ["file", "directory", "symlink"])
    func exclusiveInstallPreservesExistingDestination(kind: String) async throws {
        try await withPackageTestFixture { fixture in
            let destination = fixture.root.appendingPathComponent("occupied")
            let stage = try await fixture.stage(Data("replacement".utf8))
            let original = Data("original".utf8)
            let target = try await fixture.stage(original)
            try await fixture.io.perform {
                switch kind {
                case "file": try original.write(to: destination)
                case "directory": try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                default: try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
                }
            }

            await #expect(throws: CocoaError.self) { try await fixture.io.install(stage, to: destination) }

            #expect(try await fixture.contents(of: stage) == Data("replacement".utf8))
            #expect(try await fixture.contents(of: target) == original)
            if kind == "directory" {
                let children = try await fixture.io.perform { try FileManager.default.contentsOfDirectory(atPath: destination.path) }
                #expect(children.isEmpty)
            } else {
                #expect(try await fixture.contents(of: destination) == original)
                if kind == "symlink" {
                    let link = try await fixture.io.perform { try FileManager.default.destinationOfSymbolicLink(atPath: destination.path) }
                    #expect(link == target.path)
                }
            }
        }
    }

    @Test func concurrentInstallsAdmitExactlyOneOwnerAndRetainLosingStage() async throws {
        try await withPackageTestFixture { fixture in
            let second = ProjectPackageIO()
            let firstData = Data("first".utf8)
            let secondData = Data("second".utf8)
            let first = try await fixture.stage(firstData)
            let other = try await fixture.stage(secondData)
            let destination = fixture.root.appendingPathComponent("winner")
            async let firstResult = install(fixture.io, first, to: destination)
            async let otherResult = install(second, other, to: destination)
            let results = await [firstResult, otherResult]
            #expect(results.filter { if case .success = $0 { true } else { false } }.count == 1)
            #expect(results.filter { if case .failure(let error) = $0 { (error as? CocoaError)?.code == .fileWriteFileExists } else { false } }.count == 1)
            let firstExists = try await fixture.exists(first)
            let otherExists = try await fixture.exists(other)
            #expect(firstExists != otherExists)
            let installed = try await fixture.contents(of: destination)
            #expect(installed == (firstExists ? secondData : firstData))
            #expect(try await fixture.contents(of: firstExists ? first : other) == (firstExists ? firstData : secondData))
        }
    }

    private func install(_ io: ProjectPackageIO, _ source: URL, to destination: URL) async -> Result<Void, Error> {
        do { try await io.install(source, to: destination); return .success(()) }
        catch { return .failure(error) }
    }

    private func reserve(_ io: ProjectPackageIO, at url: URL) async -> Result<Void, Error> {
        do { try await io.reservePackage(at: url); return .success(()) }
        catch { return .failure(error) }
    }
}
