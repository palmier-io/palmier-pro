import Darwin
import Foundation
import os

/// File-backed log for support and debugging.
///
/// `os.Logger` is the right tool for production telemetry, but it is close to useless for
/// answering "what happened on this machine": in a release build nothing is mirrored to a
/// file, and reading the unified log needs Console or `log collect`. This writes a small,
/// rotated, redacted text log next to the crash log so a report can be turned into evidence.
enum DiagnosticLog {
    static let directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/PalmierPro", isDirectory: true)
    static let fileURL = directory.appendingPathComponent("palmier.log")

    private static let maxBytes = 2 * 1024 * 1024
    private static let maxFiles = 3
    private static let queue = DispatchQueue(label: "io.palmier.pro.diagnostics", qos: .utility)

    /// What the app was doing, kept so a crash report can say which operation was in flight.
    private static let activity = ActivityRing(capacity: 12)

    /// Set once at launch by the crash handler, which must not read the ring from inside a
    /// signal and so needs the text pushed to it instead.
    static let activityObserver = ActivityObserver()

    static func install() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        queue.async { rotateIfNeeded() }
    }

    static func write(level: String, category: String, message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) [\(level)] \(category): \(redact(message))\n"
        guard let data = line.data(using: .utf8) else { return }
        queue.async {
            rotateIfNeeded()
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
        if level == "ERROR" || level == "FAULT" {
            noteActivity("last \(level) in \(category): \(message)")
        }
    }

    /// Records in-flight work so a crash names it. Never the payload.
    static func noteActivity(_ description: String) {
        activity.append(description)
        activityObserver.notify()
    }

    static func recentActivity() -> [String] {
        activity.snapshot()
    }

    private static func rotateIfNeeded() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? Int) ?? 0
        guard size > maxBytes else { return }
        let parent = fileURL.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: parent.appendingPathComponent("palmier.log.\(maxFiles - 1)"))
        for index in stride(from: maxFiles - 2, through: 1, by: -1) {
            let source = parent.appendingPathComponent("palmier.log.\(index)")
            let destination = parent.appendingPathComponent("palmier.log.\(index + 1)")
            try? FileManager.default.moveItem(at: source, to: destination)
        }
        try? FileManager.default.moveItem(at: fileURL, to: parent.appendingPathComponent("palmier.log.1"))
    }

    /// Keeps credentials out of a file the user is likely to paste into a bug report. Anything
    /// shaped like a key, or sitting under a credential-shaped label, is replaced.
    ///
    /// Both passes are single-shot regular expressions on purpose. An earlier loop-and-replace
    /// version never terminated: its replacement kept the very prefix being searched for, so
    /// each iteration re-found its own output forever.
    static func redact(_ message: String) -> String {
        var out = message
        let labelled = #"(?i)\b(api[-_ ]?key|authorization|bearer|token|secret|password)\b\s*[:=]\s*"?([^\s",}]{4,})"#
        let prefixed = #"(sk-or-v1-|sk-ant-|sk-|gsk_|xai-|AIza)[A-Za-z0-9_\-]{4,}"#
        for (pattern, template) in [(labelled, "$1=[redacted]"), (prefixed, "$1[redacted]")] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            out = regex.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template
            )
        }
        return out
    }
}

/// Small lock-guarded ring of recent activity descriptions.
final class ActivityRing: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    func append(_ entry: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(entry)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

/// One-shot observer the crash handler registers, so a signal handler never has to read the
/// ring itself. Registered exactly once, from `Log.bootstrap`.
final class ActivityObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (() -> Void)?

    func register(_ handler: @escaping () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
    }

    func notify() {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?()
    }
}
