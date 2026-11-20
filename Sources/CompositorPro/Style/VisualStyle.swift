import Foundation
import SwiftUI

/// A reusable, named visual style playbook — ported from OpenMontage's
/// `styles/*.yaml` + `schemas/styles/playbook.schema.json` conventions.
///
/// A `VisualStyle` is data only: it declares a color palette, typography,
/// motion, audio, and overlay rules, but never mutates `AppTheme`. Views opt
/// in by reading `style.color(for:)` / `style.font(for:)` instead of
/// `AppTheme.Text.primaryColor` etc. `AppTheme` remains the hard default.
///
/// Styles load from JSON files (one per playbook) via `VisualStyleManager`.
/// No OpenMontage source is copied; the schema and validation rules are
/// reimplemented in Swift.
struct VisualStyle: Codable, Sendable, Equatable {
    /// A named role a color can play in the style.
    enum ColorRole: String, Codable, Sendable, CaseIterable {
        case background, surface, text, primary, accent, muted
    }

    /// A typographic role.
    enum TextRole: String, Codable, Sendable, CaseIterable {
        case heading, body, code, statCard
    }

    /// Playbook category, matching OpenMontage's schema enum.
    enum Category: String, Codable, Sendable, CaseIterable {
        case motionGraphics = "motion-graphics"
        case whiteboard
        case cinematic
        case minimalist
        case retro
        case custom
    }

    /// Playbook pace, matching OpenMontage's schema enum.
    enum Pace: String, Codable, Sendable, CaseIterable {
        case slow, deliberate, moderate, fast, rapid
    }

    /// Harmony type for color rules.
    enum HarmonyType: String, Codable, Sendable, CaseIterable {
        case complementary, analogous, triadic, splitComplementary = "split-complementary"
    }

