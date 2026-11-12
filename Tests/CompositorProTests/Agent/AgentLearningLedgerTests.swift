import Foundation
import Testing
@testable import CompositorPro

@Suite("AgentLearningLedger — editing playbook")
struct AgentLearningLedgerTests {
    private func obs(_ run: String, _ seq: Int, _ tool: String, _ outcome: AgentLearningOutcome, _ ms: Int = 100) -> AgentLearningObservation {
        AgentLearningObservation(
            runId: run, sequence: seq, tool: tool, outcome: outcome,
            timelineChanged: outcome == .success, durationMs: ms, timestamp: Double(seq)
        )
    }

    @Test func successfulTransitionsAreLearned() {
        var ledger = AgentLearningLedger()
        // Two successful runs of a -> b.
        for run in ["r1", "r2"] {
            ledger.record(obs(run, 0, "get_timeline", .success))
            ledger.record(obs(run, 1, "move_clips", .success))
        }
        let playbook = ledger.playbook()
        #expect(playbook.transitions.contains { $0.from == "get_timeline" && $0.to == "move_clips" && $0.support == 2 })
        let section = playbook.promptSection()
        #expect(section.contains("After get_timeline, move_clips worked 2 times"))
    }

    @Test func failedTransitionsAreNotLearned() {
        var ledger = AgentLearningLedger()
        for run in ["r1", "r2"] {
            ledger.record(obs(run, 0, "get_timeline", .success))
            ledger.record(obs(run, 1, "move_clips", .error))
        }
        #expect(ledger.playbook().transitions.isEmpty)
    }

    @Test func singleSampleDoesNotTeach() {
        var ledger = AgentLearningLedger()
        ledger.record(obs("r1", 0, "get_timeline", .success))
        ledger.record(obs("r1", 1, "move_clips", .success))
        #expect(ledger.playbook().transitions.isEmpty)
    }

    @Test func frequentlyFailingToolsAreFlagged() {
        var ledger = AgentLearningLedger()
        for i in 0..<4 { ledger.record(obs("r\(i)", 0, "apply_plan", .error)) }
        let skill = ledger.playbook()
        #expect(skill.riskyTools.contains { $0.tool == "apply_plan" && $0.samples == 4 })
        #expect(skill.promptSection().contains("apply_plan frequently failed"))
    }

    @Test func slowToolsAreFlagged() {
        var ledger = AgentLearningLedger()
        for i in 0..<3 { ledger.record(obs("r\(i)", 0, "review_timeline", .success, 9000)) }
        let playbook = ledger.playbook()
        #expect(playbook.slowTools.contains { $0.tool == "review_timeline" })
    }

    @Test func classifyDetectsOutcome() {
        #expect(AgentLearningOutcome.classify(.ok("{\"ok\":1}")) == .success)
        #expect(AgentLearningOutcome.classify(.ok("{\"noOp\":true}")) == .noOp)
        #expect(AgentLearningOutcome.classify(.error("boom")) == .error)
    }

    @Test func persistenceRoundTripsAndRingStaysBounded() throws {
        let suite = UserDefaults(suiteName: "test.agent.learning")!
        suite.removePersistentDomain(forName: "test.agent.learning")
        var ledger = AgentLearningLedger()
        ledger.record(obs("r1", 0, "get_timeline", .success))
        ledger.save(to: suite)
        let loaded = AgentLearningLedger.load(from: suite)
        #expect(loaded.observations == ledger.observations)
    }

    @Test func ringBufferDropsOldest() {
        var ledger = AgentLearningLedger()
        for i in 0..<(AgentLearningLedger.maxObservations + 10) {
            ledger.record(obs("r", i, "get_media", .success))
        }
        #expect(ledger.observations.count == AgentLearningLedger.maxObservations)
        #expect(ledger.observations.first?.sequence == 10)
    }

    @Test func emptyLedgerProducesNoSection() {
        #expect(AgentLearningLedger().playbook().promptSection().isEmpty)
    }
}
