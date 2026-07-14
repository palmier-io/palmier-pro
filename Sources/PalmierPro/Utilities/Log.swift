import Darwin
import Foundation
import os

/// Categorized logger + crash handler.
///
/// Uncaught exceptions and fatal signals are written to
/// `~/Library/Logs/PalmierPro/crash.log` with a backtrace.
enum Log {
    static let subsystem  = "io.palmier.pro"
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
        .appendingPathComponent("Library/Logs/PalmierPro/crash.log")

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
        CrashHandler.install()
        app.notice("launch pid=\(ProcessInfo.processInfo.processIdentifier)")
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
    func info(_ m: String) { logger.info("\(m, privacy: .public)") }
    func notice(_ m: String, telemetry: String? = nil, data: Telemetry.Payload? = nil) {
        mirror("NOTICE", m)
        logger.notice("\(m, privacy: .public)")
        if let telemetry {
            Telemetry.breadcrumb(telemetry, category: category, data: data)
        }
    }
    func warning(_ m: String, telemetry: String? = nil, data: Telemetry.Payload? = nil) {
        mirror("WARN", m)
        logger.warning("\(m, privacy: .public)")
        Telemetry.logWarning(telemetry ?? m, category: category, data: data)
    }
    func error(_ m: String, telemetry: String? = nil, data: Telemetry.Payload? = nil) {
        mirror("ERROR", m)
        logger.error("\(m, privacy: .public)")
        Telemetry.logError(telemetry ?? m, category: category, data: data)
    }
    func fault(_ m: String, telemetry: String? = nil, data: Telemetry.Payload? = nil) {
        mirror("FAULT", m)
        logger.fault("\(m, privacy: .public)")
        Telemetry.logFault(telemetry ?? m, category: category, data: data)
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

    static func install() {
        let url = Log.crashLogURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)

        NSSetUncaughtExceptionHandler(uncaughtExceptionHandler)
        for sig in [SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig, signalHandler)
        }
    }
}

private let uncaughtExceptionHandler: @convention(c) (NSException) -> Void = { exc in
    let stack = exc.callStackSymbols.joined(separator: "\n")
    let message = """
    === \(Date()) UNCAUGHT \(exc.name.rawValue) ===
    reason: \(exc.reason ?? "(none)")
    \(stack)

    """
    if CrashHandler.fd >= 0, let data = message.data(using: .utf8) {
        data.withUnsafeBytes { _ = write(CrashHandler.fd, $0.baseAddress, $0.count) }
    }
    Logger(subsystem: Log.subsystem, category: "crash")
        .fault("\(message, privacy: .public)")
}

/// Async-signal-safe: uses only `write`, `backtrace*`, `fsync`, `raise`.
private let signalHandler: @convention(c) (Int32) -> Void = { sig in
    let target = CrashHandler.fd >= 0 ? CrashHandler.fd : STDERR_FILENO
    let header = "\n*** FATAL SIGNAL ***\n"
    header.withCString { _ = write(target, $0, strlen($0)) }
    withUnsafeTemporaryAllocation(of: UnsafeMutableRawPointer?.self, capacity: 64) { frames in
        let count = backtrace(frames.baseAddress, 64)
        backtrace_symbols_fd(frames.baseAddress, count, target)
    }
    fsync(target)
    signal(sig, SIG_DFL)
    raise(sig)
}
