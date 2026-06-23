import Foundation

enum FeatureAvailability: Equatable {
    case available
    case unavailable(reason: String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    var unavailableReason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

enum FeatureGate {
    static var isOfficialFullBuild: Bool { !BuildMode.isEditorOnly }
    static var isExperimentalIntelEditorOnly: Bool { BuildMode.isEditorOnly }

    static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    static var isIntel: Bool {
        #if arch(x86_64)
        return true
        #else
        return false
        #endif
    }

    static var isMacOS26OrNewer: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    static var palmierBackendAuth: FeatureAvailability {
        editorOnlyUnavailable(reason: "Account/login requires Palmier backend support.")
    }

    static var cloudSync: FeatureAvailability {
        editorOnlyUnavailable(reason: "Cloud sync requires Convex and Clerk support.")
    }

    static var hostedAIGeneration: FeatureAvailability {
        editorOnlyUnavailable(reason: "Hosted AI generation requires Palmier auth, credits, and the hosted model catalog.")
    }

    static var hostedModelCatalog: FeatureAvailability {
        editorOnlyUnavailable(reason: "The hosted model catalog requires Convex backend support.")
    }

    static var transcription: FeatureAvailability {
        #if PALMIER_EDITOR_ONLY
        return editorOnlyUnavailable(reason: "Advanced transcription requires macOS 26 Speech APIs or a configured fallback provider.")
        #else
        if #available(macOS 26.0, *) { return .available }
        return .unavailable(reason: "Advanced transcription requires macOS 26 Speech APIs.")
        #endif
    }

    static var feedbackSubmission: FeatureAvailability {
        editorOnlyUnavailable(reason: "Feedback submission requires Palmier backend support.")
    }

    static var officialUpdateChecks: FeatureAvailability {
        editorOnlyUnavailable(reason: "Experimental Intel artifacts are not connected to the official Palmier update feed.")
    }

    private static func editorOnlyUnavailable(reason: String) -> FeatureAvailability {
        #if PALMIER_EDITOR_ONLY
        return .unavailable(reason: "\(BuildMode.editorOnlyUnavailableMessage) \(reason)")
        #else
        return .available
        #endif
    }
}
