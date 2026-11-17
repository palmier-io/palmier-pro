import Darwin
import Dispatch
import Foundation
import Synchronization

struct LocalAgentProcessResult: Sendable {
    let status: Int32
    let diagnostics: String
}

private struct LocalAgentPipe: Sendable {
    let channel: DispatchIO
    let chunks: AsyncThrowingStream<Data, Error>

    init(_ handle: FileHandle) {
        let queue = DispatchQueue(label: "compositor.local-agent.pipe", qos: .utility)
        let (chunks, continuation) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        let channel = DispatchIO(type: .stream, fileDescriptor: handle.fileDescriptor, queue: queue) { _ in }
        self.channel = channel
        self.chunks = chunks
        channel.setLimit(lowWater: 1)
        channel.setLimit(highWater: 65_536)
        channel.read(offset: 0, length: Int.max, queue: queue) { done, data, error in
            if error != 0 {
                continuation.finish(throwing: error == ECANCELED ? CancellationError() : LocalAgentFailure.invalidOutput)
                return
            }
            if let data, !data.isEmpty, case .dropped = continuation.yield(Data(data)) {
                continuation.finish(throwing: LocalAgentFailure.outputLimit)
                channel.close(flags: .stop)
                return
            }
            if done { continuation.finish() }
        }
    }
}

private final class LocalAgentProcessLifetime<TimeoutClock: Clock>: Sendable where TimeoutClock.Duration == Duration {
    private struct State {
        var process: Process?
        var channels: [DispatchIO] = []
        var cancelled = false
        var timedOut = false
        var exitStatus: Int32?
        var exitWaiter: CheckedContinuation<Int32, Never>?
        var lastActivity: TimeoutClock.Instant
    }
    private let state: Mutex<State>
    private let clock: TimeoutClock

    init(clock: TimeoutClock) {
        self.clock = clock
        state = Mutex(State(lastActivity: clock.now))
    }

    func install(_ process: Process, channels: [DispatchIO]) throws {
        try state.withLock {
            guard !$0.cancelled else { throw CancellationError() }
            $0.process = process
            $0.channels = channels
        }
    }

    func didLaunch() {
        recordActivity()
        if state.withLock({ $0.cancelled }) { stop() }
    }

    func cancel() {
        state.withLock { $0.cancelled = true }
        stop()
    }

    var didTimeOut: Bool { state.withLock { $0.timedOut } }

    func recordActivity() {
        state.withLock {
            guard !$0.cancelled, $0.exitStatus == nil else { return }
            $0.lastActivity = clock.now
        }
    }

    func inactivityDeadline(after timeout: Duration) -> TimeoutClock.Instant? {
        var expired = false
        let deadline = state.withLock { state -> TimeoutClock.Instant? in
            guard !state.cancelled, state.exitStatus == nil else { return nil }
            let deadline = state.lastActivity.advanced(by: timeout)
            guard clock.now < deadline else {
                state.cancelled = true
                state.timedOut = true
                expired = true
                return nil
            }
            return deadline
        }
        if expired { stop() }
        return deadline
    }

    func didExit(status: Int32) {
        let waiter = state.withLock { state -> CheckedContinuation<Int32, Never>? in
            guard state.exitStatus == nil else { return nil }
            state.exitStatus = status
            state.process = nil
            let waiter = state.exitWaiter
            state.exitWaiter = nil
            return waiter
        }
        waiter?.resume(returning: status)
    }

    func waitForExit() async -> Int32 {
        // Cancellation must drain the process before its request workspace is removed.
        await withCheckedContinuation { continuation in
            let status = state.withLock { state -> Int32? in
                if let status = state.exitStatus { return status }
                state.exitWaiter = continuation
                return nil
            }
            if let status { continuation.resume(returning: status) }
        }
    }

