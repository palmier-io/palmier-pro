import Foundation
import Sentry

enum Telemetry {
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
    }

    static func breadcrumb(_ message: String, category: String = "app", level: SentryLevel = .info) {
        guard enabledForCurrentLaunch else { return }
        let crumb = Breadcrumb(level: level, category: category)
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
    }

    static func captureMessage(_ message: String, level: SentryLevel = .warning) {
        guard enabledForCurrentLaunch else { return }
        SentrySDK.capture(message: message) { scope in
            scope.setLevel(level)
        }
    }

    static func captureError(_ error: Error) {
        guard enabledForCurrentLaunch else { return }
        SentrySDK.capture(error: error)
    }

    static func logWarning(_ message: String, category: String) {
        breadcrumb(message, category: category, level: .warning)
    }

    static func logError(_ message: String, category: String) {
        captureLogMessage(message, level: .error, category: category)
    }

    static func logFault(_ message: String, category: String) {
        captureLogMessage(message, level: .fatal, category: category)
    }

    private static func captureLogMessage(_ message: String, level: SentryLevel, category: String) {
        guard enabledForCurrentLaunch else { return }
        SentrySDK.capture(message: message) { scope in
            scope.setLevel(level)
            scope.setTag(value: category, key: "log_category")
        }
    }

    static func trace<T>(name: String, operation: String = "task", _ work: () throws -> T) rethrows -> T {
        guard enabledForCurrentLaunch else { return try work() }
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
        guard enabledForCurrentLaunch else { return try await work() }
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
