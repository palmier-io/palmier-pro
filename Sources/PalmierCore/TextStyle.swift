import Foundation

public struct TextStyle: Codable, Sendable, Equatable, Hashable {
    public static let axisScaleRange = 0.1...10.0

    public var fontName: String = "Helvetica-Bold"
    public var fontSize: Double = 96
    public var fontScale: Double = 1.0
    public var widthScale: Double = 1.0
    public var heightScale: Double = 1.0
    public var tracking: Double = 0
    public var lineSpacing: Double = 0
    public var fontCase: FontCase = .mixed
    public var isBold: Bool = true
    public var isItalic: Bool = false
    public var isUnderlined: Bool = false
    public var isStruckThrough: Bool = false
    public var isOverlined: Bool = false
    public var color: RGBA = RGBA()
    public var alignment: Alignment = .center
    public var shadow: Shadow = Shadow()
    public var background: Background = Background()
    public var border: Outline = Outline()

    public init() {}

    /// Convenience init overriding just fontSize; everything else defaults.
    public init(fontSize: Double) {
        self.init()
        self.fontSize = fontSize
    }

    /// Full memberwise init (synthesized memberwise inits are internal; this
    /// public form covers every partial shape callers use via default args).
    public init(
        fontName: String = "Helvetica-Bold",
        fontSize: Double = 96,
        fontScale: Double = 1.0,
        widthScale: Double = 1.0,
        heightScale: Double = 1.0,
        tracking: Double = 0,
        lineSpacing: Double = 0,
        fontCase: FontCase = .mixed,
        isBold: Bool = true,
        isItalic: Bool = false,
        isUnderlined: Bool = false,
        isStruckThrough: Bool = false,
        isOverlined: Bool = false,
        color: RGBA = RGBA(),
        alignment: Alignment = .center,
        shadow: Shadow = Shadow(),
        background: Background = Background(),
        border: Outline = Outline()
    ) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.fontScale = fontScale
        self.widthScale = widthScale
        self.heightScale = heightScale
        self.tracking = tracking
        self.lineSpacing = lineSpacing
        self.fontCase = fontCase
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderlined = isUnderlined
        self.isStruckThrough = isStruckThrough
        self.isOverlined = isOverlined
        self.color = color
        self.alignment = alignment
        self.shadow = shadow
        self.background = background
        self.border = border
    }

    public enum Alignment: String, Codable, Sendable, CaseIterable, Hashable {
        case left
        case center
        case right
    }

    public enum FontCase: String, Codable, Sendable, CaseIterable, Hashable {
        case mixed
        case uppercase
        case lowercase

        public var label: String {
            switch self {
            case .mixed: "Mixed"
            case .uppercase: "UPPERCASE"
            case .lowercase: "lowercase"
            }
        }

        public func apply(to text: String) -> String {
            switch self {
            case .mixed: text
            case .uppercase: text.uppercased()
            case .lowercase: text.lowercased()
            }
        }
    }

    public struct RGBA: Codable, Sendable, Equatable, Hashable {
        public var r: Double = 1
        public var g: Double = 1
        public var b: Double = 1
        public var a: Double = 1

        public init(r: Double = 1, g: Double = 1, b: Double = 1, a: Double = 1) {
            self.r = r; self.g = g; self.b = b; self.a = a
        }
    }

    public struct Shadow: Codable, Sendable, Equatable, Hashable {
        public var enabled: Bool = true
        /// Alpha doubles as opacity; layer.shadowOpacity stays at 1.
        public var color: RGBA = RGBA(r: 0, g: 0, b: 0, a: 0.6)
        /// Canvas points; scaled at render time.
        public var offsetX: Double = 0
        public var offsetY: Double = -2
        public var blur: Double = 6

        public init() {}

        public init(
            enabled: Bool = true,
            color: RGBA = RGBA(r: 0, g: 0, b: 0, a: 0.6),
            offsetX: Double = 0,
            offsetY: Double = -2,
            blur: Double = 6
        ) {
            self.enabled = enabled
            self.color = color
            self.offsetX = offsetX
            self.offsetY = offsetY
            self.blur = blur
        }
    }

    public struct Outline: Codable, Sendable, Equatable, Hashable {
        public var enabled: Bool = false
        public var color: RGBA = RGBA(r: 0, g: 0, b: 0, a: 1)
        /// Width in reference-canvas points.
        public var width: Double = 4

        public init(enabled: Bool = false, color: RGBA = RGBA(r: 0, g: 0, b: 0, a: 1), width: Double = 4) {
            self.enabled = enabled
            self.color = color
            self.width = width
        }

        private enum CodingKeys: String, CodingKey { case enabled, color, width }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                enabled: (try? c.decode(Bool.self, forKey: .enabled)) ?? false,
                color: (try? c.decode(RGBA.self, forKey: .color)) ?? RGBA(r: 0, g: 0, b: 0, a: 1),
                width: (try? c.decode(Double.self, forKey: .width)) ?? 4
            )
        }
    }

    public struct Background: Codable, Sendable, Equatable, Hashable {
        public var enabled: Bool = false
        public var color: RGBA = RGBA(r: 0, g: 0, b: 0, a: 0.6)
        public var paddingX: Double = 0
        public var paddingY: Double = 0
        public var cornerRadius: Double = 0
        public var offsetX: Double = 0
        public var offsetY: Double = 0
        public var outlineColor: RGBA = RGBA(r: 0, g: 0, b: 0, a: 1)
        public var outlineWidth: Double = 0

        public init(
            enabled: Bool = false,
            color: RGBA = RGBA(r: 0, g: 0, b: 0, a: 0.6),
            paddingX: Double = 0,
            paddingY: Double = 0,
            cornerRadius: Double = 0,
            offsetX: Double = 0,
            offsetY: Double = 0,
            outlineColor: RGBA = RGBA(r: 0, g: 0, b: 0, a: 1),
            outlineWidth: Double = 0
        ) {
            self.enabled = enabled
            self.color = color
            self.paddingX = paddingX
            self.paddingY = paddingY
            self.cornerRadius = cornerRadius
            self.offsetX = offsetX
            self.offsetY = offsetY
            self.outlineColor = outlineColor
            self.outlineWidth = outlineWidth
        }

        private enum CodingKeys: String, CodingKey {
            case enabled, color, paddingX, paddingY, cornerRadius, offsetX, offsetY, outlineColor, outlineWidth
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                enabled: (try? c.decode(Bool.self, forKey: .enabled)) ?? false,
                color: (try? c.decode(RGBA.self, forKey: .color)) ?? RGBA(r: 0, g: 0, b: 0, a: 0.6),
                paddingX: (try? c.decode(Double.self, forKey: .paddingX)) ?? 0,
                paddingY: (try? c.decode(Double.self, forKey: .paddingY)) ?? 0,
                cornerRadius: (try? c.decode(Double.self, forKey: .cornerRadius)) ?? 0,
                offsetX: (try? c.decode(Double.self, forKey: .offsetX)) ?? 0,
                offsetY: (try? c.decode(Double.self, forKey: .offsetY)) ?? 0,
                outlineColor: (try? c.decode(RGBA.self, forKey: .outlineColor)) ?? RGBA(r: 0, g: 0, b: 0, a: 1),
                outlineWidth: (try? c.decode(Double.self, forKey: .outlineWidth)) ?? 0
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case fontName, fontSize, fontScale, widthScale, heightScale, tracking, lineSpacing, fontCase
        case isBold, isItalic, isUnderlined, isStruckThrough, isOverlined
        case color, alignment, shadow, background, border
    }
}

