import Darwin
import Foundation
import os

/// Categorized logger + crash handler.
///
/// Uncaught exceptions and fatal signals are written to
/// `~/Library/Logs/CompositorPro/crash.log` with a backtrace.
enum Log {
    static let subsystem  = "io.compositor.pro"
    static let app        = CategoryLog("app")
    static let editor     = CategoryLog("editor")
    static let export     = CategoryLog("export")
    static let preview    = CategoryLog("preview")
    static let mcp        = CategoryLog("mcp")
    static let agent      = CategoryLog("agent")
    static let account    = CategoryLog("account")
    static let generation = CategoryLog("generation")
    static let project    = CategoryLog("project")
    static let transcription = CategoryLog("transcription")
    static let search     = CategoryLog("search")

    static let crashLogURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/CompositorPro/crash.log")

    /// Full NSError chain
    static func detail(_ error: Error) -> String {
        let ns = error as NSError
        var message = ns.localizedDescription
        if let reason = ns.localizedFailureReason, !message.contains(reason) {
            message += " — \(reason)"
        }
        var codes: [String] = []
        var current: NSError? = ns
        while let e = current {
            codes.append("\(e.domain) \(e.code)")
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return "\(message) (\(codes.joined(separator: " → ")))"
    }

    /// Call once at launch, before `NSApplication.run()`.
    static func bootstrap() {
        DiagnosticLog.install()
        CrashHandler.install()
        DiagnosticLog.activityObserver.register { CrashHandler.refreshActivity() }
        app.notice("launch pid=\(ProcessInfo.processInfo.processIdentifier) version=\(Self.version)")
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// The in-flight work at the moment of a crash, so a signal is not the end of the report.
    static func crashContext() -> String {
        let recent = DiagnosticLog.recentActivity()
        guard !recent.isEmpty else { return "activity: (none recorded)" }
        return "activity:\n" + recent.map { "  - \($0)" }.joined(separator: "\n")
    }
}

struct CategoryLog {
    let logger: Logger
    let category: String

    init(_ category: String) {
        self.logger = Logger(subsystem: Log.subsystem, category: category)
        self.category = category
    }

    func debug(_ message: @autoclosure () -> String) {
        #if DEBUG
        let value = message()
        mirror("DEBUG", value)
        logger.debug("\(value, privacy: .public)")
        #endif
    }
    func info(_ m: String) { logger.info("\(m, privacy: .public)"); file("INFO", m) }
    func notice(_ m: String, telemetry: String? = nil, data: Telemetry.Payload? = nil) {
        mirror("NOTICE", m)
        file("NOTICE", m)
        logger.notice("\(m, privacy: .public)")
        Telemetry.logInfo(m, category: category, data: data)
        if let telemetry {
            Telemetry.breadcrumb(telemetry, category: category, data: data)
        }
    }
    func warning(_ m: String, telemetry: String? = nil, data: Telemetry.Payload? = nil) {
        mirror("WARN", m)
        file("WARN", m)
        logger.warning("\(m, privacy: .public)")
        Telemetry.logWarning(telemetry ?? m, category: category, data: data)
    }
    func error(_ m: String, telemetry: String? = nil, data: Telemetry.Payload? = nil) {
        mirror("ERROR", m)
        file("ERROR", m)
        logger.error("\(m, privacy: .public)")
        Telemetry.logError(telemetry ?? m, category: category, data: data)
    }
    func fault(_ m: String, telemetry: String? = nil, data: Telemetry.Payload? = nil) {
        mirror("FAULT", m)
        file("FAULT", m)
        logger.fault("\(m, privacy: .public)")
        Telemetry.logFault(telemetry ?? m, category: category, data: data)
    }

    /// Marks work as in flight so a crash report can name it instead of showing a bare signal.
    func activity(_ description: String) {
        DiagnosticLog.noteActivity("\(category): \(DiagnosticLog.redact(description))")
    }

    private func file(_ level: String, _ message: String) {
        DiagnosticLog.write(level: level, category: category, message: message)
    }

    private func mirror(_ level: String, _ msg: String) {
        #if DEBUG
        FileHandle.standardError.write(Data("[\(category)] \(level): \(msg)\n".utf8))
        #endif
    }
}

// MARK: - Crash handler

private enum CrashHandler {
    /// File descriptor for `crash.log`, opened once at install. `-1` if unavailable.
    nonisolated(unsafe) static var fd: Int32 = -1
    /// Pre-rendered activity block. A signal handler must not take a lock, so the text is
    /// rebuilt on the main thread whenever the activity changes and read straight from here.
    nonisolated(unsafe) static var cachedActivity: String = "activity: (none recorded)"

    static func install() {
        let url = Log.crashLogURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        refreshActivity()

        NSSetUncaughtExceptionHandler(uncaughtExceptionHandler)
        for sig in [SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig, signalHandler)
        }
    }

    static func refreshActivity() {
        cachedActivity = Log.crashContext()
    }
}

private let uncaughtExceptionHandler: @convention(c) (NSException) -> Void = { exc in
    let stack = exc.callStackSymbols.joined(separator: "\n")
    let message = """
    === \(Date()) UNCAUGHT \(exc.name.rawValue) ===
    reason: \(exc.reason ?? "(none)")
    \(Log.crashContext())
    \(stack)

    """
    if CrashHandler.fd >= 0, let data = message.data(using: .utf8) {
        data.withUnsafeBytes { _ = write(CrashHandler.fd, $0.baseAddress, $0.count) }
    }
    Logger(subsystem: Log.subsystem, category: "crash")
        .fault("\(message, privacy: .public)")
}

/// Async-signal-safe: uses only `write`, `backtrace*`, `fsync`, `raise`. The activity snapshot
/// takes a lock, which is not signal-safe, so the context is snapshotted into a plain buffer
/// whenever it changes instead of being read here.
private let signalHandler: @convention(c) (Int32) -> Void = { sig in
    let target = CrashHandler.fd >= 0 ? CrashHandler.fd : STDERR_FILENO
    let header = "\n*** FATAL SIGNAL ***\n\(CrashHandler.cachedActivity)\n"
    header.withCString { _ = write(target, $0, strlen($0)) }
    withUnsafeTemporaryAllocation(of: UnsafeMutableRawPointer?.self, capacity: 64) { frames in
        let count = backtrace(frames.baseAddress, 64)
        backtrace_symbols_fd(frames.baseAddress, count, target)
    }
    fsync(target)
    signal(sig, SIG_DFL)
    raise(sig)
}
