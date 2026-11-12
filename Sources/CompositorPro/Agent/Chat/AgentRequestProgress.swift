import Foundation

enum AgentStreamActivity: Equatable, Sendable {
    case connected
    case reasoning
    case generating
    case preparingTool(String)
}

struct AgentRequestProgress: Equatable, Sendable {
    enum Retry: Equatable, Sendable {
        case timeout(attempt: Int, limit: Int)
        case contextLimit
        case outputLimit

        @MainActor var displayText: String {
            switch self {
            case .timeout(let attempt, let limit):
                L10n.string("The provider timed out. Retrying \(attempt) of \(limit)…")
            case .contextLimit:
                L10n.string("The conversation exceeded the model’s limit. Reducing context and retrying…")
            case .outputLimit:
                L10n.string("The response reached the output limit. Requesting the rest…")
            }
        }
    }

    let startedAt: ContinuousClock.Instant
    let providerName: String
    private(set) var phase: AgentService.ChatStatus
    private(set) var phaseStartedAt: ContinuousClock.Instant
    private(set) var lastActivityAt: ContinuousClock.Instant
    var retry: Retry?

    init(phase: AgentService.ChatStatus, providerName: String, now: ContinuousClock.Instant = .now) {
        self.phase = phase
        self.providerName = providerName
        startedAt = now
        phaseStartedAt = now
        lastActivityAt = now
    }

    mutating func update(_ phase: AgentService.ChatStatus, now: ContinuousClock.Instant = .now) {
        if self.phase != phase {
            self.phase = phase
            phaseStartedAt = now
        }
        lastActivityAt = now
    }

    func elapsedSeconds(at now: ContinuousClock.Instant) -> Int64 {
        max(0, (now - startedAt).components.seconds)
    }

    @MainActor func detail(at now: ContinuousClock.Instant) -> String? {
        let phaseSeconds = max(0, (now - phaseStartedAt).components.seconds)
        let quietSeconds = max(0, (now - lastActivityAt).components.seconds)
        switch phase {
        case .waitingForPreviousRun:
            return L10n.string("Waiting for the previous request to finish stopping.")
        case .loadingSkills:
            return L10n.string("Loading local agent skills.")
        case .preparingContext:
            return L10n.string("Preparing conversation and media context.")
        case .connecting, .waitingForResponse:
            return phaseSeconds >= 20
                ? L10n.string("No response received from \(providerName) yet. You can stop this request.")
                : L10n.string("Waiting for \(providerName).")
        case .reasoning:
            return quietSeconds >= 20
                ? L10n.string("The provider reported reasoning. Waiting for its next update.")
                : L10n.string("The provider is reasoning.")
        case .preparingTool:
            return L10n.string("The provider is preparing tool arguments.")
        case .streaming:
            return quietSeconds >= 20
                ? L10n.string("No new response content for \(quietSeconds)s. Waiting for \(providerName).")
                : nil
        case .toolRunning:
            return phaseSeconds >= 20
                ? L10n.string("This tool is still running. You can stop this request.")
                : nil
        case .idle, .toolCompleted, .error:
            return nil
        }
    }
}
