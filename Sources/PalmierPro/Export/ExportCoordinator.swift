import Foundation

@MainActor
enum ExportCoordinator {
    private static var exportActive = false

    static var isExportActive: Bool { exportActive }

    static func beginExportIfIdle() -> Bool {
        guard !exportActive else { return false }
        exportActive = true
        return true
    }

    static func acquireExport() async {
        while exportActive {
            try? await Task.sleep(for: .milliseconds(50))
        }
        exportActive = true
    }

    static func endExport() {
        exportActive = false
    }

    static func waitWhileExportActive() async throws {
        while exportActive {
            try await Task.sleep(for: .seconds(2))
        }
    }
}
