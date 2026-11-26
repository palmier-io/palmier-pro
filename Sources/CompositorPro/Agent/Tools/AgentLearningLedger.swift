import Foundation

/// What happened when one tool call ran. Stable values only — never user text or media content.
enum AgentLearningOutcome: String, Codable, Sendable, Equatable {
    case success
    case noOp
    case error
}

/// One executed tool call, recorded for post-edit learning. Privacy-safe by construction:
/// tool identity, outcome, and duration only — never prompts, transcripts, or asset names.
struct AgentLearningObservation: Codable, Sendable, Equatable {
    var runId: String
    var sequence: Int
    var tool: String
    var outcome: AgentLearningOutcome
    var timelineChanged: Bool
    var durationMs: Int
    var timestamp: TimeInterval
}

/// Local, bounded learning ledger. Learns two things from each edit:
/// (1) which action reliably follows which (transition playbook), and
/// (2) which tools frequently fail or run slowly (avoidance flags).
///
/// The derived playbook is injected into the agent's instructions as guidance,
/// so later turns reuse the fastest reliable editing path. Records persist in
/// UserDefaults as one small JSON payload; corruption falls back to empty.
struct AgentLearningLedger: Codable, Sendable, Equatable {
    static let userDefaultsKey = "io.compositor.pro.agent.learning.ledger.v1"
    static let maxObservations = 500

    var version = 1
    var observations: [AgentLearningObservation] = []

    init(version: Int = 1, observations: [AgentLearningObservation] = []) {
        self.version = version
        self.observations = observations
    }

    // MARK: - Persistence (UserDefaults, tiny bounded payload)

    static func load(from defaults: UserDefaults = .standard) -> AgentLearningLedger {
        guard let data = defaults.data(forKey: userDefaultsKey),
              let ledger = try? JSONDecoder().decode(AgentLearningLedger.self, from: data),
              ledger.version == 1 else { return AgentLearningLedger() }
        return ledger
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.userDefaultsKey)
    }

    mutating func record(_ observation: AgentLearningObservation) {
        observations.append(observation)
        if observations.count > Self.maxObservations {
            observations.removeFirst(observations.count - Self.maxObservations)
        }
    }

    // MARK: - Playbook derivation (pure, deterministic)

    struct Transition {
        var from: String
        var to: String
        var support: Int
        var successRate: Double
    }

    struct ToolStat {
        var tool: String
        var samples: Int
        var successRate: Double
        var avgDurationMs: Double
    }

    struct Playbook {
        var transitions: [Transition] = []
        var riskyTools: [ToolStat] = []
        var slowTools: [ToolStat] = []

        var isEmpty: Bool { transitions.isEmpty && riskyTools.isEmpty && slowTools.isEmpty }

        /// Concise, machine-style guidance for the agent's system prompt.
        func promptSection() -> String {
            guard !isEmpty else { return "" }
            var lines = ["## Learned playbook (from prior edits in this copy of the app)",
                         "Prefer the reliable action sequences below when they fit the request. Correctness and the user's goal always win over this guidance."]
            for transition in transitions {
                lines.append("- After \(transition.from), \(transition.to) worked \(transition.support) times (success \(Int((transition.successRate * 100).rounded()))%).")
            }
            for stat in sortedRiskyTools {
                lines.append("- \(stat.tool) frequently failed (\(Int((stat.successRate * 100).rounded()))% success over \(stat.samples) runs) — prefer an alternative or verify prerequisites first.")
            }
            for stat in slowTools {
                lines.append("- \(stat.tool) was slow (avg \(Int(stat.avgDurationMs.rounded()))ms over \(stat.samples) runs) — batch its inputs or avoid unnecessary calls.")
            }
            return lines.joined(separator: "\n")
        }

        private var sortedRiskyTools: [ToolStat] { riskyTools.sorted { $0.successRate < $1.successRate } }
    }

    func playbook() -> Playbook {
        let successfulRuns = observations
            .filter { $0.outcome == .success }
        var runGroups: [String: [AgentLearningObservation]] = [:]
        for observation in successfulRuns {
            runGroups[observation.runId, default: []].append(observation)
        }
        for key in runGroups.keys {
            runGroups[key]?.sort { $0.sequence < $1.sequence }
        }

        // (before, after) pairs within one run, both successful.
        var pairStats: [String: (count: Int, success: Int)] = [:]
        for (_, group) in runGroups {
            for (a, b) in zip(group, group.dropFirst()) {
                let key = "\(a.tool)\u{1F}\(b.tool)"
                var stat = pairStats[key] ?? (0, 0)
                stat.count += 1
                stat.success += 1
                pairStats[key] = stat
            }
        }
        // Error observations penalize the transition that led into them.
        let errors = observations.filter { $0.outcome == .error }
        for error in errors {
            guard let previous = observations
                .filter({ $0.runId == error.runId && $0.sequence < error.sequence })
                .max(by: { $0.sequence < $1.sequence }) else { continue }
            let key = "\(previous.tool)\u{1F}\(error.tool)"
            var stat = pairStats[key] ?? (0, 0)
            stat.count += 1
            pairStats[key] = stat
        }

        let transitions = pairStats
            .compactMap { key, stat -> Transition? in
                let parts = key.split(separator: "\u{1F}")
                guard parts.count == 2 else { return nil }
                let rate = stat.count > 0 ? Double(stat.success) / Double(stat.count) : 0
                guard stat.count >= 2, rate >= 0.7 else { return nil }
                return Transition(from: String(parts[0]), to: String(parts[1]), support: stat.success, successRate: rate)
            }
            .sorted { $0.support > $1.support || ($0.support == $1.support && $0.successRate > $1.successRate) }
            .prefix(8)
            .map { $0 }

        var byTool: [String: [AgentLearningObservation]] = [:]
        for observation in observations { byTool[observation.tool, default: []].append(observation) }
        var risky: [ToolStat] = []
        var slow: [ToolStat] = []
        for (tool, group) in byTool where group.count >= 3 {
            let successes = group.filter { $0.outcome == .success }.count
            let rate = Double(successes) / Double(group.count)
            let avg = Double(group.map(\.durationMs).reduce(0, +)) / Double(group.count)
            let stat = ToolStat(tool: tool, samples: group.count, successRate: rate, avgDurationMs: avg)
            if rate < 0.5 { risky.append(stat) }
            if avg > 5000 { slow.append(stat) }
        }
        return Playbook(transitions: transitions, riskyTools: risky, slowTools: slow)
    }
}

extension AgentLearningOutcome {
    /// Classify a tool result without looking at user text: only the receipt's no-op marker.
    static func classify(_ result: ToolResult) -> AgentLearningOutcome {
        if result.isError { return .error }
        let text = result.content.compactMap { block -> String? in
            if case .text(let s) = block { return s }
            return nil
        }.joined(separator: "\n")
        if text.contains("\"noOp\"") || text.contains("noOp") { return .noOp }
        return .success
    }
}
