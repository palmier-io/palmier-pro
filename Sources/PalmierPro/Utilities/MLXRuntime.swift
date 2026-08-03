import Foundation
import os

enum MLXRuntime {
    static var isAvailable: Bool {
        AppCapabilities.current.availability(of: .silenceDetection).isAvailable
    }
    private static let gate = MLXOperationGate()

    struct Unavailable: Error, LocalizedError {
        let feature: AppFeature
        let reason: AppFeatureUnavailability

        init(feature: AppFeature = .silenceDetection) {
            self.feature = feature
            guard case .unavailable(let reason) = AppCapabilities.current.availability(of: feature) else {
                preconditionFailure("Unavailable created for an available feature")
            }
            self.reason = reason
        }

        var errorDescription: String? {
            switch reason {
            case .requiresAppleSilicon:
                "\(feature.rawValue) requires Apple silicon"
            case .buildExcludesBundledSpeech:
                "\(feature.rawValue) is not included in this build"
            case .buildExcludesHostedBackend:
                "\(feature.rawValue) is not included in this build"
            case .unpackagedSpeechResources:
                "\(feature.rawValue) is unavailable because the MLX runtime resources are missing"
            }
        }
    }

    static func requireAvailable(for feature: AppFeature = .silenceDetection) throws {
        guard !AppCapabilities.current.availability(of: feature).isAvailable else { return }
        throw Unavailable(feature: feature)
    }

    static func beginOperation(for feature: AppFeature = .silenceDetection) throws {
        try requireAvailable(for: feature)
        guard gate.begin() else { throw CancellationError() }
    }
    static func endOperation() { gate.end() }

    private static let inferenceGate = AsyncSemaphore(value: 1)

    static func beginInference(for feature: AppFeature = .silenceDetection) async throws {
        try beginOperation(for: feature)
        do { try await inferenceGate.wait() } catch {
            endOperation()
            throw error
        }
    }
    static func endInference() {
        Task { await inferenceGate.signal() }
        endOperation()
    }
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
