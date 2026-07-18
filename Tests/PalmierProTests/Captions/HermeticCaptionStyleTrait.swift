// Test trait that binds CaptionStyleStore's global/library base dirs to a fresh temp dir per test,
// so caption-style/lint tests never read or write the real ~/.config/caption-style or the shared
// media library. Per-test @TaskLocal binding keeps it hermetic under parallel test execution.

import Foundation
import Testing
@testable import PalmierPro

struct HermeticCaptionStyle: TestTrait, SuiteTrait, TestScoping {
    func provideScope(for test: Test, testCase: Test.Case?, performing function: () async throws -> Void) async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("caption-style-hermetic-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try await CaptionStyleStore.$globalDirectoryOverride.withValue(base.appendingPathComponent("global", isDirectory: true)) {
            try await CaptionStyleStore.$libraryDirectoryOverride.withValue(base.appendingPathComponent("library", isDirectory: true)) {
                try await function()
            }
        }
    }
}

extension Trait where Self == HermeticCaptionStyle {
    /// Isolate CaptionStyleStore global/library scope to a temp dir for the annotated test or suite.
    static var hermeticCaptionStyle: Self { HermeticCaptionStyle() }
}