public extension TextStyle {
    /// Missing-key-tolerant decode — older files pick up defaults for fields added later.
    /// Bold/italic fall back to font-name trait inference via `boldItalicInference`
    /// (registered by the app, since it requires a platform font framework). The
    /// default returns no inference, meaning the stored default is used.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fontName = (try? c.decode(String.self, forKey: .fontName)) ?? "Helvetica-Bold"
        let fontSize = (try? c.decode(Double.self, forKey: .fontSize)) ?? 96
        let inferred = TextStyle.boldItalicInference(fontName, fontSize)
        self.init()
        self.fontName = fontName
        self.fontSize = fontSize
        self.fontScale = (try? c.decode(Double.self, forKey: .fontScale)) ?? 1.0
        self.widthScale = (try? c.decode(Double.self, forKey: .widthScale)) ?? 1.0
        self.heightScale = (try? c.decode(Double.self, forKey: .heightScale)) ?? 1.0
        self.tracking = (try? c.decode(Double.self, forKey: .tracking)) ?? 0
        self.lineSpacing = (try? c.decode(Double.self, forKey: .lineSpacing)) ?? 0
        self.fontCase = (try? c.decode(FontCase.self, forKey: .fontCase)) ?? .mixed
        self.isBold = (try? c.decode(Bool.self, forKey: .isBold)) ?? inferred.bold
        self.isItalic = (try? c.decode(Bool.self, forKey: .isItalic)) ?? inferred.italic
        self.isUnderlined = (try? c.decode(Bool.self, forKey: .isUnderlined)) ?? false
        self.isStruckThrough = (try? c.decode(Bool.self, forKey: .isStruckThrough)) ?? false
        self.isOverlined = (try? c.decode(Bool.self, forKey: .isOverlined)) ?? false
        self.color = (try? c.decode(RGBA.self, forKey: .color)) ?? RGBA()
        self.alignment = (try? c.decode(Alignment.self, forKey: .alignment)) ?? .center
        self.shadow = (try? c.decode(Shadow.self, forKey: .shadow)) ?? Shadow()
        self.background = (try? c.decode(Background.self, forKey: .background)) ?? Background()
        self.border = (try? c.decode(Outline.self, forKey: .border)) ?? Outline()
    }

    /// Hook registered by the app to infer bold/italic from a PostScript font name.
    /// Core has no font framework, so the default reports no inference. The app
    /// overrides this at launch via `usePlatformFontTraitInference(_:)`.
    nonisolated(unsafe) static var boldItalicInference: (String, Double) -> (bold: Bool, italic: Bool) = { _, _ in (false, false) }

    /// Installed by the app to restore platform font-name → bold/italic inference.
    static func usePlatformFontTraitInference(_ inference: @escaping (String, Double) -> (bold: Bool, italic: Bool)) {
        boldItalicInference = inference
    }
}

