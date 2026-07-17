import Foundation
#if PRODUCTION_TELEMETRY
import Sentry
#endif

enum Telemetry {
    typealias Payload = [String: Any]

    enum Level {
        case info
        case warning
        case error
        case fatal
    }

    private static let dsn = Bundle.main.object(forInfoDictionaryKey: "SentryDSN") as? String ?? ""
    private static let enabledKey = "io.palmier.pro.telemetry.enabled"

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

    nonisolated(unsafe) private static var didStart = false

    static func start() {
        #if PRODUCTION_TELEMETRY
        guard enabledForCurrentLaunch else { return }
        guard !dsn.isEmpty else { return }

        SentrySDK.start { options in
            options.dsn = dsn
            options.sendDefaultPii = false
            #if DEBUG
            options.environment = "development"
            #else
            options.environment = "production"
            #endif
            options.tracesSampleRate = 0.1
            options.appHangTimeoutInterval = 8.0
            options.attachStacktrace = true
            options.enableCaptureFailedRequests = false
            options.enableUncaughtNSExceptionReporting = true
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
               let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
                options.releaseName = "palmier-pro@\(version)+\(build)"
            }
        }
        didStart = true
        #endif
    }

    static func breadcrumb(
        _ message: String,
        category: String = "app",
        level: Level = .info,
        data: Payload? = nil
    ) {
        #if PRODUCTION_TELEMETRY
        guard didStart else { return }
        let crumb = Breadcrumb(level: level.sentryLevel, category: category)
        crumb.message = message
        crumb.data = data
        SentrySDK.addBreadcrumb(crumb)
        #endif
    }

    static func shortId(_ id: String) -> String {
        String(id.prefix(8))
    }

    static func setUser(id: String?) {
        #if PRODUCTION_TELEMETRY
        guard didStart else { return }
        SentrySDK.configureScope { scope in
            guard let id else { scope.setUser(nil); return }
            let user = User()
            user.userId = id
            scope.setUser(user)
        }
        #endif
    }

    static func setExtra(value: Any?, key: String) {
        #if PRODUCTION_TELEMETRY
        guard didStart else { return }
        SentrySDK.configureScope { scope in
            scope.setExtra(value: value, key: key)
        }
        #endif
    }

    static func logWarning(_ message: String, category: String, data: Payload? = nil) {
        breadcrumb(message, category: category, level: .warning, data: data)
    }

    static func logError(_ message: String, category: String, data: Payload? = nil) {
        captureLogMessage(message, level: .error, category: category, data: data)
    }

    static func logFault(_ message: String, category: String, data: Payload? = nil) {
        captureLogMessage(message, level: .fatal, category: category, data: data)
    }

    private static func captureLogMessage(_ message: String, level: Level, category: String, data: Payload?) {
        #if PRODUCTION_TELEMETRY
        guard didStart else { return }
        SentrySDK.capture(message: message) { scope in
            scope.setLevel(level.sentryLevel)
            scope.setTag(value: category, key: "log_category")
            if let data {
                scope.setExtra(value: data, key: "log")
            }
        }
        #endif
    }

}

#if PRODUCTION_TELEMETRY
private extension Telemetry.Level {
    var sentryLevel: SentryLevel {
        switch self {
        case .info: .info
        case .warning: .warning
        case .error: .error
        case .fatal: .fatal
        }
    }
}
#endif
