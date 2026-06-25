import Foundation

@MainActor
enum ExportCoordinator {
    private static var activeCount = 0
    private static var exclusiveExportActive = false

    static var isExportActive: Bool { activeCount > 0 || exclusiveExportActive }

    static func beginExport() {
        activeCount += 1
    }

    static func endExport() {
        activeCount = max(0, activeCount - 1)
    }

    static func beginExclusiveExportIfIdle() -> Bool {
        guard !isExportActive else { return false }
        exclusiveExportActive = true
        return true
    }

    static func endExclusiveExport() {
        exclusiveExportActive = false
    }

    static func waitWhileExportActive() async throws {
        while isExportActive {
            try await Task.sleep(for: .seconds(2))
        }
    }
}
