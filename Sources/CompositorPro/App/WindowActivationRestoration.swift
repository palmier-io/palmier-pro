import Foundation

@MainActor
final class WindowActivationRestoration {
    typealias Schedule = @MainActor (@escaping @MainActor @Sendable () -> Void) -> Void

    private let schedule: Schedule
    private let canRestore: () -> Bool
    private let restore: (Bool) -> Void
    private var scheduledID: UUID?
    private var restoringMinimizedWindows = false

    init(
        schedule: @escaping Schedule = { action in
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated { action() }
            }
        },
        canRestore: @escaping () -> Bool,
        restore: @escaping (Bool) -> Void
    ) {
        self.schedule = schedule
        self.canRestore = canRestore
        self.restore = restore
    }

    func request(restoringMinimizedWindows: Bool) {
        self.restoringMinimizedWindows = self.restoringMinimizedWindows || restoringMinimizedWindows
        guard scheduledID == nil else { return }

        let id = UUID()
        scheduledID = id
        // Defer window ordering until AppKit returns from the activation callback.
        schedule { [weak self] in
            guard let self, self.scheduledID == id else { return }
            self.scheduledID = nil
            // Keep Dock intent until a later activation request can restore it.
            guard self.canRestore() else { return }
            let restoringMinimizedWindows = self.restoringMinimizedWindows
            self.restoringMinimizedWindows = false
            self.restore(restoringMinimizedWindows)
        }
    }

    func cancel() {
        scheduledID = nil
        restoringMinimizedWindows = false
    }
}
