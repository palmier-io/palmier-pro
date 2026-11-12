import Foundation
import Testing
@testable import CompositorPro

@Suite("Agent request progress")
@MainActor
struct AgentRequestProgressTests {
    @Test func silentProviderShowsElapsedTimeAndStopGuidance() {
        let start = ContinuousClock.now
        let progress = AgentRequestProgress(phase: .waitingForResponse, providerName: "Test Provider", now: start)
        #expect(progress.elapsedSeconds(at: start.advanced(by: .seconds(61))) == 61)
        #expect(progress.detail(at: start.advanced(by: .seconds(61))) ==
                L10n.string("No response received from \("Test Provider") yet. You can stop this request."))
        #expect(progress.detail(at: start.advanced(by: .seconds(19))) == L10n.string("Waiting for \("Test Provider")."))
    }

    @Test func providerActivityRestartsQuietTimeWithoutResettingElapsedTime() {
        let start = ContinuousClock.now
        var progress = AgentRequestProgress(phase: .waitingForResponse, providerName: "Test Provider", now: start)
        progress.update(.streaming, now: start.advanced(by: .seconds(25)))
        progress.update(.streaming, now: start.advanced(by: .seconds(40)))
        #expect(progress.elapsedSeconds(at: start.advanced(by: .seconds(59))) == 59)
        #expect(progress.detail(at: start.advanced(by: .seconds(59))) == nil)
        #expect(progress.detail(at: start.advanced(by: .seconds(60))) ==
                L10n.string("No new response content for \(Int64(20))s. Waiting for \("Test Provider")."))
    }

    @Test func toolDelayNamesTheOperationAndOffersStop() {
        let start = ContinuousClock.now
        let progress = AgentRequestProgress(phase: .toolRunning("review_timeline"), providerName: "Test Provider", now: start)
        #expect(progress.phase.displayText == L10n.string("Running \("review_timeline")…"))
        #expect(progress.detail(at: start.advanced(by: .seconds(60))) ==
                L10n.string("This tool is still running. You can stop this request."))
    }
}
