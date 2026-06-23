import Foundation
import Sentry

enum Telemetry {
    typealias Payload = [String: Any]

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
    }

    static func breadcrumb(
        _ message: String,
        category: String = "app",
        level: SentryLevel = .info,
        data: Payload? = nil
    ) {
        guard didStart else { return }
        let crumb = Breadcrumb(level: level, category: category)
        crumb.message = message
        crumb.data = data
        SentrySDK.addBreadcrumb(crumb)
    }

    static func shortId(_ id: String) -> String {
        String(id.prefix(8))
    }

    static func setUser(id: String?) {
        guard didStart else { return }
        SentrySDK.configureScope { scope in
            guard let id else { scope.setUser(nil); return }
            let user = User()
            user.userId = id
            scope.setUser(user)
        }
    }

    static func setExtra(value: Any?, key: String) {
        guard didStart else { return }
        SentrySDK.configureScope { scope in
            scope.setExtra(value: value, key: key)
        }
    }

    static func captureMessage(_ message: String, level: SentryLevel = .warning) {
        guard didStart else { return }
        SentrySDK.capture(message: message) { scope in
            scope.setLevel(level)
        }
    }

    static func captureError(_ error: Error) {
        guard didStart else { return }
        SentrySDK.capture(error: error)
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

    private static func captureLogMessage(_ message: String, level: SentryLevel, category: String, data: Payload?) {
        guard didStart else { return }
        SentrySDK.capture(message: message) { scope in
            scope.setLevel(level)
            scope.setTag(value: category, key: "log_category")
            if let data {
                scope.setExtra(value: data, key: "log")
            }
        }
    }

    static func trace<T>(name: String, operation: String = "task", _ work: () throws -> T) rethrows -> T {
        guard didStart else { return try work() }
        let txn = SentrySDK.startTransaction(name: name, operation: operation)
        do {
            let result = try work()
            txn.finish()
            return result
        } catch {
            txn.finish(status: .internalError)
            throw error
        }
    }

    static func trace<T>(name: String, operation: String = "task", _ work: () async throws -> T) async rethrows -> T {
        guard didStart else { return try await work() }
        let txn = SentrySDK.startTransaction(name: name, operation: operation)
        do {
            let result = try await work()
            txn.finish()
            return result
        } catch {
            txn.finish(status: .internalError)
            throw error
        }
    }
}
