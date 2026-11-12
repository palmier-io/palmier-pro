import Foundation
import Testing
@testable import CompositorPro

@MainActor
private final class CloseOwnerSignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !signaled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        signaled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

@Suite("Project close ownership")
@MainActor
struct ProjectCloseOwnerTests {
    @Test func cancellingOneCloseKeepsOtherOwnersFencedUntilLastCancellation() async throws {
        let coordinator = ProjectPackageCoordinator()
        var reopenings = 0
        var state = 0
        coordinator.onReopen = { reopenings += 1 }
        let native = try #require(coordinator.beginClosing())
        let tool = try #require(coordinator.beginClosing())
        let quit = try #require(coordinator.beginClosing())
        for owner in [native, tool] {
            coordinator.cancelClosing(owner)
            coordinator.cancelClosing(owner)
            #expect(coordinator.isClosing)
            #expect(reopenings == 0)
            #expect(throws: CancellationError.self) { try coordinator.admitIntent() }
            await #expect(throws: CancellationError.self) {
                try await coordinator.withMutation { _ in state += 1 }
            }
        }
        try coordinator.validate(quit)
        coordinator.cancelClosing(quit)
        coordinator.cancelClosing(quit)
        #expect(!coordinator.isClosing)
        #expect(reopenings == 1)
        #expect(state == 0)
        try await coordinator.withIntent { _ in state += 1 }
        #expect(state == 1)
    }

    @Test func foreignAndExpiredOwnersCannotReleaseOrFinishNewAttempt() throws {
        let coordinator = ProjectPackageCoordinator()
        let foreignProject = ProjectPackageCoordinator()
        let expired = try #require(coordinator.beginClosing())
        coordinator.cancelClosing(expired)
        var reopenings = 0
        coordinator.onReopen = { reopenings += 1 }
        let current = try #require(coordinator.beginClosing())
        let foreign = try #require(foreignProject.beginClosing())
        for owner in [expired, foreign] {
            coordinator.cancelClosing(owner)
            #expect(throws: CancellationError.self) { try coordinator.validate(owner) }
            #expect(throws: CancellationError.self) { try coordinator.finishClosing(owner) }
        }
        try coordinator.validate(current)
        try foreignProject.validate(foreign)
        #expect(coordinator.isClosing)
        #expect(!coordinator.isClosed)
        #expect(reopenings == 0)
        coordinator.cancelClosing(current)
        #expect(reopenings == 1)
    }

    @Test func oneConfirmedOwnerExpiresAllOthersWithoutReopeningOrDuplicateClose() throws {
        let coordinator = ProjectPackageCoordinator()
        var reopenings = 0
        coordinator.onReopen = { reopenings += 1 }
        let first = try #require(coordinator.beginClosing())
        let second = try #require(coordinator.beginClosing())
        try coordinator.finishClosing(second)
        for owner in [first, second] {
            coordinator.cancelClosing(owner)
            #expect(throws: CancellationError.self) { try coordinator.validate(owner) }
            #expect(throws: CancellationError.self) { try coordinator.finishClosing(owner) }
        }
        #expect(coordinator.beginClosing() == nil)
        #expect(coordinator.isClosing)
        #expect(coordinator.isClosed)
        #expect(!coordinator.canFinishClosing)
        #expect(reopenings == 0)
    }

    @Test func staleCompletionAfterAwaitCannotFinishAnotherOwnersClose() async throws {
        let coordinator = ProjectPackageCoordinator()
        let pending = try #require(coordinator.beginClosing())
        let other = try #require(coordinator.beginClosing())
        let entered = CloseOwnerSignal()
        let resume = CloseOwnerSignal()
        let closing = Task {
            try coordinator.validate(pending)
            entered.signal()
            await resume.wait()
            try coordinator.finishClosing(pending)
        }
        await entered.wait()
        coordinator.cancelClosing(pending)
        resume.signal()
        await #expect(throws: CancellationError.self) { try await closing.value }
        #expect(coordinator.isClosing)
        #expect(!coordinator.isClosed)
        try coordinator.finishClosing(other)
        #expect(coordinator.isClosed)
    }

    @Test func cancelledCloseWaiterReturnsWithoutDrainingOrReleasingAnotherOwner() async throws {
        let coordinator = ProjectPackageCoordinator()
        let intent = try coordinator.admitIntent()
        let first = try #require(coordinator.beginClosing())
        let second = try #require(coordinator.beginClosing())
        let entered = CloseOwnerSignal()
        let waiting = Task {
            defer { coordinator.cancelClosing(first) }
            entered.signal()
            try await coordinator.waitUntilIdle(for: first)
        }
        await entered.wait()
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(coordinator.isClosing)
        #expect(!coordinator.canFinishClosing)
        try coordinator.validate(intent)
        try coordinator.validate(second)
        coordinator.finishIntent(intent)
        try coordinator.finishClosing(second)
    }

    @Test func explicitOwnerCancellationResumesOnlyItsWaiters() async throws {
        let coordinator = ProjectPackageCoordinator()
        let intent = try coordinator.admitIntent()
        let first = try #require(coordinator.beginClosing())
        let second = try #require(coordinator.beginClosing())
        let firstEntered = CloseOwnerSignal()
        let secondEntered = CloseOwnerSignal()
        var secondFinished = false
        let firstWait = Task {
            firstEntered.signal()
            try await coordinator.waitUntilIdle(for: first)
        }
        let secondWait = Task {
            secondEntered.signal()
            try await coordinator.waitUntilIdle(for: second)
            secondFinished = true
        }
        await firstEntered.wait()
        await secondEntered.wait()
        coordinator.cancelClosing(first)
        await #expect(throws: CancellationError.self) { try await firstWait.value }
        #expect(!secondFinished)
        coordinator.finishIntent(intent)
        try await secondWait.value
        #expect(secondFinished)
        try coordinator.finishClosing(second)
    }

    @Test func overlappingCloseStillAllowsAdmittedChildAndWaitsForCleanup() async throws {
        let coordinator = ProjectPackageCoordinator()
        let entered = CloseOwnerSignal()
        let proceed = CloseOwnerSignal()
        let cleaning = CloseOwnerSignal()
        let release = CloseOwnerSignal()
        var events: [String] = []
        let intent = coordinator.startIntent { root in
            entered.signal()
            await proceed.wait()
            try coordinator.validate(root)
            try await coordinator.withMutation { lease in
                try coordinator.validate(lease)
                events.append("commit")
                cleaning.signal()
                await release.wait()
                events.append("cleanup")
            }
        } onFailure: { Issue.record($0) }
        await entered.wait()
        let native = try #require(coordinator.beginClosing())
        let quit = try #require(coordinator.beginClosing())
        coordinator.cancelClosing(native)
        proceed.signal()
        await cleaning.wait()
        #expect(events == ["commit"])
        #expect(throws: CancellationError.self) { try coordinator.finishClosing(quit) }
        coordinator.enqueueSave { lease in
            events.append("save")
            coordinator.finishSave(lease) {}
        }
        release.signal()
        try await coordinator.waitUntilIdle(for: quit)
        await intent.value
        #expect(events == ["commit", "cleanup", "save"])
        try coordinator.finishClosing(quit)
    }

    @Test func ordinarySaveDoesNotWaitForIntentButCloseDoes() async throws {
        let coordinator = ProjectPackageCoordinator()
        let intent = try coordinator.admitIntent()
        let owner = try #require(coordinator.beginClosing())
        var saved = false
        coordinator.enqueueSave { lease in
            saved = true
            coordinator.finishSave(lease) {}
        }
        #expect(saved)
        #expect(!coordinator.canFinishClosing)
        coordinator.finishIntent(intent)
        try await coordinator.waitUntilIdle(for: owner)
        try coordinator.finishClosing(owner)
    }

    @Test func quitReservationsFenceEveryProjectBeforeFirstSuspensionAndReleaseOnlyQuit() async throws {
        let first = ProjectPackageCoordinator()
        let second = ProjectPackageCoordinator()
        let native = try #require(second.beginClosing())
        let reservations = try [first, second].map { ($0, try #require($0.beginClosing())) }
        for (project, _) in reservations {
            #expect(throws: CancellationError.self) { try project.admitIntent() }
        }
        for (project, lease) in reservations { project.cancelClosing(lease) }
        #expect(!first.isClosing)
        #expect(second.isClosing)
        await #expect(throws: CancellationError.self) { try await second.withMutation { _ in } }
        try second.validate(native)
        second.cancelClosing(native)
        #expect(!second.isClosing)
    }

    @Test func closeDrainInsideOwnEditIntentRefusesInsteadOfDeadlocking() async throws {
        let coordinator = ProjectPackageCoordinator()
        try await coordinator.withIntent { intent in
            let close = try #require(coordinator.beginClosing())
            defer { coordinator.cancelClosing(close) }
            await #expect(throws: CancellationError.self) { try await coordinator.waitUntilIdle(for: close) }
            try coordinator.validate(intent)
        }
        #expect(!coordinator.isClosing)
        try await coordinator.withMutation { _ in }
    }
}
