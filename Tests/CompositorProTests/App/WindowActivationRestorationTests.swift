import AppKit
import Testing
@testable import CompositorPro

@Suite("Deferred window activation restoration")
@MainActor
struct WindowActivationRestorationTests {
    @MainActor
    private final class Fixture {
        var scheduled: [@MainActor @Sendable () -> Void] = []
        var eligible = true
        var restoredModes: [Bool] = []
        lazy var restoration = WindowActivationRestoration(
            schedule: { [weak self] in self?.scheduled.append($0) },
            canRestore: { [weak self] in self?.eligible == true },
            restore: { [weak self] in self?.restoredModes.append($0) }
        )
        lazy var delegate = AppDelegate(windowActivationRestoration: restoration)

        func finishNativeActivation() {
            let callbacks = scheduled
            scheduled.removeAll()
            callbacks.forEach { $0() }
        }
    }

    @Test func restorationWaitsForNativeActivationToFinish() {
        let fixture = Fixture()

        fixture.delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))

        #expect(fixture.restoredModes.isEmpty)
        fixture.finishNativeActivation()
        #expect(fixture.restoredModes == [false])
    }

    @Test(arguments: [false, true])
    func dockReopenAndActivationKeepTheMinimizedWindowRequest(dockFirst: Bool) {
        let fixture = Fixture()

        fixture.restoration.request(restoringMinimizedWindows: dockFirst)
        fixture.restoration.request(restoringMinimizedWindows: !dockFirst)
        fixture.finishNativeActivation()

        #expect(fixture.restoredModes == [true])
    }

    @Test func repeatedActivationRestoresOnce() {
        let fixture = Fixture()

        fixture.restoration.request(restoringMinimizedWindows: false)
        fixture.restoration.request(restoringMinimizedWindows: false)
        fixture.finishNativeActivation()

        #expect(fixture.restoredModes == [false])
    }

    @Test(arguments: [false, true])
    func switchingAwayCancelsPendingRestoration(afterDeferredCallback: Bool) {
        let fixture = Fixture()
        fixture.eligible = false

        fixture.restoration.request(restoringMinimizedWindows: true)
        if afterDeferredCallback { fixture.finishNativeActivation() }
        fixture.delegate.applicationWillResignActive(Notification(name: NSApplication.willResignActiveNotification))
        fixture.eligible = true
        fixture.finishNativeActivation()

        #expect(fixture.restoredModes.isEmpty)
        fixture.delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        fixture.finishNativeActivation()
        #expect(fixture.restoredModes == [false])
    }

    @Test func oldActivationCannotConsumeANewerRequest() {
        let fixture = Fixture()

        fixture.restoration.request(restoringMinimizedWindows: true)
        fixture.delegate.applicationWillResignActive(Notification(name: NSApplication.willResignActiveNotification))
        fixture.delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        fixture.finishNativeActivation()

        #expect(fixture.restoredModes == [false])
    }

    @Test func eligibilityIsCheckedAfterNativeActivation() {
        let fixture = Fixture()

        fixture.restoration.request(restoringMinimizedWindows: false)
        fixture.eligible = false
        fixture.finishNativeActivation()
        #expect(fixture.restoredModes.isEmpty)

        fixture.eligible = true
        fixture.restoration.request(restoringMinimizedWindows: false)
        fixture.finishNativeActivation()
        #expect(fixture.restoredModes == [false])
    }

    @Test func dockRequestSurvivesActivationCompletingAfterTheDeferredCallback() {
        let fixture = Fixture()
        fixture.eligible = false

        fixture.restoration.request(restoringMinimizedWindows: true)
        fixture.finishNativeActivation()
        #expect(fixture.restoredModes.isEmpty)

        fixture.eligible = true
        fixture.delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        fixture.finishNativeActivation()

        #expect(fixture.restoredModes == [true])
    }

    @Test func terminationCancelsPendingRestorationAndRejectsActivation() async {
        let fixture = Fixture()
        let finished = PackageTestSignal()
        fixture.delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))

        fixture.delegate.startTermination(
            projects: [],
            prepareServices: { _ in },
            didClose: {},
            onError: { Issue.record("Unexpected termination failure: \($0)") },
            sendReply: {
                #expect($0)
                finished.signal()
            }
        )
        fixture.finishNativeActivation()
        fixture.delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        fixture.finishNativeActivation()

        #expect(fixture.restoredModes.isEmpty)
        await finished.wait()
    }
}
