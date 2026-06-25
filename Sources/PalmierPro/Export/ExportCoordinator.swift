import Foundation

@MainActor
enum ExportCoordinator {
    private static var exportActive = false

    static var isExportActive: Bool { exportActive }

    /// Claims the single heavy-export slot. Returns false if one is already running.
    static func beginExportIfIdle() -> Bool {
        guard !exportActive else { return false }
        exportActive = true
        return true
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
