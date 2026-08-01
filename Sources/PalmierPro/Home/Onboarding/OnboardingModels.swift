import Foundation

enum OnboardingStep: Int {
    case welcome, profile, account
}

enum OnboardingSampleState: Equatable {
    case idle
    case loading
    case failed
}

struct OnboardingOption: Identifiable {
    let id: String
    let labelKey: String
    static let other = OnboardingOption(id: "other", labelKey: L10n.key("Other"))
}

enum OnboardingQuestion: String, CaseIterable, Identifiable {
    case roles, videoTypes, interests
    var id: String { rawValue }
    var titleKey: String {
        switch self {
        case .videoTypes: L10n.key("What do you make?")
        case .roles: L10n.key("What best describes your role?")
        case .interests: L10n.key("What interests you most about Palmier Pro?")
        }
    }
    var options: [OnboardingOption] {
        switch self {
        case .videoTypes: [
            .init(id: "short_form", labelKey: L10n.key("Short-form and social")),
            .init(id: "youtube", labelKey: L10n.key("YouTube")),
            .init(id: "podcast", labelKey: L10n.key("Podcast")),
            .init(id: "ai_videos", labelKey: L10n.key("AI videos")),
            .init(id: "advertising", labelKey: L10n.key("Ads and branded content")),
            .init(id: "product_demos", labelKey: L10n.key("Product demos")),
            .init(id: "education", labelKey: L10n.key("Education and tutorials")),
            .other,
        ]
        case .roles: [
            .init(id: "editor", labelKey: L10n.key("Video editor")),
            .init(id: "filmmaker", labelKey: L10n.key("Filmmaker")),
            .init(id: "hobbyist", labelKey: L10n.key("Hobbyist")),
            .init(id: "founder", labelKey: L10n.key("Founder")),
            .init(id: "designer", labelKey: L10n.key("Designer")),
            .init(id: "content_creator", labelKey: L10n.key("Content creator")),
            .init(id: "student", labelKey: L10n.key("Student")),
            .init(id: "marketer", labelKey: L10n.key("Marketer")),
            .other,
        ]
        case .interests: [
            .init(id: "ai_generation", labelKey: L10n.key("AI videos")),
            .init(id: "ai_transcription", labelKey: L10n.key("AI transcription")),
            .init(id: "agent_editing", labelKey: L10n.key("Agentic editing")),
            .init(id: "external_agents", labelKey: L10n.key("Integration with your own agent")),
            .init(id: "video_automation", labelKey: L10n.key("Video automation")),
        ]
        }
    }
}