public extension TextStyle {
    /// Scales font size, tracking, spacing, shadow, border, and background paddings
    /// by `fontScale` and resets `fontScale` to 1. Pure Double math.
    var scaledVisualStyle: TextStyle {
        guard fontScale != 1 else { return self }
        var style = self
        style.fontSize *= fontScale
        style.tracking *= fontScale
        style.lineSpacing *= fontScale
        style.shadow.offsetX *= fontScale
        style.shadow.offsetY *= fontScale
        style.shadow.blur *= fontScale
        style.border.width *= fontScale
        style.background.paddingX *= fontScale
        style.background.paddingY *= fontScale
        style.background.cornerRadius *= fontScale
        style.background.offsetX *= fontScale
        style.background.offsetY *= fontScale
        style.background.outlineWidth *= fontScale
        style.fontScale = 1
        return style
    }

    func displayText(_ text: String) -> String {
        fontCase.apply(to: text)
    }
}

public extension TextStyle.RGBA {
    /// Accepts `#RGB`, `#RRGGBB`, or `#RRGGBBAA`. Leading `#` optional.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        let chars = Array(s)
        func component(_ start: Int, _ len: Int) -> Double? {
            let slice = String(chars[start..<start + len])
            let byteStr = len == 1 ? slice + slice : slice
            guard let n = UInt8(byteStr, radix: 16) else { return nil }
            return Double(n) / 255.0
        }
        switch chars.count {
        case 3:
            guard let r = component(0, 1), let g = component(1, 1), let b = component(2, 1) else { return nil }
            self.init(r: r, g: g, b: b, a: 1)
        case 6:
            guard let r = component(0, 2), let g = component(2, 2), let b = component(4, 2) else { return nil }
            self.init(r: r, g: g, b: b, a: 1)
        case 8:
            guard let r = component(0, 2), let g = component(2, 2),
                  let b = component(4, 2), let a = component(6, 2) else { return nil }
            self.init(r: r, g: g, b: b, a: a)
        default:
            return nil
        }
    }
}
