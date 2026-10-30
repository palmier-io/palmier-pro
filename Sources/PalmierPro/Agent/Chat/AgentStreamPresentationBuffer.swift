import Foundation

// Coalesces token deltas off-main so streamed chat cannot saturate SwiftUI layout.
struct AgentStreamSnapshot: Sendable {
    let blocks: [AgentContentBlock]
    let stopReason: AgentStopReason
    let revision: UInt64
}

private struct AgentStreamReducer: Sendable {
    private(set) var blocks: [AgentContentBlock] = []
    private(set) var stopReason: AgentStopReason = .endTurn
    private let model: AgentModel

    init(model: AgentModel) {
        self.model = model
    }

    @discardableResult
    mutating func apply(_ event: AgentStreamEvent) -> Bool {
        switch event {
        case .thinkingDelta(let chunk):
            updateThinking(textDelta: chunk)
        case .thinkingSignature(let signature):
            updateThinking(signatureDelta: signature)
        case .redactedThinking(let data):
            blocks.append(.redactedThinking(data: data))
        case .reasoningSummaryDelta(let chunk):
            let existing = takeStreamingReasoningSummary()
            blocks.append(.openAIReasoning(
                summary: existing + chunk,
                encryptedContent: "",
                itemID: nil,
                model: model
            ))
        case .reasoningComplete(let itemID, let summary, let encryptedContent):
            let existing = takeStreamingReasoningSummary()
            blocks.append(.openAIReasoning(
                summary: summary.isEmpty ? existing : summary,
                encryptedContent: encryptedContent,
                itemID: itemID,
                model: model
            ))
        case .textDelta(let chunk):
            if case .text(let existing)? = blocks.last {
                blocks[blocks.count - 1] = .text(existing + chunk)
            } else {
                blocks.append(.text(chunk))
            }
        case .toolUseComplete(let id, let name, let inputJSON):
            blocks.append(.toolUse(id: id, name: name, inputJSON: inputJSON))
        case .messageStop(let reason):
            stopReason = reason
            return false
        }
        return true
    }

    private mutating func updateThinking(
        textDelta: String = "",
        signatureDelta: String = ""
    ) {
        if case .thinking(let text, let signature)? = blocks.last {
            blocks[blocks.count - 1] = .thinking(
                text: text + textDelta,
                signature: signature + signatureDelta
            )
        } else {
            blocks.append(.thinking(text: textDelta, signature: signatureDelta))
        }
    }

    private mutating func takeStreamingReasoningSummary() -> String {
        guard case .openAIReasoning(let summary, _, _, let existingModel)? = blocks.last,
              existingModel == model else { return "" }
        blocks.removeLast()
        return summary
    }
}

actor AgentStreamPresentationBuffer {
    private var reducer: AgentStreamReducer
    private var revision: UInt64 = 0
    private var isDirty = false
    private var hasPublished = false
    private var isComplete = false
    private var continuation: AsyncThrowingStream<AgentStreamSnapshot, Error>.Continuation?
    private var timerTask: Task<Void, Never>?

    init(model: AgentModel) {
        reducer = AgentStreamReducer(model: model)
    }

    func snapshots() -> AsyncThrowingStream<AgentStreamSnapshot, Error> {
        precondition(continuation == nil)
        var captured: AsyncThrowingStream<AgentStreamSnapshot, Error>.Continuation?
        let stream = AsyncThrowingStream(
            bufferingPolicy: .bufferingNewest(1)
        ) { continuation in
            captured = continuation
        }
        continuation = captured
        return stream
    }

    func receive(_ event: AgentStreamEvent) {
        guard !isComplete else { return }
        guard reducer.apply(event) else { return }
        revision &+= 1
        isDirty = true
        if !hasPublished {
            publish()
        }
        scheduleIfNeeded()
    }

    @discardableResult
    func complete(throwing error: (any Error)? = nil) -> AgentStreamSnapshot {
        if !isComplete {
            isComplete = true
            timerTask?.cancel()
            timerTask = nil
            publish()
            if let error {
                continuation?.finish(throwing: error)
            } else {
                continuation?.finish()
            }
        }
        return snapshot
    }

    var snapshot: AgentStreamSnapshot {
        AgentStreamSnapshot(
            blocks: reducer.blocks,
            stopReason: reducer.stopReason,
            revision: revision
        )
    }

    private func scheduleIfNeeded() {
        guard timerTask == nil, !isComplete else { return }
        timerTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.timerFired()
        }
    }

    private func timerFired() {
        timerTask = nil
        publish()
    }

    private func publish() {
        guard isDirty else { return }
        isDirty = false
        hasPublished = true
        continuation?.yield(snapshot)
    }
}

func presentAgentStream(
    _ source: AsyncThrowingStream<AgentStreamEvent, Error>,
    model: AgentModel,
    onSnapshot: @escaping @Sendable (AgentStreamSnapshot) async -> Void
) async throws -> AgentStreamSnapshot {
    let buffer = AgentStreamPresentationBuffer(model: model)
    let snapshots = await buffer.snapshots()
    let producer = Task.detached {
        do {
            for try await event in source {
                try Task.checkCancellation()
                await buffer.receive(event)
            }
            await buffer.complete()
        } catch {
            await buffer.complete(throwing: error)
        }
    }
    var lastRevision: UInt64 = 0

    do {
        for try await snapshot in snapshots {
            guard snapshot.revision != lastRevision else { continue }
            await onSnapshot(snapshot)
            lastRevision = snapshot.revision
        }
        if Task.isCancelled {
            throw CancellationError()
        }
    } catch {
        producer.cancel()
        await producer.value
        let final = await buffer.complete()
        if final.revision != lastRevision {
            await onSnapshot(final)
        }
        throw error
    }

    await producer.value
    let final = await buffer.complete()
    if final.revision != lastRevision {
        await onSnapshot(final)
    }
    return final
}
