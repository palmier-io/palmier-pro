import Testing
@testable import PalmierPro

@Suite("Scrub audio output state")
struct ScrubAudioOutputStateTests {
    @Test func startsPlayerOncePerRunningSession() {
        var state = ScrubAudioOutputState()

        state.graphPrepared()
        state.engineStarted()

        let firstStart = state.startPlayerIfNeeded()
        let duplicateStart = state.startPlayerIfNeeded()

        #expect(firstStart)
        #expect(!duplicateStart)
        #expect(state.graph == .running)
        #expect(state.playerStarted)
    }

    @Test func stopRequiresEngineRestartAndAllowsPlayerRestart() {
        var state = ScrubAudioOutputState()
        state.graphPrepared()
        state.engineStarted()
        let initialStart = state.startPlayerIfNeeded()
        #expect(initialStart)

        state.stop()

        #expect(state.graph == .stopped)
        #expect(!state.playerStarted)
        let stoppedStart = state.startPlayerIfNeeded()
        #expect(!stoppedStart)

        state.engineStarted()
        let restarted = state.startPlayerIfNeeded()
        #expect(restarted)
    }

    @Test func invalidationRequiresNewGraph() {
        var state = ScrubAudioOutputState()
        state.graphPrepared()
        state.engineStarted()
        let initialStart = state.startPlayerIfNeeded()
        #expect(initialStart)

        state.invalidate()

        #expect(state.graph == .missing)
        #expect(!state.playerStarted)
        let invalidatedStart = state.startPlayerIfNeeded()
        #expect(!invalidatedStart)
    }
}

@Suite("Scrub audio pending state")
struct ScrubAudioPendingStateTests {
    @Test func keepsOnlyLatestPendingValue() {
        var state = ScrubAudioPendingState<Int>()

        let generation = state.submit(1)!
        let firstValue = state.take(for: generation)
        let duplicateDrain = state.submit(2)
        let secondDuplicateDrain = state.submit(3)
        let latestValue = state.take(for: generation)
        let exhausted = state.take(for: generation)
        let nextDrain = state.finishDrain(for: generation)

        #expect(firstValue == 1)
        #expect(duplicateDrain == nil)
        #expect(secondDuplicateDrain == nil)
        #expect(latestValue == 3)
        #expect(exhausted == nil)
        #expect(nextDrain == nil)
    }

    @Test func cancelDiscardsOldValuesAndReschedulesNewGeneration() {
        var state = ScrubAudioPendingState<Int>()

        let oldGeneration = state.submit(1)!
        state.cancel()
        let duplicateDrain = state.submit(2)
        let staleValue = state.take(for: oldGeneration)
        let newGeneration = state.finishDrain(for: oldGeneration)
        let currentValue = state.take(for: newGeneration!)

        #expect(duplicateDrain == nil)
        #expect(staleValue == nil)
        #expect(newGeneration == state.generation)
        #expect(currentValue == 2)
    }

    @Test func cancelWithoutNewValueDoesNotScheduleAnotherDrain() {
        var state = ScrubAudioPendingState<Int>()

        let oldGeneration = state.submit(1)!
        state.cancel()
        let staleValue = state.take(for: oldGeneration)
        let nextGeneration = state.finishDrain(for: oldGeneration)

        #expect(staleValue == nil)
        #expect(nextGeneration == nil)
        #expect(state.drainGeneration == nil)
    }
}
