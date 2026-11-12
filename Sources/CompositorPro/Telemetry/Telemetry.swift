import Foundation

/// Telemetry is local-only: events are computed but never transmitted.
/// The API surface stays stable for callers, but captures drop on the floor.
///
/// Removed with the backend teardown (R1): previously these paths
/// shipped to PostHog when PRODUCTION_TELEMETRY was enabled.
enum Telemetry {
    typealias Payload = [String: Any]

    enum Level {
        case info
        case warning
        case error
        case fatal
    }

    private static let enabledKey = "io.compositor.pro.telemetry.enabled"

    static var isEnabled: Bool {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: enabledKey) == nil { return true }
            return defaults.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }

    static let enabledForCurrentLaunch: Bool = isEnabled

    static func start() {}

    static func breadcrumb(
        _ message: String,
        category: String = "app",
        level: Level = .info,
        data: Payload? = nil
    ) {}

    static func shortId(_ id: String) -> String {
        String(id.prefix(8))
    }

    static func setUser(id: String?, email: String? = nil, username: String? = nil) {}

    static func setExtra(value: Any?, key: String) {}

    static func beginOperation(_ name: String, data: Payload = [:]) {}

    static func endOperation(_ name: String) {}

    static func logInfo(_ message: String, category: String, data: Payload? = nil) {}

    static func logWarning(_ message: String, category: String, data: Payload? = nil) {}

    static func logError(_ message: String, category: String, data: Payload? = nil) {}

    static func logFault(_ message: String, category: String, data: Payload? = nil) {}
}
