import Foundation
import Network
import Testing
@testable import PalmierPro

@Suite("MCPService start/stop races", .serialized)
@MainActor
struct MCPServiceTests {

    @Test func stopBeforeStartTaskRunsLeavesNoListener() async throws {
        try await withLoopbackMCP {
            try await requireMCPPortFree()

            let service = MCPService(projectProvider: { nil })
            service.start()
            await service.stop()

            #expect(service.isRunning == false)
            let bound = await mcpPortBecameAccepting(within: .milliseconds(500))
            #expect(!bound)
            #expect(service.isRunning == false)
        }
    }

    @Test func restartAfterImmediateStopBindsOneListener() async throws {
        try await withLoopbackMCP {
            try await requireMCPPortFree()

            let service = MCPService(projectProvider: { nil })
            service.start()
            await service.stop()
            service.start()

            let bound = await mcpPortBecameAccepting(within: .milliseconds(500))
            #expect(bound)
            #expect(service.isRunning)

            await service.stop()
            #expect(service.isRunning == false)
            let rebound = await mcpPortBecameAccepting(within: .milliseconds(300))
            #expect(!rebound)
        }
    }
}

@MainActor
private func withLoopbackMCP(_ body: () async throws -> Void) async throws {
    let previousHost = MCPService.bindHostPreference
    MCPService.bindHostPreference = MCPService.loopbackBindHost
    defer { MCPService.bindHostPreference = previousHost }
    try await body()
}

@MainActor
private func requireMCPPortFree() async throws {
    let occupied = await tcpPortIsAccepting(MCPService.port, timeout: .milliseconds(200))
    try #require(!occupied, "MCP port \(MCPService.port) already in use")
}

private func mcpPortBecameAccepting(within timeout: Duration) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await tcpPortIsAccepting(MCPService.port, timeout: .milliseconds(50)) {
            return true
        }
        await Task.yield()
    }
    return false
}

private func tcpPortIsAccepting(_ port: UInt16, timeout: Duration) async -> Bool {
    guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return false }
    let connection = NWConnection(
        host: NWEndpoint.Host(MCPService.loopbackBindHost),
        port: endpointPort,
        using: .tcp
    )
    return await withCheckedContinuation { continuation in
        let box = ResumeBox()
        func finish(_ value: Bool) {
            guard box.complete() else { return }
            connection.cancel()
            continuation.resume(returning: value)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                finish(true)
            case .failed, .cancelled:
                finish(false)
            case .waiting(let error):
                if case .posix(let code) = error, code == .ECONNREFUSED {
                    finish(false)
                }
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        Task {
            try? await Task.sleep(for: timeout)
            finish(false)
        }
    }
}

private final class ResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func complete() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
}
