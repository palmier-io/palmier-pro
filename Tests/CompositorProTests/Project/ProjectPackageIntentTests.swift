import Foundation
import Testing
@testable import CompositorPro

@MainActor
private final class IntentTestSignal {
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
        pending.forEach { $0.resume() }
    }
}

private enum IntentAdmissionRoute: CaseIterable, Sendable {
    case intent, explicitIntent, mutation, ownedIntent, ownedMutation

    @MainActor
    func run(on coordinator: ProjectPackageCoordinator, operation: @escaping @MainActor () -> Void) async throws {
        switch self {
        case .intent:
            try await coordinator.withIntent { _ in operation() }
        case .explicitIntent:
            let lease = try coordinator.admitIntent()
            coordinator.finishIntent(lease)
            operation()
        case .mutation:
            try await coordinator.withMutation { _ in operation() }
        case .ownedIntent, .ownedMutation:
            var failure: Error?
            let task = self == .ownedIntent
                ? coordinator.startIntent(operation: { _ in operation() }, onFailure: { failure = $0 })
                : coordinator.startMutation(operation: { _ in operation() }, onFailure: { failure = $0 })
            await task.value
            if let failure { throw failure }
        }
    }
}

@Suite("Project intent admission")
@MainActor
struct ProjectPackageIntentTests {
    @Test func admittedIntentDrainsBeforeIdleAndClosure() async throws {
        let coordinator = ProjectPackageCoordinator()
        let lease = try coordinator.admitIntent()
        let close = try #require(coordinator.beginClosing())
        let waiting = IntentTestSignal()
        var idle = false
        let drain = Task {
            waiting.signal()
            await coordinator.waitUntilIdle()
            idle = true
        }
        await waiting.wait()
        #expect(!idle)
        #expect(!coordinator.canFinishClosing)
        try coordinator.validate(lease)
        coordinator.finishIntent(lease)
        await drain.value
        #expect(idle)
        #expect(coordinator.canFinishClosing)
        try coordinator.finishClosing(close)
        #expect(coordinator.isClosed)
        #expect(throws: CancellationError.self) { try coordinator.validate(lease) }
    }

