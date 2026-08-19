import Foundation

enum OnboardingStep: Int {
    case welcome, discovery, profile, account
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
    case roles, videoTypes, interests, acquisitionSource, previousEditors

    var id: String { rawValue }

    static let profileQuestions: [OnboardingQuestion] = [.roles, .videoTypes, .interests]
    static let discoveryQuestions: [OnboardingQuestion] = [.acquisitionSource, .previousEditors]

    var titleKey: String {
        switch self {
        case .videoTypes: L10n.key("What do you make?")
        case .roles: L10n.key("What best describes your role?")
        case .interests: L10n.key("What interests you most about Palmier Pro?")
        case .acquisitionSource: L10n.key("How did you find Palmier Pro?")
        case .previousEditors: L10n.key("Which editors did you use before?")
        }
    }

    var allowsMultipleSelection: Bool {
        self != .acquisitionSource
    }

    var exclusiveOptionIDs: Set<String> {
        self == .previousEditors ? ["none"] : []
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
        case .acquisitionSource: [
            .init(id: "google", labelKey: L10n.key("Google")),
            .init(id: "github", labelKey: L10n.key("GitHub")),
            .init(id: "x", labelKey: L10n.key("X")),
            .init(id: "instagram", labelKey: L10n.key("Instagram")),
            .init(id: "youtube", labelKey: L10n.key("YouTube")),
            .init(id: "hacker_news", labelKey: L10n.key("Hacker News")),
            .init(id: "word_of_mouth", labelKey: L10n.key("Friend or colleague")),
            .other,
        ]
        case .previousEditors: [
            .init(id: "premiere_pro", labelKey: L10n.key("Adobe Premiere Pro")),
            .init(id: "davinci_resolve", labelKey: L10n.key("DaVinci Resolve")),
            .init(id: "final_cut_pro", labelKey: L10n.key("Final Cut Pro")),
            .init(id: "capcut", labelKey: L10n.key("CapCut")),
            .init(id: "instagram_edits", labelKey: L10n.key("Instagram Edits")),
            .init(id: "imovie", labelKey: L10n.key("iMovie")),
            .init(id: "descript", labelKey: L10n.key("Descript")),
            .init(id: "none", labelKey: L10n.key("None")),
            .other,
        ]
        }
    }
}
