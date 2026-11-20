import Foundation
import Testing
@testable import CompositorPro

@Suite(.serialized)
struct DevSecretStoreTests {
    @Test func savedCredentialsReadBackIdentically() {
        withStore { store in
            store.save("sk-value", account: "anthropic-api-key")
            #expect(store.load(account: "anthropic-api-key") == "sk-value")
        }
    }

    @Test func accountsAreIndependent() {
        withStore { store in
            store.save("one", account: "a")
            store.save("two", account: "b")
            #expect(store.load(account: "a") == "one")
            #expect(store.load(account: "b") == "two")
        }
    }

    @Test func rewritingOneAccountLeavesTheOthersIntact() {
        withStore { store in
            store.save("keep", account: "keep")
            store.save("old", account: "changed")
            store.save("new", account: "changed")
            #expect(store.load(account: "keep") == "keep")
            #expect(store.load(account: "changed") == "new")
        }
    }

    @Test func deletingRemovesOnlyThatAccount() {
        withStore { store in
            store.save("gone", account: "gone")
            store.save("kept", account: "kept")
            store.delete(account: "gone")
            #expect(store.load(account: "gone") == nil)
            #expect(store.load(account: "kept") == "kept")
        }
    }

    @Test func anAbsentAccountReadsAsNothing() {
        withStore { store in
            #expect(store.load(account: "never-written") == nil)
        }
    }

    /// A blank value is the same as no key, so the app must not treat whitespace as configured.
    @Test func aBlankValueIsNotAStoredCredential() {
        withStore { store in
            store.save("   ", account: "blank")
            #expect(store.load(account: "blank") == nil)
        }
    }

    /// Anyone on the machine can read a world-readable credential file.
    @Test func theFileIsNotReadableByOtherUsers() throws {
        try withStore { store in
            store.save("sk-value", account: "account")
            let attributes = try #require(
                try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
            )
            let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
            #expect(permissions.int16Value & 0o077 == 0)
        }
    }

    /// A half-written file must not take the other credentials with it.
    @Test func anUnreadableFileIsTreatedAsEmpty() throws {
        try withStore { store in
            try FileManager.default.createDirectory(
                at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("{ not json".utf8).write(to: store.fileURL)
            #expect(store.load(account: "anything") == nil)
            store.save("sk-value", account: "recovered")
            #expect(store.load(account: "recovered") == "sk-value")
        }
    }

    private func withStore(_ body: (DevSecretStore) throws -> Void) rethrows {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dev-secret-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(DevSecretStore(fileURL: root.appendingPathComponent("secrets.json")))
    }
}