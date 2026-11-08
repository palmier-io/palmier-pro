import Foundation
import Observation

@Observable
@MainActor
final class CaptionGenerationController {
    enum Mode { case captions, transcript }
    enum Output {
        case captions([String])
        case transcript(EditorViewModel.TimelineTranscriptDocument)
    }

    private(set) var isGenerating = false
    var note: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var requestId: UUID?

    func start(
        in editor: EditorViewModel,
        request: EditorViewModel.CaptionRequest,
        mode: Mode,
        onCompletion: @escaping @MainActor (Output) -> Void
    ) {
        guard task == nil else { return }
        let id = UUID()
        requestId = id
        note = nil
        isGenerating = true
        let context = editor.captionPreparationContext(for: request)
        task = editor.projectPackageCoordinator.startIntent { lease in
            try context.validate(in: editor)
            if request.provider == .cloud {
                if let message = self.cloudUnavailableMessage(cost: nil) {
                    self.finish(id, note: message)
                    return
                }
                let cost = await editor.captionCloudCreditCost(for: request)
                try context.validate(in: editor)
                if let message = self.cloudUnavailableMessage(cost: cost) {
                    self.finish(id, note: message)
                    return
                }
            }
            let output: Output
            let isEmpty: Bool
            switch mode {
            case .captions:
                let ids = try await editor.generateCaptions(for: request)
                output = .captions(ids)
                isEmpty = ids.isEmpty
            case .transcript:
                let transcript = try await editor.timelineTranscript(for: request)
                output = .transcript(transcript)
                isEmpty = transcript.rows.isEmpty
            }
            try Task.checkCancellation()
            try editor.projectPackageCoordinator.validate(lease)
            guard self.requestId == id, editor.activeTimelineId == context.timelineId else {
                throw CancellationError()
            }
            self.finish(id, note: isEmpty ? L10n.string("No speech detected.") : nil)
            if !isEmpty { onCompletion(output) }
        } onFailure: { error in
            self.finish(id, note: self.localizedError(error))
        }
    }

    func cancel() {
        requestId = nil
        task?.cancel()
    }

    func waitUntilFinished() async {
        await task?.value
    }

    private func finish(_ id: UUID, note: String?) {
        if requestId == id { self.note = note }
        requestId = nil
        task = nil
        isGenerating = false
    }

    private func cloudUnavailableMessage(cost: Int?) -> String? {
        let account = AccountService.shared
        guard account.isSignedIn else { return L10n.string("Sign in to use Cloud.") }
        guard let cost, cost > 0, account.budgetCredits != nil else { return nil }
        let remaining = account.remainingCredits
        guard remaining > 0 else { return L10n.string("Add credits to use Cloud.") }
        if cost > remaining { return CostEstimator.localizedInsufficientCredits(cost, remaining: remaining) }
        return nil
    }

    private func localizedError(_ error: Error) -> String {
        if error is CancellationError { return L10n.string("Caption generation canceled.") }
        if let error = error as? EditorViewModel.CaptionError {
            switch error {
            case .noSource: return L10n.string("No audio clips to caption.")
            case .timelineChanged: return L10n.string("The timeline changed while captions were being prepared. Try again.")
            }
        }
        guard let error = error as? TranscriptionError else { return error.localizedDescription }
        switch error {
        case .unsupportedLocale(let identifier):
            return L10n.string("On-device transcription is not available for \(identifier).")
        case .modelInstallFailed(let reason):
            return L10n.string("Could not install the on-device speech model: \(reason)")
        case .decodeFailed:
            return L10n.string("Could not parse transcription result.")
        case .audioExtractionFailed(let reason):
            return L10n.string("Audio extraction failed: \(reason)")
        case .analysisFailed(let reason):
            return L10n.string("Transcription failed: \(reason)")
        }
    }
}
