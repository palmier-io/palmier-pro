import AppKit
import Observation

// MARK: - Model

struct TourStep: Equatable {
    enum Kind: Equatable {
        case intro
        case spotlight(TourTarget)
        case outro
    }
    let kind: Kind
    let title: String
    let instruction: String
}

enum TourTarget: Equatable {
    case panel(EditorViewModel.FocusedPanel)
    case element(TourAnchorID)

    /// The panel that must be visible for this target to have a frame.
    var hostPanel: EditorViewModel.FocusedPanel {
        switch self {
        case .panel(let p): return p
        case .element(let id): return id.hostPanel
        }
    }
}

/// Pinpointable controls. Add a case + its `hostPanel`, then tag the view with
/// `.tourAnchor(_:)`. `timelineRuler` is derived (the AppKit ruler has no SwiftUI view).
enum TourAnchorID: Hashable {
    case importButton
    case generateButton
    case generation
    case smartSearch
    case screenshotButton
    case skillsButton
    case timelineRuler

    var hostPanel: EditorViewModel.FocusedPanel {
        switch self {
        case .importButton, .generateButton, .generation, .smartSearch: return .media
        case .screenshotButton: return .preview
        case .skillsButton: return .agent
        case .timelineRuler: return .timeline
        }
    }
}

/// Weak box so registered anchor views aren't retained by the controller.
final class WeakView {
    weak var value: NSView?
    init(_ value: NSView?) { self.value = value }
}

// MARK: - Controller

@MainActor
@Observable
final class TourController {
    private(set) var stepIndex: Int?
    /// Highlighted region's frame in editor-view coords; set by the split controller.
    var targetFrame: CGRect?
    /// Live backing views for `.element` targets, registered by `.tourAnchor(_:)`.
    @ObservationIgnored var anchorViews: [TourAnchorID: WeakView] = [:]
    /// Bumped when an anchor view lays out, so the split controller recomputes the
    /// frame for controls that appear/animate inside a panel (e.g. the generation panel).
    private(set) var anchorRevision = 0
    func anchorDidLayout() { anchorRevision &+= 1 }
    @ObservationIgnored private weak var editor: EditorViewModel?

    private(set) var steps: [TourStep] = []

    var count: Int { steps.count }

    var spotlightCount: Int {
        steps.reduce(0) { if case .spotlight = $1.kind { return $0 + 1 }; return $0 }
    }

    var currentStep: TourStep? {
        guard let i = stepIndex, steps.indices.contains(i) else { return nil }
        return steps[i]
    }

    func start(in editor: EditorViewModel) {
        self.editor = editor
        steps = Self.makeSteps(editor: editor)
        applyStep(0)
    }

    func advance() {
        guard let i = stepIndex else { return }
        if steps.indices.contains(i + 1) { applyStep(i + 1) } else { end() }
    }

    func back() {
        guard let i = stepIndex, i > 0 else { return }
        applyStep(i - 1)
    }

    func end() {
        stepIndex = nil
        targetFrame = nil
    }

    /// Ensure a spotlight step's host panel is visible
    private func applyStep(_ index: Int) {
        guard let editor, steps.indices.contains(index) else { return }
        editor.maximizedPanel = nil
        if case .spotlight(let target) = steps[index].kind {
            switch target.hostPanel {
            case .media: editor.mediaPanelVisible = true
            case .agent: editor.agentPanelVisible = true
            case .inspector: editor.inspectorPanelVisible = true
            case .timeline, .preview: break
            }
            editor.showGenerationPanel = (target == .element(.generation))
        } else {
            editor.showGenerationPanel = false
        }
        stepIndex = index
    }

    // MARK: - Step list

    private static func makeSteps(editor: EditorViewModel) -> [TourStep] {
        var steps: [TourStep] = [
            TourStep(kind: .intro, title: L10n.string("Tutorial"),
                     instruction: L10n.string("Let's take a quick tour of the workspace and what you can do.")),
            TourStep(kind: .spotlight(.panel(.media)), title: L10n.string("Media panel"),
                     instruction: L10n.string("This is where all your footage and assets live.")),
            TourStep(kind: .spotlight(.element(.importButton)), title: L10n.string("Import footage"),
                     instruction: L10n.string("Import your footage here, or drag and drop, or copy-paste, into the media panel.")),
            TourStep(kind: .spotlight(.element(.generateButton)), title: L10n.string("Generate"),
                     instruction: L10n.string("Click Generate to open the generation panel.")),
            TourStep(kind: .spotlight(.element(.generation)), title: L10n.string("Generation panel"),
                     instruction: L10n.string("Generate video, image, or audio with different models and settings. Drag assets from the media panel above into the reference frame.")),
        ]
        // Only shown when the "Smart search" button is present (model not yet installed).
        if smartSearchAvailable(editor: editor) {
            steps.append(TourStep(kind: .spotlight(.element(.smartSearch)), title: L10n.string("Smart search"),
                                  instruction: L10n.string("Download a local model to index your media, so you or your agent can search any clips by describing them. The model runs on-device and nothing leaves your Mac.")))
        }
        steps += [
            TourStep(kind: .spotlight(.panel(.preview)), title: L10n.string("Preview"),
                     instruction: L10n.string("This is your preview panel to play a selected media or the whole timeline.")),
            TourStep(kind: .spotlight(.element(.screenshotButton)), title: L10n.string("Screenshot a frame"),
                     instruction: L10n.string("Take a screenshot of the preview and use it as a reference for generation. Particularly useful for creating AI transitions.")),
            TourStep(kind: .spotlight(.panel(.inspector)), title: L10n.string("Inspector"),
                     instruction: L10n.string("This is your inspector panel. Select a clip from the timeline to edit it.")),
            TourStep(kind: .spotlight(.panel(.timeline)), title: L10n.string("Timeline"),
                     instruction: L10n.string("Your timeline: the top half is video, the bottom half is audio. This is where you edit. Right-click a clip for some cool AI features such as upscale, edit, or generate music.")),
            TourStep(kind: .spotlight(.element(.timelineRuler)), title: L10n.string("Select a range"),
                     instruction: L10n.string("This is the timeline ruler. Shift+drag on the ruler to select a range to render. You can pick any slot to AI edit or generate music that fits that range.")),
            TourStep(kind: .spotlight(.panel(.agent)), title: L10n.string("AI agent"),
                     instruction: L10n.string("Chat with your agent! It can generate content, edit clips, organize your assets, and much more. Start by signing in, or bring your own Anthropic API key.")),
            TourStep(kind: .spotlight(.element(.skillsButton)), title: L10n.string("Skills"),
                     instruction: L10n.string("Open Skills to browse community playbooks, create your own, or add them to other agents.")),
            TourStep(kind: .outro, title: L10n.string("You're all set"),
                     instruction: L10n.string("Start creating, or explore these to get the most out of Palmier Pro.")),
        ]
        return steps
    }

    /// True when the "Smart search" enable button is showing (model downloadable, not yet installed).
    private static func smartSearchAvailable(editor: EditorViewModel) -> Bool {
        let model = VisualModelLoader.shared
        guard case .notInstalled = model.state, model.enabled else { return false }
        return editor.mediaAssets.contains { $0.type == .video || $0.type == .image }
    }
}
