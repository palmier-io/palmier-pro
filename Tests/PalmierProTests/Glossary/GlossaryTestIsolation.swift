// Test scoping trait that redirects GlossaryStore's machine-global library/global roots to a fresh
// temp directory per test, so no glossary test ever reads or writes the real ~/Documents or ~/.config
// paths. Apply with `@Suite(.isolatedGlossaryRoot)` on any suite that loads or mutates the glossary.

import Foundation
import Testing
@testable import PalmierPro

struct IsolatedGlossaryRoot: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        // Scope individual test cases only; the suite container itself runs no body.
        guard testCase != nil else { try await function(); return }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gloss-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await GlossaryScope.$sharedRootOverride.withValue(dir) {
            try await function()
        }
    }
}

extension Trait where Self == IsolatedGlossaryRoot {
    static var isolatedGlossaryRoot: Self { Self() }
}