    /// Scale-system ratio for modular typography.
    enum ScaleSystem: Codable, Sendable, Equatable {
        case named(String)        // minor_second, major_second, minor_third, major_third, perfect_fourth, golden
        case custom(Double)       // any ratio > 1.0

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                self = .custom(number)
            } else {
                let name = try container.decode(String.self)
                self = .named(name)
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .named(let name): try container.encode(name)
            case .custom(let value): try container.encode(value)
            }
        }
    }

    // MARK: - Identity

    struct Identity: Codable, Sendable, Equatable {
        var name: String
        var category: Category
        var mood: String
        var pace: Pace
        var bestFor: String?
    }

    // MARK: - Color (stored as hex strings, matching OpenMontage's YAML; resolved to RGBA on access)

    struct ColorPalette: Codable, Sendable, Equatable {
        var primary: [String]
        var accent: [String]
        var background: String
        var text: String
        var muted: String?
    }

    // MARK: - Typography

    struct FontSpec: Codable, Sendable, Equatable {
        var font: String
        var weight: Int = 400            // 100...900
        var tracking: String?            // e.g. "-0.01em"
        var lineHeight: Double?
        var sizeMultiplier: Double?

        var fontWeight: Font.Weight {
            switch weight {
            case ...100: .ultraLight
            case 101...200: .thin
            case 201...300: .light
            case 301...400: .regular
            case 401...500: .medium
            case 501...600: .semibold
            case 601...700: .bold
            case 701...800: .heavy
            default: .black
            }
        }
    }

    struct WeightMatrix: Codable, Sendable, Equatable {
        var title: Int = 800
        var heading: Int = 700
        var body: Int = 400
        var caption: Int = 500
    }

    struct Typography: Codable, Sendable, Equatable {
        var headings: FontSpec
        var body: FontSpec
        var code: FontSpec?
        var statCard: FontSpec?
        var scaleSystem: ScaleSystem?
        var weightMatrix: WeightMatrix?
    }

    // MARK: - Motion

    struct PacingRules: Codable, Sendable, Equatable {
        var minSceneHoldSeconds: Double?
        var maxSceneHoldSeconds: Double?
        var textCardHoldSeconds: Double?
        var statCardHoldSeconds: Double?
        var transitionDurationSeconds: Double?
    }

    struct Motion: Codable, Sendable, Equatable {
        var transitions: [String] = ["fade"]
        var animationStyle: String = "ease-out"
        var pacingRules: PacingRules?
        var entrance: String?
        var exit: String?
    }

    // MARK: - Audio

    struct Audio: Codable, Sendable, Equatable {
        var voiceStyle: String = "measured, expert, warm"
        var musicMood: String = "minimal pulse"
        var musicVolume: Double = 0.07     // 0...1
        var sfxStyle: String?
        var duckingThresholdDB: Double?
    }

    // MARK: - Overlays

    struct OverlayStyle: Codable, Sendable, Equatable {
        var bg: String?
        var border: String?
        var text: String?
        var radius: Double?
        var shadow: String?
        var highlight: String?
        var accent: String?
    }

    struct Overlays: Codable, Sendable, Equatable {
        var statCard: OverlayStyle?
        var keyTerm: OverlayStyle?
        var codeBlock: OverlayStyle?
        var sectionTitle: OverlayStyle?
        var statReveal: OverlayStyle?
        var heroTitle: OverlayStyle?
        var providerChip: OverlayStyle?
    }

    // MARK: - Asset generation

    struct AssetGeneration: Codable, Sendable, Equatable {
        var imagePromptPrefix: String?
        var imageNegativePrompt: String?
        var diagramStyle: String?
        var consistencyAnchors: [String]?
        var sceneType: String?            // default cut.type equivalent
        var multiImagePerScene: Bool = false
        var imagesPerScene: Int = 1
        var defaultParticles: String?
        var defaultParticleColor: String?
        var defaultVignette: Bool = false

        enum CodingKeys: String, CodingKey {
            case imagePromptPrefix, imageNegativePrompt, diagramStyle, consistencyAnchors
            case sceneType, multiImagePerScene, imagesPerScene, defaultParticles, defaultParticleColor, defaultVignette
        }

        init(
            imagePromptPrefix: String? = nil,
            imageNegativePrompt: String? = nil,
            diagramStyle: String? = nil,
            consistencyAnchors: [String]? = nil,
            sceneType: String? = nil,
            multiImagePerScene: Bool = false,
            imagesPerScene: Int = 1,
            defaultParticles: String? = nil,
            defaultParticleColor: String? = nil,
            defaultVignette: Bool = false
        ) {
            self.imagePromptPrefix = imagePromptPrefix
            self.imageNegativePrompt = imageNegativePrompt
            self.diagramStyle = diagramStyle
            self.consistencyAnchors = consistencyAnchors
            self.sceneType = sceneType
            self.multiImagePerScene = multiImagePerScene
            self.imagesPerScene = imagesPerScene
            self.defaultParticles = defaultParticles
            self.defaultParticleColor = defaultParticleColor
            self.defaultVignette = defaultVignette
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            imagePromptPrefix = try container.decodeIfPresent(String.self, forKey: .imagePromptPrefix)
            imageNegativePrompt = try container.decodeIfPresent(String.self, forKey: .imageNegativePrompt)
            diagramStyle = try container.decodeIfPresent(String.self, forKey: .diagramStyle)
            consistencyAnchors = try container.decodeIfPresent([String].self, forKey: .consistencyAnchors)
            sceneType = try container.decodeIfPresent(String.self, forKey: .sceneType)
            multiImagePerScene = try container.decodeIfPresent(Bool.self, forKey: .multiImagePerScene) ?? false
            imagesPerScene = try container.decodeIfPresent(Int.self, forKey: .imagesPerScene) ?? 1
            defaultParticles = try container.decodeIfPresent(String.self, forKey: .defaultParticles)
            defaultParticleColor = try container.decodeIfPresent(String.self, forKey: .defaultParticleColor)
            defaultVignette = try container.decodeIfPresent(Bool.self, forKey: .defaultVignette) ?? false
        }
    }

    // MARK: - Taste profile

    struct TasteProfile: Codable, Sendable, Equatable {
        var designRead: String
        var visualVariance: Int = 5        // 1...10
        var motionIntensity: Int = 5       // 1...10
        var informationDensity: Int = 5    // 1...10
        var paletteDiscipline: String?
        var layoutVariation: String?
        var referenceStrategy: String?
        var antiPatterns: [String]?
        var qualityGates: [String]?
    }

    // MARK: - Color rules

    struct ColorRules: Codable, Sendable, Equatable {
        var harmonyType: HarmonyType?
        var contrastValidation: Bool = true
        var colorblindSafe: Bool = true
    }

    // MARK: - Overrides

    struct SceneOverride: Codable, Sendable, Equatable {
        var sceneId: String
        var reason: String
        var colorOverride: [String: String]?
        var typographyOverride: [String: FontSpec]?
        var motionOverride: [String: String]?
    }

    struct Overrides: Codable, Sendable, Equatable {
        var maxDeviationRatio: Double = 0.2   // 0...0.5
        var sceneOverrides: [SceneOverride] = []
    }

    // MARK: - Top-level

    var identity: Identity
    var colorPalette: ColorPalette
    var composition: String = "centered, generous margins"
    var texture: String = "flat matte fields"
    var typography: Typography
    var motion: Motion = .init()
    var audio: Audio = .init()
    var assetGeneration: AssetGeneration?
    var overlays: Overlays?
    var qualityRules: [String] = []
    var tasteProfile: TasteProfile?
    var chartPalette: [String]?
    var colorRules: ColorRules?
    var overrides: Overrides?

    // MARK: - Resolved RGBA helpers

    private func rgba(_ hex: String?) -> TextStyle.RGBA? {
        hex.flatMap { TextStyle.RGBA(hex: $0) }
    }

    var primaryRGBA: [TextStyle.RGBA] { colorPalette.primary.compactMap { rgba($0) } }
    var accentRGBA: [TextStyle.RGBA] { colorPalette.accent.compactMap { rgba($0) } }
    var backgroundRGBA: TextStyle.RGBA? { rgba(colorPalette.background) }
    var textRGBA: TextStyle.RGBA? { rgba(colorPalette.text) }
    var mutedRGBA: TextStyle.RGBA? { rgba(colorPalette.muted) }
    var chartPaletteRGBA: [TextStyle.RGBA] { chartPalette?.compactMap { rgba($0) } ?? [] }

    // MARK: - Color accessors (opt-in replacement for AppTheme colors)

    func color(for role: ColorRole) -> Color {
        switch role {
        case .background: backgroundRGBA?.swiftUIColor ?? AppTheme.Background.baseColor
        case .surface: backgroundRGBA?.swiftUIColor ?? AppTheme.Background.surfaceColor
        case .text: textRGBA?.swiftUIColor ?? AppTheme.Text.primaryColor
        case .primary: primaryRGBA.first?.swiftUIColor ?? AppTheme.Accent.primary
        case .accent: accentRGBA.first?.swiftUIColor ?? AppTheme.Accent.primary
        case .muted: mutedRGBA?.swiftUIColor ?? AppTheme.Text.tertiaryColor
        }
    }

    func nsColor(for role: ColorRole) -> NSColor {
        NSColor(color(for: role))
    }

    // MARK: - Typography accessors

    func font(for role: TextRole, size: Double) -> Font {
        let spec: FontSpec
        switch role {
        case .heading: spec = typography.headings
        case .body: spec = typography.body
        case .code: spec = typography.code ?? typography.body
        case .statCard: spec = typography.statCard ?? typography.headings
        }
        return Font.custom(spec.font, size: size)
            .weight(spec.fontWeight)
    }

    /// Resolves the base body font size in pixels using the style's scale system,
    /// or 24 px (the video minimum) if none is declared.
    func baseBodySize() -> Double {
        guard let scale = typography.scaleSystem else { return 24 }
        let ratio: Double
        switch scale {
        case .named(let name): ratio = Self.scaleRatio(named: name)
        case .custom(let r): ratio = r
        }
        return max(16, 24 * ratio)
    }

    private static func scaleRatio(named name: String) -> Double {
        switch name.lowercased() {
        case "minor_second": 1.067
        case "major_second": 1.125
        case "minor_third": 1.2
        case "major_third": 1.25
        case "perfect_fourth": 1.333
        case "golden": 1.618
        default: 1.25
        }
    }
}
