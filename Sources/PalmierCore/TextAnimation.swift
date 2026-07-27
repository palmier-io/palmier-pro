import Foundation

public struct WordTiming: Codable, Sendable, Equatable {
    public var text: String
    public var startFrame: Int
    public var endFrame: Int

    public init(text: String, startFrame: Int, endFrame: Int) {
        self.text = text
        self.startFrame = startFrame
        self.endFrame = endFrame
    }
}

public struct TextAnimation: Codable, Sendable, Equatable {
    public var preset: Preset = .none
    public var perWordFrames: Int = 6
    public var highlight: TextStyle.RGBA?

    public enum Preset: String, Codable, CaseIterable, Sendable {
        case none
        // Whole-clip / per-line.
        case fadeIn, popIn, slideUp, typewriter
        // Per word.
        case wordReveal, wordSlide, wordPop, wordCycle, highlightPop, highlightBlock

        public enum RenderMode { case entrance, perWord, typewriter }

        public var renderMode: RenderMode {
            switch self {
            case .none, .fadeIn, .popIn, .slideUp: .entrance
            case .typewriter: .typewriter
            case .wordReveal, .wordSlide, .wordPop, .wordCycle,
                 .highlightPop, .highlightBlock: .perWord
            }
        }

        public var isPerWord: Bool { renderMode == .perWord }
        public var usesHighlight: Bool { isPerWord }

        public var displayName: String {
            switch self {
            case .none: "Off"
            case .fadeIn: "Fade In"
            case .popIn: "Pop In"
            case .slideUp: "Slide Up"
            case .typewriter: "Typewriter"
            case .wordReveal: "Word Reveal"
            case .wordSlide: "Word Slide"
            case .wordPop: "Word Pop"
            case .wordCycle: "Word Cycle"
            case .highlightPop: "Highlight"
            case .highlightBlock: "Highlight Block"
            }
        }

        public static let agentValues: [String] = ["off"] + allCases.filter { $0 != .none }.map(\.rawValue)

        public static let perLine: [Preset] = [.fadeIn, .popIn, .slideUp, .typewriter]
        public static let perWord: [Preset] = [.wordReveal, .wordSlide, .wordPop, .wordCycle,
                                        .highlightPop, .highlightBlock]
    }

    public var isActive: Bool { preset != .none }

    public static let defaultHighlight = TextStyle.RGBA(r: 1, g: 0.85, b: 0, a: 1)

    private enum CodingKeys: String, CodingKey { case preset, perWordFrames, highlight }

    public init(preset: Preset = .none, perWordFrames: Int = 6, highlight: TextStyle.RGBA? = nil) {
        self.preset = preset
        self.perWordFrames = perWordFrames
        self.highlight = highlight
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            preset: (try? c.decode(Preset.self, forKey: .preset)) ?? .none,
            perWordFrames: (try? c.decode(Int.self, forKey: .perWordFrames)) ?? 6,
            highlight: try? c.decode(TextStyle.RGBA.self, forKey: .highlight)
        )
    }
}
