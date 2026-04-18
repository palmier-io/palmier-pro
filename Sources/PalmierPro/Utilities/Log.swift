import Darwin
import Foundation
import os

/// Categorized logger + crash handler.
///
/// Normal logs go to the unified log. To retrieve:
///   log show --predicate 'subsystem == "io.palmier.pro"' --info --last 1h
///
/// Uncaught exceptions and fatal signals are written to
/// `~/Library/Logs/PalmierPro/crash.log` with a backtrace.
enum Log {
    static let subsystem  = "io.palmier.pro"
    static let app        = Logger(subsystem: subsystem, category: "app")
    static let editor     = Logger(subsystem: subsystem, category: "editor")
    static let export     = Logger(subsystem: subsystem, category: "export")
    static let preview    = Logger(subsystem: subsystem, category: "preview")
    static let mcp        = Logger(subsystem: subsystem, category: "mcp")
    static let generation = Logger(subsystem: subsystem, category: "generation")
    static let project    = Logger(subsystem: subsystem, category: "project")

    static let crashLogURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/PalmierPro/crash.log")

    /// Call once at launch, before `NSApplication.run()`.
    static func bootstrap() {
        CrashHandler.install()
        app.notice("launch pid=\(ProcessInfo.processInfo.processIdentifier)")
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