    @Test(arguments: IntentAdmissionRoute.allCases)
    private func closingProjectRefusesNewWorkWithoutMutation(route: IntentAdmissionRoute) async throws {
        let projectA = ProjectPackageCoordinator()
        let projectB = ProjectPackageCoordinator()
        var state = 0
        projectB.beginClosing()
        await #expect(throws: CancellationError.self) {
            try await route.run(on: projectB) { state += 1 }
        }
        #expect(state == 0)
        #expect(projectB.canFinishClosing)
        try await projectA.withIntent { _ in state += 1 }
        #expect(state == 1)
    }

    @Test func nestedScopesShareOneRootLifetime() async throws {
        let coordinator = ProjectPackageCoordinator()
        var nested: ProjectPackageCoordinator.IntentLease?
        try await coordinator.withIntent { root in
            coordinator.beginClosing()
            try await coordinator.withIntent { lease in
                nested = lease
                try await coordinator.withIntent(lease) { _ in }
            }
            try coordinator.validate(try #require(nested))
            try coordinator.validate(root)
            #expect(!coordinator.canFinishClosing)
        }
        #expect(throws: CancellationError.self) { try coordinator.validate(try #require(nested)) }
        #expect(coordinator.canFinishClosing)
    }

    @Test(arguments: IntentAdmissionRoute.allCases)
    private func expiredInheritedContextRefusesInsteadOfReadmitting(route: IntentAdmissionRoute) async throws {
        let coordinator = ProjectPackageCoordinator()
        let proceed = IntentTestSignal()
        var ran = false
        let child = try await coordinator.withIntent { _ in
            Task {
                await proceed.wait()
                try await route.run(on: coordinator) { ran = true }
            }
        }
        proceed.signal()
        await #expect(throws: CancellationError.self) { try await child.value }
        #expect(!ran)
        coordinator.beginClosing()
        #expect(coordinator.canFinishClosing)
    }

    @Test(arguments: IntentAdmissionRoute.allCases)
    private func foreignInheritedContextRefusesWithoutTouchingEitherProject(route: IntentAdmissionRoute) async throws {
        let projectA = ProjectPackageCoordinator()
        let projectB = ProjectPackageCoordinator()
        var ran = false
        try await projectA.withIntent { root in
            await #expect(throws: CancellationError.self) {
                try await route.run(on: projectB) { ran = true }
            }
            try projectA.validate(root)
        }
        #expect(!ran)
        projectA.beginClosing()
        projectB.beginClosing()
        #expect(projectA.canFinishClosing)
        #expect(projectB.canFinishClosing)
    }

    @Test func intentCanAwaitOrdinarySaveThenAcquirePackageMutation() async throws {
        let coordinator = ProjectPackageCoordinator()
        let saveStarted = IntentTestSignal()
        let saveFinished = IntentTestSignal()
        var save: ProjectPackageCoordinator.SaveLease?
        var events: [String] = []
        let intent = Task {
            try await coordinator.withIntent { root in
                coordinator.enqueueSave { lease in
                    save = lease
                    events.append("save")
                    saveStarted.signal()
                }
                await saveFinished.wait()
                try coordinator.validate(root)
                try await coordinator.withMutation { lease in
                    try coordinator.validate(lease)
                    events.append("mutation")
                }
            }
        }
        await saveStarted.wait()
        #expect(events == ["save"])
        coordinator.finishSave(try #require(save)) { events.append("saved") }
        saveFinished.signal()
        try await intent.value
        #expect(events == ["save", "saved", "mutation"])
        coordinator.beginClosing()
        #expect(coordinator.canFinishClosing)
    }

    @Test func closePreservesAdmittedChildBehindFifoSavesAndRefusesUnrelatedQueue() async throws {
        let coordinator = ProjectPackageCoordinator()
        let root = try coordinator.admitIntent()
        var first: ProjectPackageCoordinator.SaveLease?
        var second: ProjectPackageCoordinator.SaveLease?
        var events: [String] = []
        coordinator.enqueueSave { first = $0; events.append("first") }
        coordinator.enqueueSave { second = $0; events.append("second") }
        let childRequested = IntentTestSignal()
        let child = Task {
            try await coordinator.withIntent(root) { _ in
                childRequested.signal()
                try await coordinator.withMutation { lease in
                    try coordinator.validate(lease)
                    events.append("child")
                }
            }
        }
        await childRequested.wait()
        let unrelatedRequested = IntentTestSignal()
        let unrelated = Task {
            unrelatedRequested.signal()
            try await coordinator.withMutation { _ in events.append("unrelated") }
        }
        await unrelatedRequested.wait()
        coordinator.beginClosing()
        await #expect(throws: CancellationError.self) { try await unrelated.value }
        #expect(events == ["first"])
        #expect(!coordinator.canFinishClosing)
        coordinator.finishSave(try #require(first)) { events.append("firstComplete") }
        #expect(events == ["first", "firstComplete", "second"])
        coordinator.finishSave(try #require(second)) { events.append("secondComplete") }
        try await child.value
        #expect(events == ["first", "firstComplete", "second", "secondComplete", "child"])
        #expect(coordinator.canFinishClosing)
    }

    @Test func admittedIntentCanRequestNewChildWhileClosing() async throws {
        let coordinator = ProjectPackageCoordinator()
        try await coordinator.withIntent { root in
            coordinator.beginClosing()
            try await coordinator.withMutation { lease in
                try coordinator.validate(root)
                try coordinator.validate(lease)
            }
            #expect(throws: CancellationError.self) { try coordinator.admitIntent() }
        }
        #expect(coordinator.canFinishClosing)
    }

    @Test(arguments: [false, true])
    func expiredQueuedChildRefusesWhenSaveOrClosingAdvances(closing: Bool) async throws {
        let coordinator = ProjectPackageCoordinator()
        var save: ProjectPackageCoordinator.SaveLease?
        coordinator.enqueueSave { save = $0 }
        let requested = IntentTestSignal()
        var ran = false
        let child = try await coordinator.withIntent { _ in
            let task = Task {
                requested.signal()
                try await coordinator.withMutation { _ in ran = true }
            }
            await requested.wait()
            return task
        }
        if closing { coordinator.beginClosing() }
        coordinator.finishSave(try #require(save)) {}
        await #expect(throws: CancellationError.self) { try await child.value }
        #expect(!ran)
        coordinator.beginClosing()
        #expect(coordinator.canFinishClosing)
    }

    @Test(arguments: [false, true])
    func cancelledChildQueueResumesOnceAcrossClosingAndSaveGrant(closeFirst: Bool) async throws {
        let coordinator = ProjectPackageCoordinator()
        var save: ProjectPackageCoordinator.SaveLease?
        coordinator.enqueueSave { save = $0 }
        let requested = IntentTestSignal()
        let finish = IntentTestSignal()
        var ran = false
        let parent = Task {
            try await coordinator.withIntent { _ in
                let child = Task {
                    requested.signal()
                    try await coordinator.withMutation { _ in ran = true }
                }
                await requested.wait()
                child.cancel()
                if closeFirst { coordinator.beginClosing() }
                coordinator.finishSave(try #require(save)) {}
                if !closeFirst { coordinator.beginClosing() }
                await #expect(throws: CancellationError.self) { try await child.value }
                await finish.wait()
            }
        }
        await requested.wait()
        finish.signal()
        try await parent.value
        #expect(!ran)
        #expect(coordinator.canFinishClosing)
    }

    @Test func ownedIntentReservesBeforeSchedulingAndStillAllowsOrdinarySave() async throws {
        let coordinator = ProjectPackageCoordinator()
        let entered = IntentTestSignal()
        let finish = IntentTestSignal()
        var saved = false
        let task = coordinator.startIntent { lease in
            try coordinator.validate(lease)
            entered.signal()
            await finish.wait()
            try coordinator.validate(lease)
        } onFailure: { Issue.record($0) }
        coordinator.beginClosing()
        #expect(!coordinator.canFinishClosing)
        coordinator.enqueueSave { lease in
            saved = true
            coordinator.finishSave(lease) {}
        }
        #expect(saved)
        await entered.wait()
        finish.signal()
        await task.value
        #expect(coordinator.canFinishClosing)
    }

    @Test func ownedIntentPreStartCancellationPublishesBeforeIdle() async {
        let coordinator = ProjectPackageCoordinator()
        var events: [String] = []
        let task = coordinator.startIntent { _ in
            events.append("ran")
        } onFailure: { error in
            #expect(error is CancellationError)
            #expect(!coordinator.canFinishClosing)
            events.append("cancelled")
        }
        task.cancel()
        coordinator.beginClosing()
        #expect(!coordinator.canFinishClosing)
        await coordinator.waitUntilIdle()
        events.append("idle")
        await task.value
        #expect(events == ["cancelled", "idle"])
        #expect(coordinator.canFinishClosing)
    }

    @Test func ownedIntentCancellationDrainsAwaitedCleanupAndFailurePublication() async {
        let coordinator = ProjectPackageCoordinator()
        let entered = IntentTestSignal()
        let cancellation = IntentTestSignal()
        let cleaning = IntentTestSignal()
        let finishCleanup = IntentTestSignal()
        var events: [String] = []
        let task = coordinator.startIntent { lease in
            entered.signal()
            await cancellation.wait()
            do {
                try Task.checkCancellation()
            } catch {
                cleaning.signal()
                await finishCleanup.wait()
                try coordinator.validate(lease)
                events.append("cleanup")
                throw error
            }
        } onFailure: { error in
            #expect(error is CancellationError)
            events.append("cancelled")
        }
        await entered.wait()
        task.cancel()
        coordinator.beginClosing()
        cancellation.signal()
        await cleaning.wait()
        #expect(events.isEmpty)
        #expect(!coordinator.canFinishClosing)
        finishCleanup.signal()
        await coordinator.waitUntilIdle()
        events.append("idle")
        await task.value
        #expect(events == ["cleanup", "cancelled", "idle"])
        #expect(coordinator.canFinishClosing)
    }

    @Test func ownedIntentRefusalDoesNotReadmitAfterReopening() async throws {
        let coordinator = ProjectPackageCoordinator()
        var ran = false
        var failures = 0
        let close = try #require(coordinator.beginClosing())
        let task = coordinator.startIntent { _ in ran = true } onFailure: { error in
            #expect(error is CancellationError)
            failures += 1
        }
        coordinator.cancelClosing(close)
        await task.value
        #expect(!ran)
        #expect(failures == 1)
        coordinator.beginClosing()
        #expect(coordinator.canFinishClosing)
    }

    @Test func ownedIntentExplicitReservationSurvivesParentScopeEnding() async throws {
        let coordinator = ProjectPackageCoordinator()
        var ran = false
        let task = try await coordinator.withIntent { _ in
            coordinator.startIntent { lease in
                try coordinator.validate(lease)
                try await coordinator.withIntent { nested in try coordinator.validate(nested) }
                try await coordinator.withMutation { _ in ran = true }
            } onFailure: { Issue.record($0) }
        }
        coordinator.beginClosing()
        #expect(!coordinator.canFinishClosing)
        await task.value
        #expect(ran)
        #expect(coordinator.canFinishClosing)
    }

    @Test(arguments: [false, true], [false, true])
    func ownedMutationSurvivesInitiatingIntentAndDrainsTerminalPublication(queued: Bool, closingBeforeRegistration: Bool) async throws {
        let coordinator = ProjectPackageCoordinator()
        var save: ProjectPackageCoordinator.SaveLease?
        var close: ProjectPackageCoordinator.CloseLease?
        if queued { coordinator.enqueueSave { save = $0 } }
        var events: [String] = []
        let task = try await coordinator.withIntent { _ in
            if closingBeforeRegistration { close = coordinator.beginClosing() }
            return coordinator.startMutation { lease in
                try coordinator.validate(lease)
                try await coordinator.withIntent { intent in try coordinator.validate(intent) }
                events.append("published")
            } onFailure: { error in
                Issue.record(error)
                events.append("failed")
            }
        }
        let owner = try #require(close ?? coordinator.beginClosing())
        #expect(!coordinator.canFinishClosing)
        if let save { coordinator.finishSave(save) {} }
        try await coordinator.waitUntilIdle(for: owner)
        events.append("idle")
        await task.value
        #expect(events == ["published", "idle"])
        #expect(coordinator.canFinishClosing)
    }

    @Test(arguments: [false, true])
    func ownedMutationCancellationAfterParentEndsPublishesOnceAndReleasesReservation(queued: Bool) async throws {
        let coordinator = ProjectPackageCoordinator()
        var save: ProjectPackageCoordinator.SaveLease?
        if queued { coordinator.enqueueSave { save = $0 } }
        var failures = 0
        let task = try await coordinator.withIntent { _ in
            coordinator.startMutation { _ in Issue.record("Cancelled mutation ran") } onFailure: { error in
                #expect(error is CancellationError)
                #expect(!coordinator.canFinishClosing)
                failures += 1
            }
        }
        task.cancel()
        let close = try #require(coordinator.beginClosing())
        if let save { coordinator.finishSave(save) {} }
        try await coordinator.waitUntilIdle(for: close)
        await task.value
        #expect(failures == 1)
        #expect(coordinator.canFinishClosing)
    }

    @Test func ownedMutationRetainsCleanupAndFailureAfterParentEnds() async throws {
        let coordinator = ProjectPackageCoordinator()
        let entered = IntentTestSignal()
        let proceed = IntentTestSignal()
        let cleaning = IntentTestSignal()
        let finish = IntentTestSignal()
        var events: [String] = []
        let task = try await coordinator.withIntent { _ in
            coordinator.startMutation { lease in
                entered.signal()
                await proceed.wait()
                do { try Task.checkCancellation() } catch {
                    cleaning.signal()
                    await finish.wait()
                    try coordinator.validate(lease)
                    events.append("cleanup")
                    throw error
                }
            } onFailure: { error in
                #expect(error is CancellationError)
                events.append("failed")
            }
        }
        await entered.wait()
        task.cancel()
        let close = try #require(coordinator.beginClosing())
        proceed.signal()
        await cleaning.wait()
        #expect(!coordinator.canFinishClosing)
        #expect(events.isEmpty)
        finish.signal()
        try await coordinator.waitUntilIdle(for: close)
        events.append("idle")
        await task.value
        #expect(events == ["cleanup", "failed", "idle"])
    }

    @Test func explicitScopeRejectsExpiredInheritedContextAndReleasesItsReservation() async throws {
        let coordinator = ProjectPackageCoordinator()
        let reserved = try coordinator.admitIntent()
        let proceed = IntentTestSignal()
        var ran = false
        let child = try await coordinator.withIntent { _ in
            Task {
                await proceed.wait()
                try await coordinator.withIntent(reserved) { _ in ran = true }
            }
        }
        proceed.signal()
        await #expect(throws: CancellationError.self) { try await child.value }
        #expect(!ran)
        coordinator.beginClosing()
        #expect(coordinator.canFinishClosing)
    }

    @Test func foreignExplicitLeaseRefusesWithoutReleasingItsOwner() async throws {
        let projectA = ProjectPackageCoordinator()
        let projectB = ProjectPackageCoordinator()
        let lease = try projectA.admitIntent()
        #expect(throws: CancellationError.self) { try projectB.validate(lease) }
        await #expect(throws: CancellationError.self) {
            try await projectB.withIntent(lease) { _ in Issue.record("Foreign lease ran") }
        }
        try projectA.validate(lease)
        projectA.finishIntent(lease)
        projectA.beginClosing()
        projectB.beginClosing()
        #expect(projectA.canFinishClosing)
        #expect(projectB.canFinishClosing)
    }

    @Test func ownedMutationQueuedBeforeSchedulingCannotCrossCloseAndReopen() async throws {
        let coordinator = ProjectPackageCoordinator()
        var save: ProjectPackageCoordinator.SaveLease?
        coordinator.enqueueSave { save = $0 }
        var ran = false
        var failures = 0
        let task = coordinator.startMutation { _ in ran = true } onFailure: { error in
            #expect(error is CancellationError)
            failures += 1
        }
        let close = try #require(coordinator.beginClosing())
        coordinator.cancelClosing(close)
        coordinator.finishSave(try #require(save)) {}
        await task.value
        #expect(!ran)
        #expect(failures == 1)
        coordinator.beginClosing()
        #expect(coordinator.canFinishClosing)
    }

    @Test func ownedMutationFromAdmittedIntentCanQueueDuringClosing() async throws {
        let coordinator = ProjectPackageCoordinator()
        var save: ProjectPackageCoordinator.SaveLease?
        var ran = false
        try await coordinator.withIntent { _ in
            coordinator.enqueueSave { save = $0 }
            coordinator.beginClosing()
            let task = coordinator.startMutation { lease in
                try coordinator.validate(lease)
                ran = true
            } onFailure: { Issue.record($0) }
            coordinator.finishSave(try #require(save)) {}
            await task.value
        }
        #expect(ran)
        #expect(coordinator.canFinishClosing)
    }

    @Test func ownedMutationCancellationKeepsFailurePublicationInsideSaveFence() async {
        let coordinator = ProjectPackageCoordinator()
        var status = "preparing"
        var savedStatus: String?
        var failures = 0
        let task = coordinator.startMutation { _ in Issue.record("Cancelled mutation ran") } onFailure: { error in
            #expect(error is CancellationError)
            failures += 1
            status = "cancelled"
        }
        task.cancel()
        coordinator.enqueueSave { lease in
            savedStatus = status
            coordinator.finishSave(lease) {}
        }
        coordinator.beginClosing()
        await task.value
        #expect(failures == 1)
        #expect(savedStatus == "cancelled")
        #expect(coordinator.canFinishClosing)
    }
}
