import Foundation
import os

/// Signposts for the export pipeline so Instruments can attribute wall-clock time to prepare,
/// export, and commit phases. Lightweight: no allocation on the hot path.
enum ExportSignposts {
    private static let log = OSLog(subsystem: Log.subsystem, category: "export")

    enum Phase: String {
        case prepare = "prepare"
        case export = "export"
        case commit = "commit"
    }

    static func begin(_ phase: Phase) {
        os_signpost(.event, log: log, name: "phase_begin", "%{public}s", phase.rawValue)
    }

    static func end(_ phase: Phase, since started: ContinuousClock.Instant) {
        os_signpost(.event, log: log, name: "phase_end", "%{public}s", phase.rawValue)
        let elapsed = (ContinuousClock.now - started).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        Log.export.notice("export phase=\(phase.rawValue) seconds=\(seconds)")
    }
}