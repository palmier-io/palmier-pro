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

    func debug(_ m: String) { logger.debug("\(m, privacy: .public)") }
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
        FileHandle.standardError.write(Data("[\(category)] \(level): \(msg)\n".utf8))
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

private let fatalSignalHeader: StaticString = "\n*** FATAL SIGNAL ***\n"

/// Truly async-signal-safe: only `write`, `backtrace`, `fsync`, `signal`, `raise`,
/// and stack-only formatting. Deliberately avoids `backtrace_symbols_fd`, which
/// symbolicates via `dladdr`/dyld (NOT signal-safe) — under a multi-threaded fault
/// that deadlocks the handler and masks the real crash. Addresses are written raw;
/// symbolicate offline (`atos`) or read the OS crash report. A reentrancy guard
/// keeps concurrent faulting threads from interleaving in the handler.
private nonisolated(unsafe) var crashHandlerEntered: Int32 = 0

private let signalHandler: @convention(c) (Int32) -> Void = { sig in
    // First faulting thread wins; others go straight to the default disposition.
    if !OSAtomicCompareAndSwap32(0, 1, &crashHandlerEntered) {
        signal(sig, SIG_DFL)
        raise(sig)
        return
    }
    let target = CrashHandler.fd >= 0 ? CrashHandler.fd : STDERR_FILENO
    fatalSignalHeader.withUTF8Buffer { _ = write(target, $0.baseAddress, $0.count) }
    withUnsafeTemporaryAllocation(of: UnsafeMutableRawPointer?.self, capacity: 64) { frames in
        let count = Int(backtrace(frames.baseAddress, 64))
        withUnsafeTemporaryAllocation(of: CChar.self, capacity: 19) { line in
            for i in 0..<count {
                line[0] = CChar(UInt8(ascii: "0")); line[1] = CChar(UInt8(ascii: "x"))
                var v = UInt(bitPattern: frames[i])
                var idx = 17
                while idx >= 2 {
                    let nibble = UInt8(v & 0xF)
                    line[idx] = CChar(nibble < 10 ? UInt8(ascii: "0") + nibble : UInt8(ascii: "a") + nibble - 10)
                    v >>= 4
                    idx -= 1
                }
                line[18] = CChar(UInt8(ascii: "\n"))
                _ = write(target, line.baseAddress, 19)
            }
        }
    }
    fsync(target)
    signal(sig, SIG_DFL)
    raise(sig)
}
