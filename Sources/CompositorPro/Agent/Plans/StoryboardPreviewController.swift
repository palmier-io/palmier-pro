import AVFoundation
import Foundation
import Observation

@Observable
@MainActor
final class StoryboardPreviewController {
    private(set) var isPreparing = false
    private(set) var result: StoryboardPreviewResult?
    private(set) var player: AVPlayer?
    private(set) var measured = false
    private(set) var error: String?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var requestContext: StoryboardPreviewContext?
    @ObservationIgnored private weak var requestEditor: EditorViewModel?
    @ObservationIgnored private let render: @Sendable (StoryboardPreviewSnapshot) async throws -> StoryboardPreviewResult
    @ObservationIgnored private let remove: @Sendable (StoryboardPreviewResult) async throws -> Void
    @ObservationIgnored private let makePlayer: @Sendable (URL) async -> AVPlayer?

    init(render: @escaping @Sendable (StoryboardPreviewSnapshot) async throws -> StoryboardPreviewResult = {
        try await StoryboardPreviewService.render($0)
    }, remove: @escaping @Sendable (StoryboardPreviewResult) async throws -> Void = {
        try await StoryboardPreviewService.remove($0)
    }, makePlayer: @escaping @Sendable (URL) async -> AVPlayer? = { await StoryboardPreviewController.player(for: $0) }) {
        self.render = render
        self.remove = remove
        self.makePlayer = makePlayer
    }

    @discardableResult
    func prepare(editor: EditorViewModel, planId: String) -> Task<Void, Never> {
        let context = editor.storyboardPreviewContext(planId: planId)
        if isPreparing, requestContext == context, requestEditor === editor, let operation { return operation }
        let task = prepare(snapshot: { try await editor.storyboardPreviewSnapshot(planId: planId) },
            isCurrent: { editor.storyboardPreviewContext(planId: planId) == context })
        requestContext = context
        requestEditor = editor
        return task
    }

    @discardableResult
    func prepare(snapshot: @escaping @MainActor () async throws -> StoryboardPreviewSnapshot,
                 isCurrent: @escaping @MainActor () -> Bool) -> Task<Void, Never> {
        let previous = invalidate()
        let token = generation
        isPreparing = true
        let render = render
        let remove = remove
        let makePlayer = makePlayer
        let task = Task { [weak self] in
            await previous.value
            var output: StoryboardPreviewResult?
            var preparedPlayer: AVPlayer?
            defer {
                if let self, self.generation == token {
                    self.isPreparing = false
                    self.operation = nil
                }
            }
            do {
                try Task.checkCancellation()
                let resolved = try await snapshot()
                try Task.checkCancellation()
                guard isCurrent() else { throw StoryboardPreviewError.stale }
                let rendered = try await render(resolved)
                output = rendered
                try Task.checkCancellation()
                guard isCurrent(), self?.generation == token else { throw StoryboardPreviewError.stale }
                preparedPlayer = await makePlayer(rendered.url)
                try Task.checkCancellation()
                guard let self, self.generation == token, isCurrent() else { throw StoryboardPreviewError.stale }
                self.result = rendered
                self.player = preparedPlayer
                self.measured = resolved.measured
                output = nil
                preparedPlayer = nil
            } catch {
                if let output { await Self.dispose(player: preparedPlayer, result: output, remove: remove) }
                if error is StoryboardPreviewService.CleanupFailure {
                    Log.preview.error("Storyboard preview cleanup failed: \(error.localizedDescription)")
                }
                if let self, self.generation == token,
                   !Task.isCancelled || error is StoryboardPreviewService.CleanupFailure {
                    self.error = Self.message(for: error)
                }
            }
        }
        operation = task
        return task
    }

    @discardableResult
    func invalidate() -> Task<Void, Never> {
        generation = UUID()
        let previous = operation
        previous?.cancel()
        let player = player
        let result = result
        let remove = remove
        self.player = nil
        self.result = nil
        isPreparing = false
        measured = false
        error = nil
        requestContext = nil
        requestEditor = nil
        let task = Task {
            await previous?.value
            await Self.dispose(player: player, result: result, remove: remove)
        }
        operation = task
        return task
    }

    isolated deinit {
        let previous = operation
        previous?.cancel()
        let player = player
        let result = result
        let remove = remove
        Task {
            await previous?.value
            await Self.dispose(player: player, result: result, remove: remove)
        }
    }

    @concurrent private static func player(for url: URL) async -> AVPlayer {
        AVPlayer(url: url)
    }

    private static func message(for error: any Error) -> String {
        if let error = error as? StoryboardPreviewError { return error.userMessage }
        if let error = error as? StoryboardPreviewService.CleanupFailure {
            return L10n.string("\(message(for: error.operationError)) Preview cleanup failed: \(error.cleanupError.localizedDescription)")
        }
        return error.localizedDescription
    }

    @concurrent private static func dispose(player: AVPlayer?, result: StoryboardPreviewResult?,
                                           remove: @Sendable (StoryboardPreviewResult) async throws -> Void) async {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        guard let result else { return }
        do { try await remove(result) }
        catch { Log.preview.error("Storyboard preview cleanup failed: \(error.localizedDescription)") }
    }
}

extension StoryboardPreviewError {
    @MainActor var userMessage: String {
        switch self {
        case .emptyStoryboard: L10n.string("Add scenes before previewing the storyboard.")
        case .unsupportedLayout: L10n.string("Preview requires consecutive scenes starting at frame zero, without gaps or overlaps.")
        case .unresolvedTiming: L10n.string("Resolve scene source timing or measure the current narration before previewing.")
        case .unavailableSource: L10n.string("Relink missing sources or wait for media preparation, then preview again.")
        case .unsupportedSource: L10n.string("Preview supports still images, opaque video, and measured narration. Render other visual types before previewing.")
        case .sourceMismatch: L10n.string("Source contents or duration changed. Revise the source selection or measure narration again.")
        case .renderIncomplete: L10n.string("Preview could not render every scene and narration range exactly.")
        case .tooLong: L10n.string("Storyboard preview supports up to 30 minutes.")
        case .stale: L10n.string("Storyboard, project, or media changed. Preview the current storyboard again.")
        case .canceled: L10n.string("Storyboard preview canceled.")
        }
    }
}
