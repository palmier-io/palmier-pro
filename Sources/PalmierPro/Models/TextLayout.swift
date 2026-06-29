import AppKit

/// Natural bounding size of a rendered text clip, shared between the layer
/// controller and clip placement.
enum TextLayout {
    static let shadowPadding: CGFloat = 12
    static let referenceCanvasHeight: CGFloat = 1080

    struct WordFrame: Equatable {
        var text: String
        /// Origin and size within the phrase text box (top-left origin).
        var rect: CGRect
    }

    static func naturalSize(
        content: String,
        style: TextStyle,
        maxWidth: CGFloat,
        canvasHeight: CGFloat
    ) -> CGSize {
        let measured = content.isEmpty ? " " : content
        let canvasScale = canvasHeight / referenceCanvasHeight
        let renderSize = CGFloat(style.fontSize * style.fontScale) * canvasScale
        let str = NSAttributedString(
            string: measured,
            attributes: style.attributes(size: renderSize, includeColor: false)
        )
        let bounding = str.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        // +4px slack absorbs canvas→preview scale rounding.
        let slack: CGFloat = 4
        let shadowPad = style.shadow.enabled ? shadowPadding * 2 : 0
        return CGSize(
            width: max(1, ceil(bounding.width) + shadowPad + slack),
            height: max(1, ceil(bounding.height) + slack)
        )
    }

    static func wordFrames(
        content: String,
        words: [CaptionWordTiming],
        style: TextStyle,
        boxSize: CGSize,
        canvasHeight: CGFloat
    ) -> [WordFrame] {
        guard !content.isEmpty, !words.isEmpty else { return [] }
        let canvasScale = canvasHeight / referenceCanvasHeight
        let fontSize = CGFloat(style.fontSize * style.fontScale) * canvasScale
        let attr = NSAttributedString(string: content, attributes: style.fillAttributes(size: fontSize))
        let storage = NSTextStorage(attributedString: attr)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: boxSize)
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)

        let ns = content as NSString
        let tokenRanges = tokenRanges(in: ns)
        guard !tokenRanges.isEmpty else { return [] }

        var frames: [WordFrame] = []
        for index in words.indices {
            let range = tokenRanges[min(index, tokenRanges.count - 1)]
            let glyphRange = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphRange, in: container)
            let lineRect = layout.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            rect.origin.y = lineRect.origin.y
            rect.size.height = lineRect.height
            frames.append(WordFrame(text: ns.substring(with: range), rect: rect))
        }
        return frames
    }

    private static func tokenRanges(in ns: NSString) -> [NSRange] {
        let whitespace = CharacterSet.whitespacesAndNewlines
        var ranges: [NSRange] = []
        var loc = 0
        while loc < ns.length {
            while loc < ns.length, isWhitespace(ns.character(at: loc), whitespace) { loc += 1 }
            guard loc < ns.length else { break }
            let start = loc
            while loc < ns.length, !isWhitespace(ns.character(at: loc), whitespace) { loc += 1 }
            ranges.append(NSRange(location: start, length: loc - start))
        }
        return ranges
    }

    private static func isWhitespace(_ unit: unichar, _ set: CharacterSet) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return set.contains(scalar)
    }
}