    private func stop() {
        let resources = state.withLock { ($0.process, $0.channels) }
        DispatchQueue.global(qos: .utility).async {
            resources.1.forEach { $0.close(flags: .stop) }
            guard let process = resources.0, process.isRunning else { return }
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
}

enum LocalAgentProcess {
    private enum Completion: Sendable {
        case input
        case output
        case diagnostics(String)
        case exit(Int32)
    }

    @concurrent
    static func run<TimeoutClock: Clock>(
        executable: URL,
        request: LocalAgentRequest,
        timeout: Duration = .seconds(900),
        clock: TimeoutClock = ContinuousClock(),
        onLine: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> LocalAgentProcessResult where TimeoutClock.Duration == Duration {
        let lifetime = LocalAgentProcessLifetime(clock: clock)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let process = Process()
            let input = Pipe()
            let output = Pipe()
            let error = Pipe()
            let stdout = LocalAgentPipe(output.fileHandleForReading)
            let stderr = LocalAgentPipe(error.fileHandleForReading)
            process.executableURL = executable
            process.arguments = request.arguments
            process.currentDirectoryURL = request.directory
            process.standardInput = input
            process.standardOutput = output
            process.standardError = error
            process.terminationHandler = { [weak lifetime] process in
                lifetime?.didExit(status: process.terminationStatus)
            }
            defer {
                stdout.channel.close(flags: .stop)
                stderr.channel.close(flags: .stop)
            }
            try lifetime.install(process, channels: [stdout.channel, stderr.channel])
            try Task.checkCancellation()
            try process.run()
            lifetime.didLaunch()
            let watchdog = Task {
                do {
                    while let deadline = lifetime.inactivityDeadline(after: timeout) {
                        try await clock.sleep(until: deadline, tolerance: nil)
                        try Task.checkCancellation()
                    }
                }
                catch { return }
            }
            defer { watchdog.cancel() }
            do {
                let result = try await withThrowingTaskGroup(of: Completion.self) { group in
                    group.addTask {
                        try await write(request.input, to: input.fileHandleForWriting)
                        return .input
                    }
                    group.addTask {
                        try await readLines(stdout.chunks, onActivity: { lifetime.recordActivity() }, onLine: onLine)
                        return .output
                    }
                    group.addTask { .diagnostics(try await readDiagnostics(stderr.chunks)) }
                    group.addTask {
                        .exit(await lifetime.waitForExit())
                    }
                    var status: Int32?
                    var diagnostics = ""
                    do {
                        for try await completion in group {
                            switch completion {
                            case .exit(let value): status = value
                            case .diagnostics(let value): diagnostics = value
                            case .input, .output: break
                            }
                        }
                    } catch {
                        lifetime.cancel()
                        group.cancelAll()
                        throw error
                    }
                    guard let status else { throw LocalAgentFailure.incompleteOutput }
                    return LocalAgentProcessResult(status: status, diagnostics: diagnostics)
                }
                try Task.checkCancellation()
                if lifetime.didTimeOut { throw LocalAgentFailure.timedOut }
                return result
            } catch {
                lifetime.cancel()
                if lifetime.didTimeOut { throw LocalAgentFailure.timedOut }
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            lifetime.cancel()
        }
    }

    @concurrent private static func write(_ data: Data, to handle: FileHandle) async throws {
        do {
            try Task.checkCancellation()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            do { try handle.close() }
            catch { Log.agent.error("local agent stdin close failed") }
            throw error
        }
    }

    private static func readLines(
        _ chunks: AsyncThrowingStream<Data, Error>,
        onActivity: @escaping @Sendable () -> Void,
        onLine: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        var buffer = Data()
        var total = 0
        for try await chunk in chunks {
            try Task.checkCancellation()
            onActivity()
            guard chunk.count <= 16_777_216 - total else { throw LocalAgentFailure.outputLimit }
            total += chunk.count
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                guard line.count <= 2_097_152 else { throw LocalAgentFailure.outputLimit }
                buffer.removeSubrange(...newline)
                if !line.isEmpty { try await onLine(line) }
            }
            guard buffer.count <= 2_097_152 else { throw LocalAgentFailure.outputLimit }
        }
        if !buffer.isEmpty { try await onLine(buffer) }
    }

    private static func readDiagnostics(_ chunks: AsyncThrowingStream<Data, Error>) async throws -> String {
        var buffer = Data()
        for try await chunk in chunks {
            try Task.checkCancellation()
            buffer.append(chunk.prefix(max(0, 65_536 - buffer.count)))
        }
        return String(decoding: buffer, as: UTF8.self)
    }
}
