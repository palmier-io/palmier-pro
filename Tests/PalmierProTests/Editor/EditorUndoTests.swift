import Foundation
import Testing
@testable import PalmierPro

@MainActor
private final class UndoCounter {
    var value = 0
}

@MainActor
private func setCounter(_ value: Int, actionName: String, counter: UndoCounter, undo: EditorUndo) {
    let previous = counter.value
    counter.value = value
    undo.register(actionName, withTarget: counter) { target in
        setCounter(previous, actionName: actionName, counter: target, undo: undo)
    }
}

@MainActor
@Suite("EditorUndo")
struct EditorUndoTests {
    private enum ExpectedError: Error { case expected }

    private func harness() -> (EditorUndo, UndoManager, UndoCounter) {
        let undo = EditorUndo()
        let manager = UndoManager()
        let counter = UndoCounter()
        undo.attach(manager)
        return (undo, manager, counter)
    }

    @Test func directRegistrationsAreSeparateBalancedGroups() {
        let (undo, manager, counter) = harness()

        setCounter(1, actionName: "First", counter: counter, undo: undo)
        setCounter(2, actionName: "Second", counter: counter, undo: undo)

        #expect(manager.groupsByEvent)
        #expect(manager.groupingLevel == 0)
        #expect(manager.undoActionName == "Second")
        undo.perform("No-op") {}
        #expect(manager.undoActionName == "Second")
        #expect(undo.undoLatest() == "Second")
        #expect(counter.value == 1)
        #expect(undo.undoLatest() == "First")
        #expect(counter.value == 0)
        manager.redo()
        #expect(counter.value == 1)
    }

    @Test func transactionPreservesExistingGroup() {
        let (undo, manager, counter) = harness()
        let textStorage = UndoCounter()
        manager.registerUndo(withTarget: textStorage) { _ in }
        let initialGroupingLevel = manager.groupingLevel

        setCounter(1, actionName: "Set", counter: counter, undo: undo)

        #expect(initialGroupingLevel > 0)
        #expect(manager.groupingLevel == initialGroupingLevel)
    }

    @Test func nestedTransactionsProduceOneUndoStep() {
        let (undo, manager, first) = harness()
        let second = UndoCounter()

        undo.perform("Outer") {
            setCounter(1, actionName: "First", counter: first, undo: undo)
            undo.perform("Inner") {
                setCounter(2, actionName: "Second", counter: second, undo: undo)
            }
        }

        #expect(manager.groupingLevel == 0)
        #expect(manager.undoActionName == "Outer")
        #expect(undo.undoLatest() == "Outer")
        #expect(first.value == 0)
        #expect(second.value == 0)
        #expect(manager.canUndo == false)
        #expect(manager.redoActionName == "Outer")
        manager.redo()
        #expect(manager.undoActionName == "Outer")
    }

    @Test func throwingScopesRestoreUndoState() {
        let (undo, manager, counter) = harness()

        #expect(throws: ExpectedError.self) {
            try undo.perform("Throwing") {
                setCounter(1, actionName: "Set", counter: counter, undo: undo)
                throw ExpectedError.expected
            }
        }
        #expect(manager.groupingLevel == 0)
        _ = undo.undoLatest()
        #expect(counter.value == 0)
        manager.removeAllActions()

        #expect(throws: ExpectedError.self) {
            try undo.withoutRegistration {
                setCounter(1, actionName: "Suppressed", counter: counter, undo: undo)
                throw ExpectedError.expected
            }
        }
        #expect(undo.isRegistrationEnabled)
        #expect(manager.groupingLevel == 0)
        #expect(manager.canUndo == false)
    }
}
