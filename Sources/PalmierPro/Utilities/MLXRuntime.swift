import Foundation
import os

// Skip MLX model loads in unbundled builds to avoid a fatal mlx.metallib error.
enum MLXRuntime {
    static let isAvailable = Bundle.main.bundleURL.pathExtension == "app"
    private static let gate = MLXOperationGate()

    struct Unavailable: Error, LocalizedError {
        var errorDescription: String? {
            "MLX analysis is unavailable in unbundled builds (missing mlx.metallib)"
        }
    }

    static func requireAvailable() throws {
        guard isAvailable else { throw Unavailable() }
    }

    static func beginOperation() throws {
        try requireAvailable()
        guard gate.begin() else { throw CancellationError() }
    }
    static func endOperation() { gate.end() }
    static var shouldStop: Bool { gate.shouldStop }
    static func beginTermination() -> Bool { gate.stop() }
    static func waitUntilIdle() async { await gate.waitUntilIdle() }
}

final class MLXOperationGate: @unchecked Sendable {
    private let stopping = OSAllocatedUnfairLock(initialState: false)
    private let operations = DispatchGroup()
    func begin() -> Bool {
        stopping.withLock { stopping in
            guard !stopping else { return false }
            operations.enter()
            return true
        }
    }
    func end() { operations.leave() }
    var shouldStop: Bool { stopping.withLock { $0 } }
    func stop() -> Bool {
        stopping.withLock { $0 = true }
        return operations.wait(timeout: .now()) == .success
    }
    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            operations.notify(queue: .global(qos: .utility)) {
                continuation.resume()
            }
        }
    }
}
