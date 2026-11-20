import Foundation

enum PluginSandboxError: LocalizedError {
    case outsideBundle
    case notExecutable
    case launchFailed(String)
    case timedOut(seconds: Double)
    case exited(code: Int32, stderr: String)
    case outputTooLarge
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .outsideBundle: "Plugin entry point resolves outside its bundle"
        case .notExecutable: "Plugin entry point is not executable"
        case .launchFailed(let message): "Plugin could not start: \(message)"
        case .timedOut(let seconds): "Plugin did not finish within \(Int(seconds)) seconds"
        case .exited(let code, let stderr):
            stderr.isEmpty ? "Plugin exited with code \(code)" : "Plugin exited with code \(code): \(stderr)"
        case .outputTooLarge: "Plugin response exceeded the size limit"
        case .invalidResponse(let message): "Plugin response is not valid: \(message)"
        }
    }
}

/// Runs one plugin tool as a separate process: JSON args on stdin, one JSON object on stdout,
/// exit 0 for success. Never loads third-party code into the app process.
enum PluginSandbox {
    static let defaultTimeout: TimeInterval = 15
    static let maximumOutputBytes = 1 << 20

    /// Returns the plugin's `result` value encoded as a compact JSON string.
    @concurrent
    static func run(
        plugin: InstalledPlugin,
        payload: Data,
        timeout: TimeInterval = defaultTimeout
    ) async throws -> String {
        let entry = plugin.entryPointURL.resolvingSymlinksInPath()
        let root = plugin.directory.resolvingSymlinksInPath()
        guard entry.path.hasPrefix(root.path + "/") else { throw PluginSandboxError.outsideBundle }
        guard FileManager.default.isExecutableFile(atPath: entry.path) else { throw PluginSandboxError.notExecutable }

        let process = Process()
        process.executableURL = entry
        process.currentDirectoryURL = root
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "TMPDIR": NSTemporaryDirectory(),
        ]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdout = ByteCollector(limit: maximumOutputBytes)
        let stderr = ByteCollector(limit: maximumOutputBytes)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in stdout.append(handle.availableData) }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in stderr.append(handle.availableData) }

        let output = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let gate = ResumeGate(continuation)
            let handle = ProcessHandle(process)
            let timeoutFlag = TimeoutFlag()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                guard timeoutFlag.beginFiring() else { return }
                gate.markTimedOut()
                handle.terminate()
            }
            process.terminationHandler = { finished in
                timeoutFlag.finish()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                // Drain anything still buffered after the handler was detached.
                stdout.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                stderr.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                let captured = stdout.value
                let errorOutput = stderr.value
                let trimmedError = String(errorOutput.prefix(4096))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if gate.isTimedOut {
                    gate.finish(throwing: PluginSandboxError.timedOut(seconds: timeout))
                } else if stdout.overflowed {
                    gate.finish(throwing: PluginSandboxError.outputTooLarge)
                } else if finished.terminationStatus != 0 {
                    gate.finish(throwing: PluginSandboxError.exited(code: finished.terminationStatus, stderr: trimmedError))
                } else {
                    gate.finish(returning: captured)
                }
            }
            do {
                try process.run()
                try stdinPipe.fileHandleForWriting.write(contentsOf: payload)
                try stdinPipe.fileHandleForWriting.close()
            } catch {
                timeoutFlag.finish()
                gate.finish(throwing: PluginSandboxError.launchFailed(error.localizedDescription))
            }
        }
        return try Self.decodeResult(output)
    }

    private static func decodeResult(_ output: String) throws -> String {
        guard let data = output.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PluginSandboxError.invalidResponse("stdout must be one JSON object")
        }
        if let error = object["error"] as? String {
            throw PluginSandboxError.invalidResponse(error)
        }
        guard let result = object["result"], JSONSerialization.isValidJSONObject(result) else {
            throw PluginSandboxError.invalidResponse("missing \"result\" value")
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
              let text = String(data: encoded, encoding: .utf8) else {
            throw PluginSandboxError.invalidResponse("result is not encodable")
        }
        return text
    }
}

private final class ProcessHandle: @unchecked Sendable {
    private let process: Process
    init(_ process: Process) { self.process = process }
    func terminate() { if process.isRunning { process.terminate() } }
}

/// Lets either the timeout or the exit path win exactly once.
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func beginFiring() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return false }
        done = true
        return true
    }

    func finish() {
        lock.lock()
        done = true
        lock.unlock()
    }
}

/// Accumulates child output under a lock, bounded so a runaway plugin cannot exhaust memory.
private final class ByteCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var didOverflow = false

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let remaining = limit - data.count
        guard remaining > 0 else {
            didOverflow = true
            return
        }
        data.append(chunk.prefix(remaining))
        if chunk.count > remaining { didOverflow = true }
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    var overflowed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didOverflow
    }
}

/// Resumes the sandbox continuation exactly once, whether it ends by exit or timeout.
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var timedOut = false
    private let continuation: CheckedContinuation<String, Error>

    init(_ continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }

    var isTimedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func finish(returning value: String) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        continuation.resume(returning: value)
    }

    func finish(throwing error: Error) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        continuation.resume(throwing: error)
    }
}
