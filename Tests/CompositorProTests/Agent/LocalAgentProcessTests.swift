import Darwin
import Foundation
import Testing
@testable import CompositorPro

actor LocalAgentTestSignal {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() { opened = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
}

enum LocalAgentTestFiles {
    @concurrent static func script(_ source: String) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("local-agent-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("agent")
        try ("#!/usr/bin/python3\n" + source).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }
    @concurrent static func remove(_ script: URL) async throws {
        try FileManager.default.removeItem(at: script.deletingLastPathComponent())
    }
}

private actor LocalAgentLineRecorder {
    var lines: [String] = []
    func append(_ data: Data) { lines.append(String(decoding: data, as: UTF8.self)) }
}

@Suite("Local agent process lifecycle", .serialized)
struct LocalAgentProcessTests {
    @Test(.timeLimit(.minutes(1)))
    func activeRunSurvivesTheOriginalDeadlineAndStopsAfterInactivity() async throws {
        let script = try await LocalAgentTestFiles.script("""
        import os, signal, sys
        sys.stdin.read()
        signal.signal(signal.SIGUSR1, lambda *_: print('active', flush=True))
        print(os.getpid(), flush=True)
        while True:
            signal.pause()
        """)
        let started = LocalAgentTestSignal()
        let active = LocalAgentTestSignal()
        let recorder = LocalAgentLineRecorder()
        let clock = LocalAgentProcessTestClock()
        let origin = clock.now
        var deadlines = clock.scheduled.makeAsyncIterator()
        let run = Task {
            defer { clock.finishObservations() }
            return try await LocalAgentProcess.run(executable: script, request: .init(
                directory: script.deletingLastPathComponent(), arguments: [], input: Data()
            ), timeout: .seconds(900), clock: clock) { data in
                await recorder.append(data)
                if String(decoding: data, as: UTF8.self) == "active" {
                    await active.open()
                } else {
                    await started.open()
                }
            }
        }
        do {
            await started.wait()
            let pid = try #require(await recorder.lines.first.flatMap(Int32.init))
            #expect(await deadlines.next() == origin.advanced(by: .seconds(900)))
            clock.advance(to: origin.advanced(by: .seconds(899)))
            #expect(kill(pid, SIGUSR1) == 0)
            await active.wait()
            clock.advance(to: origin.advanced(by: .seconds(900)))
            let extended = try #require(await deadlines.next(), "Active run was terminated at its original deadline")
            #expect(extended == origin.advanced(by: .seconds(1799)))
            #expect(kill(pid, 0) == 0)
            clock.advance(to: extended)
            do {
                _ = try await run.value
                Issue.record("Silent process completed without a timeout")
            } catch {
                #expect(error as? LocalAgentFailure == .timedOut)
            }
            #expect(kill(pid, 0) == -1)
            #expect(errno == ESRCH)
        } catch {
            run.cancel()
            _ = await run.result
            try await LocalAgentTestFiles.remove(script)
            throw error
        }
        try await LocalAgentTestFiles.remove(script)
    }

    @Test func drainsBothPipesAndReassemblesSplitLines() async throws {
        let script = try await LocalAgentTestFiles.script("""
        import sys
        sys.stdin.read()
        sys.stderr.write('diagnostic\\n' * 10000)
        sys.stderr.flush()
        sys.stdout.write('{"event":'); sys.stdout.flush()
        sys.stdout.write('"init"}\\n{"event":"last"}'); sys.stdout.flush()
        """)
        let recorder = LocalAgentLineRecorder()
        do {
            let result = try await LocalAgentProcess.run(executable: script, request: .init(
                directory: script.deletingLastPathComponent(), arguments: [], input: Data("request".utf8)
            )) { await recorder.append($0) }
            #expect(result.status == 0)
            #expect(result.diagnostics.utf8.count <= 65_536)
            #expect(await recorder.lines == [#"{"event":"init"}"#, #"{"event":"last"}"#])
        } catch { try await LocalAgentTestFiles.remove(script); throw error }
        try await LocalAgentTestFiles.remove(script)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func cancellationWaitsForTheOwnedProcessToExit(_ ignoresTermination: Bool) async throws {
        let script = try await LocalAgentTestFiles.script("""
        import os, signal, sys
        sys.stdin.read()
        \(ignoresTermination ? "signal.signal(signal.SIGTERM, signal.SIG_IGN)" : "")
        print(os.getpid(), flush=True)
        signal.pause()
        """)
        let started = LocalAgentTestSignal()
        let recorder = LocalAgentLineRecorder()
        let run = Task {
            try await LocalAgentProcess.run(executable: script, request: .init(
                directory: script.deletingLastPathComponent(), arguments: [], input: Data()
            )) { data in
                await recorder.append(data)
                await started.open()
            }
        }
        await started.wait()
        run.cancel()
        do {
            _ = try await run.value
            Issue.record("Cancelled process completed successfully")
        } catch {
            #expect(error is CancellationError)
        }
        let lines = await recorder.lines
        let pid = try #require(lines.first.flatMap(Int32.init))
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
        try await LocalAgentTestFiles.remove(script)
    }
}
