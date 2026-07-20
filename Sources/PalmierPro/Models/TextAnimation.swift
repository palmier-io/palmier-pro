import Foundation

struct WordTiming: Codable, Sendable, Equatable {
    var text: String
    var startFrame: Int
    var endFrame: Int
    /// false = timing was interpolated (character-count), not acoustically aligned; nil = unknown
    /// provenance (pre-feature clip or engine-native timing). Optional so old projects decode.
    var aligned: Bool?

    init(text: String, startFrame: Int, endFrame: Int, aligned: Bool? = nil) {
        self.text = text
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.aligned = aligned
    }
}

struct TextAnimation: Codable, Sendable, Equatable {
    var preset: Preset = .none
    var perWordFrames: Int = 6
    var highlight: TextStyle.RGBA?
    /// Animation unit for per-word/typewriter presets. `word` (default) animates a whole word — a CJK
    /// word like 重庆 as one unit; `char` animates each character. Missing in old projects → word.
    var granularity: Granularity = .word

    enum Granularity: String, Codable, Sendable { case word, char }

    enum Preset: String, Codable, CaseIterable, Sendable {
        case none
        // Whole-clip / per-line.
        case fadeIn, popIn, slideUp, typewriter
        // Per word.
        case wordReveal, wordSlide, wordPop, wordCycle, highlightPop, highlightBlock

        enum RenderMode { case entrance, perWord, typewriter }

        var renderMode: RenderMode {
            switch self {
            case .none, .fadeIn, .popIn, .slideUp: .entrance
            case .typewriter: .typewriter
            case .wordReveal, .wordSlide, .wordPop, .wordCycle,
                 .highlightPop, .highlightBlock: .perWord
            }
        }

        var isPerWord: Bool { renderMode == .perWord }
        var usesHighlight: Bool { isPerWord }
        /// Word/character stepping applies to per-word and typewriter modes; entrances animate the line.
        var usesGranularity: Bool { self != .none && renderMode != .entrance }

        var displayName: String {
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

        static let agentValues: [String] = ["off"] + allCases.filter { $0 != .none }.map(\.rawValue)

        static let perLine: [Preset] = [.fadeIn, .popIn, .slideUp, .typewriter]
        static let perWord: [Preset] = [.wordReveal, .wordSlide, .wordPop, .wordCycle,
                                        .highlightPop, .highlightBlock]
    }

    var isActive: Bool { preset != .none }

    static let defaultHighlight = TextStyle.RGBA(r: 1, g: 0.85, b: 0, a: 1)

    private enum CodingKeys: String, CodingKey { case preset, perWordFrames, highlight, granularity }

    init(preset: Preset = .none, perWordFrames: Int = 6, highlight: TextStyle.RGBA? = nil, granularity: Granularity = .word) {
        self.preset = preset
        self.perWordFrames = perWordFrames
        self.highlight = highlight
        self.granularity = granularity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            preset: (try? c.decode(Preset.self, forKey: .preset)) ?? .none,
            perWordFrames: (try? c.decode(Int.self, forKey: .perWordFrames)) ?? 6,
            highlight: try? c.decode(TextStyle.RGBA.self, forKey: .highlight),
            granularity: (try? c.decode(Granularity.self, forKey: .granularity)) ?? .word
        )
    }
}
