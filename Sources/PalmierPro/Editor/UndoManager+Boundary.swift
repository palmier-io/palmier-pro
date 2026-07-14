import Foundation

@MainActor
private final class UndoBoundaryWaiter: NSObject {
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }

    @objc func resume() { continuation?.resume(); continuation = nil }
}

extension UndoManager {
    private static let agentSessionKey = UserInfoKey(rawValue: "io.palmier.agent.session")

    /// True once Foundation's automatic per-event group is closed; bounded to one run-loop pass.
    @MainActor
    func awaitTopLevelUndoBoundary() async -> Bool {
        guard groupingLevel > 0 else { return true }
        await withCheckedContinuation { continuation in
            let waiter = UndoBoundaryWaiter(continuation)
            // Runs after Foundation's NSUndoCloseGroupingRunLoopOrdering observer.
            RunLoop.main.perform(
                #selector(UndoBoundaryWaiter.resume),
                target: waiter,
                argument: nil,
                order: NSUndoCloseGroupingRunLoopOrdering + 1,
                modes: runLoopModes
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { waiter.resume() }
        }
        return groupingLevel == 0
    }

    /// One top-level named group; suspends per-event grouping while open, never closes a group it didn't begin.
    @MainActor
    func withTopLevelGroup<T>(actionName: String, sessionID: String, _ work: () throws -> T) throws -> T {
        guard groupingLevel == 0 else { throw UndoBoundaryError.actionInProgress }
        let restoresEventGrouping = groupsByEvent
        if restoresEventGrouping { groupsByEvent = false }
        beginUndoGrouping()
        defer {
            if undoActionName != actionName { setActionName(actionName) }
            setActionUserInfoValue(sessionID, forKey: Self.agentSessionKey)
            endUndoGrouping()
            if restoresEventGrouping { groupsByEvent = true }
        }
        return try work()
    }

    @MainActor
    var topAgentSessionID: String? {
        undoActionUserInfoValue(forKey: Self.agentSessionKey) as? String
    }
}

enum UndoBoundaryError: LocalizedError {
    case actionInProgress

    var errorDescription: String? { "An editor action is in progress. Try again." }
}
