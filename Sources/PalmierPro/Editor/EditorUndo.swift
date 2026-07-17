import Foundation

@MainActor
final class EditorUndo {
    private weak var manager: UndoManager?
    private let localizeActionName: (String) -> String
    private var transactionActive = false
    private var transactionGroupOpened = false

    init(localizeActionName: @escaping (String) -> String = { L10n.string($0) }) {
        self.localizeActionName = localizeActionName
    }

    func attach(_ manager: UndoManager?) {
        self.manager = manager
    }

    func perform<T>(_ actionName: String, _ work: () throws -> T) rethrows -> T {
        guard let manager, !manager.isUndoing, !manager.isRedoing else {
            return try work()
        }
        guard !transactionActive else { return try work() }

        let initialGroupingLevel = manager.groupingLevel
        // Prevent Foundation from wrapping an explicit editor transaction in an event group.
        let restoresEventGrouping = manager.groupsByEvent && initialGroupingLevel == 0
        if restoresEventGrouping { manager.groupsByEvent = false }
        transactionActive = true
        transactionGroupOpened = false
        defer {
            let groupOpened = transactionGroupOpened
            transactionActive = false
            transactionGroupOpened = false
            if groupOpened {
                let localizedActionName = localizeActionName(actionName)
                manager.setActionName(localizedActionName)
                manager.endUndoGrouping()
            }
            if restoresEventGrouping { manager.groupsByEvent = true }
            assert(manager.groupingLevel == initialGroupingLevel)
        }
        return try work()
    }

    func register<Target: AnyObject>(
        _ actionName: String,
        withTarget target: Target,
        handler: @escaping @MainActor (Target) -> Void
    ) {
        guard let manager, manager.isUndoRegistrationEnabled else { return }
        if !transactionActive, !manager.isUndoing, !manager.isRedoing {
            perform(actionName) { register(actionName, withTarget: target, handler: handler) }
            return
        }
        if transactionActive, !transactionGroupOpened {
            manager.beginUndoGrouping()
            transactionGroupOpened = true
        }
        manager.registerUndo(withTarget: target) { target in handler(target) }
    }

    func withoutRegistration<T>(_ work: () throws -> T) rethrows -> T {
        guard let manager, manager.isUndoRegistrationEnabled else {
            return try work()
        }
        manager.disableUndoRegistration()
        defer { manager.enableUndoRegistration() }
        return try work()
    }

    var isRegistrationEnabled: Bool { manager?.isUndoRegistrationEnabled ?? true }

    @discardableResult
    func undoLatest() -> Bool {
        guard let manager, manager.canUndo else { return false }
        manager.undo()
        return true
    }

    func removeAllActions<Target: AnyObject>(withTarget target: Target) {
        manager?.removeAllActions(withTarget: target)
    }
}
