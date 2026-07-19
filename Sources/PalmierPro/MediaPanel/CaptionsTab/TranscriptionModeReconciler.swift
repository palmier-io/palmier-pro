// Reconciles the caption tab's local/cloud Mode radio with the project's persisted
// transcriptionPreference so one control drives both the manual Generate button and Agent captioning.
// Pure mapping, kept out of the view so it can be tested directly.

import Foundation

enum TranscriptionModeReconciler {
    /// The concrete provider the radio shows for a persisted preference. `auto` resolves to cloud when
    /// the account can reach it (its runtime pick), else local — for display only; picking persists.
    static func provider(for preference: TranscriptionPreference, canUseCloud: Bool) -> TranscriptionProvider {
        switch preference {
        case .local: .local
        case .cloud: .cloud
        case .auto: canUseCloud ? .cloud : .local
        }
    }

    /// The preference persisted when the user actively picks a radio provider. `auto` only exists as an
    /// initial/reset state; a deliberate pick collapses it to a concrete value.
    static func preference(for provider: TranscriptionProvider) -> TranscriptionPreference {
        switch provider {
        case .local: .local
        case .cloud: .cloud
        }
    }
}
