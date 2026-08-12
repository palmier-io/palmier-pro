import Foundation
import Observation

@MainActor @Observable
final class OnboardingStore {
    /// Inherited from the pre-survey welcome overlay so existing installs stay onboarded.
    static let completionKey = "hasSeenWelcome"
    static let shared = OnboardingStore()

    private static let surveyVersion = 2

    private(set) var step = OnboardingStep.welcome
    private(set) var isComplete: Bool
    private(set) var selections: [OnboardingQuestion: Set<String>] = [:]
    private(set) var sampleState: OnboardingSampleState = .idle

    private let defaults: UserDefaults
    private var didCaptureSurvey = false
    private var sampleTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isComplete = defaults.bool(forKey: Self.completionKey)
    }

    func advance() {
        move(by: 1)
    }

    func goBack() {
        move(by: -1)
    }

    /// Reports the survey once, no matter how often the user steps back.
    func submitSurvey() {
        if !didCaptureSurvey {
            didCaptureSurvey = true
            Analytics.capture(.onboardingCompleted, properties: [
                "survey_version": Self.surveyVersion,
                "roles": selection(for: .roles).sorted(),
                "video_types": selection(for: .videoTypes).sorted(),
                "interests": selection(for: .interests).sorted(),
                "acquisition_source": selection(for: .acquisitionSource).sorted().first ?? "not_provided",
                "previous_editors": selection(for: .previousEditors).sorted(),
            ])
        }
        advance()
    }

    func complete() {
        defaults.set(true, forKey: Self.completionKey)
        isComplete = true
    }

    func skip() {
        sampleTask?.cancel()
        sampleTask = nil
        sampleState = .idle
        complete()
    }

    func selection(for question: OnboardingQuestion) -> Set<String> {
        selections[question, default: []]
    }

    func toggle(_ option: OnboardingOption, for question: OnboardingQuestion) {
        var selection = selection(for: question)

        if !question.allowsMultipleSelection {
            selections[question] = selection.contains(option.id) ? [] : [option.id]
            return
        }

        if question.exclusiveOptionIDs.contains(option.id) {
            selections[question] = selection == [option.id] ? [] : [option.id]
            return
        }

        selection.subtract(question.exclusiveOptionIDs)
        if selection.contains(option.id) {
            selection.remove(option.id)
        } else {
            selection.insert(option.id)
        }
        selections[question] = selection
    }

    /// Owned here rather than by the overlay so onboarding still completes once Home is torn down.
    func openSampleProject() {
        guard sampleTask == nil else { return }
        sampleState = .loading
        sampleTask = Task {
            defer { sampleTask = nil }
            do {
                guard let sample = try await SampleProjectService.shared.fetchSamples().first else {
                    sampleState = .failed
                    return
                }
                try Task.checkCancellation()
                try await AppState.shared.openSample(slug: sample.slug, startTutorial: true)
                try Task.checkCancellation()
                complete()
            } catch is CancellationError {
                sampleState = .idle
            } catch {
                Log.app.error("onboarding sample failed to open: \(error.localizedDescription)")
                sampleState = .failed
            }
        }
    }

    private func move(by offset: Int) {
        guard let destination = OnboardingStep(rawValue: step.rawValue + offset) else { return }
        step = destination
    }
}
