import AppKit
import CoreImage
import CoreText

/// Renders a text clip as a CIImage using CoreText on the compositor queue
enum TextFrameRenderer {
    // NSCache is internally thread-safe; the compositor queue and main thread both hit it.
    nonisolated(unsafe) private static let cache = NSCache<NSString, CIImage>()

    static func image(clip: Clip, frame: Int, renderSize: CGSize) -> CIImage? {
        guard renderSize.width >= 1, renderSize.height >= 1 else { return nil }
        let content = clip.textContent ?? ""
        guard !content.isEmpty else { return nil }
        let style = clip.textStyle ?? TextStyle()
        let box = boxRect(clip.transform, renderSize)
        let fontSize = CGFloat(style.fontSize * style.fontScale) * (renderSize.height / TextLayout.referenceCanvasHeight)
        let anim = clip.textAnimation

        if let anim, anim.isActive {
            switch anim.preset.renderMode {
            case .perWord:
                return renderPerWord(clip: clip, content: content, style: style, box: box,
                                     fontSize: fontSize, anim: anim, frame: frame, renderSize: renderSize)
            case .typewriter:
                return renderTypewriter(clip: clip, content: content, style: style, box: box,
                                        fontSize: fontSize, frame: frame, renderSize: renderSize)
            case .entrance:
                break
            }
        }

        // Static base is frame-independent → cache it. Entrance reuses it under a transform.
        guard let base = cachedStatic(content: content, style: style, transform: clip.transform,
                                      box: box, fontSize: fontSize, renderSize: renderSize) else { return nil }
        guard let anim, anim.isActive else { return base }
        return applyEntrance(base, TextAnimator.clipEntry(anim, rel: frame - clip.startFrame),
                             box: box, renderSize: renderSize)
    }

    // MARK: - Geometry

    /// Clip box in CG y-up coords (origin bottom-left); transform.topLeft is top-down.
    private static func boxRect(_ t: Transform, _ size: CGSize) -> CGRect {
        let tl = t.topLeft
        let h = max(1, t.height * size.height)
        return CGRect(x: tl.x * size.width, y: size.height - tl.y * size.height - h,
                      width: max(1, t.width * size.width), height: h)
    }

    /// A render-sized context with the box fill and shadow already applied.
    private static func beginContext(style: TextStyle, box: CGRect, renderSize: CGSize) -> CGContext? {
        guard let ctx = CGContext(
            data: nil, width: Int(renderSize.width.rounded()), height: Int(renderSize.height.rounded()),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        drawBox(ctx, style: style, box: box)
        applyShadow(ctx, style: style, renderSize: renderSize)
        return ctx
    }

    /// Premultiplied, NO color space — FrameRenderer unpremultiplies it like a source buffer.
    private static func finish(_ ctx: CGContext) -> CIImage? {
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
    }

    /// Tall top-anchored layout path so CoreText never drops a line overflowing the box
    /// (CATextLayer didn't clip vertically either). Box width drives wrapping.
    private static func layoutFrame(_ attr: NSAttributedString, box: CGRect) -> CTFrame {
        let setter = CTFramesetterCreateWithAttributedString(attr as CFAttributedString)
        let path = CGPath(rect: CGRect(x: box.minX, y: 0, width: box.width, height: box.maxY), transform: nil)
        return CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
    }

    // MARK: - Static

    private static func cachedStatic(content: String, style: TextStyle, transform: Transform,
                                     box: CGRect, fontSize: CGFloat, renderSize: CGSize) -> CIImage? {
        let key = signature(content, style, transform, renderSize)
        if let cached = cache.object(forKey: key) { return cached }
        guard let ctx = beginContext(style: style, box: box, renderSize: renderSize) else { return nil }
        CTFrameDraw(layoutFrame(NSAttributedString(string: content, attributes: style.attributes(size: fontSize)), box: box), ctx)
        guard let image = finish(ctx) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    // MARK: - Entrance (whole-clip)

    private static func applyEntrance(_ base: CIImage, _ st: TextAnimator.ClipState,
                                      box: CGRect, renderSize: CGSize) -> CIImage {
        var img = base
        if st.scale != 1 || st.dy != 0 {
            let cx = box.midX, cy = box.midY
            var t = CGAffineTransform(translationX: cx, y: cy)
                .scaledBy(x: st.scale, y: st.scale)
                .translatedBy(x: -cx, y: -cy)
            t = t.translatedBy(x: 0, y: -st.dy * renderSize.height)  // dy positive = down = -y in CI
            img = img.transformed(by: t)
        }
        if st.opacity < 1 {
            let k = CGFloat(st.opacity)  // premultiplied coverage scale → all four channels
            img = img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: k),
            ])
        }
        return img
    }

    // MARK: - Per-word

    private static func renderPerWord(clip: Clip, content: String, style: TextStyle, box: CGRect,
                                      fontSize: CGFloat, anim: TextAnimation, frame: Int, renderSize: CGSize) -> CIImage? {
        guard let ctx = beginContext(style: style, box: box, renderSize: renderSize) else { return nil }

        let attr = NSAttributedString(string: content, attributes: style.attributes(size: fontSize))
        let ctFrame = layoutFrame(attr, box: box)
        let lines = CTFrameGetLines(ctFrame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(ctFrame, CFRange(location: 0, length: 0), &origins)

        let tokens = words(in: content)
        let timings = tokenTimings(tokens, clip.wordTimings, duration: clip.durationFrames)
        let rel = frame - clip.startFrame
        let baseAttrs = style.attributes(size: fontSize)
        let font = baseAttrs[.font] as? NSFont

        for (li, line) in lines.enumerated() {
            let lineRange = CTLineGetStringRange(line)
            for (ti, tok) in tokens.enumerated() {
                guard tok.range.location >= lineRange.location,
                      tok.range.location < lineRange.location + lineRange.length else { continue }
                let st = TextAnimator.wordState(anim, word: timings[ti], rel: rel, base: style.color)
                guard st.opacity > 0 else { continue }

                let startOff = CTLineGetOffsetForStringIndex(line, tok.range.location, nil)
                let endOff = CTLineGetOffsetForStringIndex(line, tok.range.location + tok.range.length, nil)
                let penX = box.minX + origins[li].x + startOff
                let penY = origins[li].y
                let wWidth = endOff - startOff

                var attrs = baseAttrs
                attrs[.foregroundColor] = st.color.nsColor
                let wordLine = CTLineCreateWithAttributedString(
                    NSAttributedString(string: tok.text, attributes: attrs) as CFAttributedString)

                ctx.saveGState()
                ctx.setAlpha(CGFloat(st.opacity))
                let cx = penX + wWidth / 2, cy = penY + fontSize * 0.35
                ctx.translateBy(x: 0, y: -st.dy * fontSize)
                ctx.translateBy(x: cx, y: cy)
                ctx.scaleBy(x: st.scale, y: st.scale)
                ctx.translateBy(x: -cx, y: -cy)
                if let bg = st.bgColor, bg.a > 0.001 {
                    drawWordBackground(ctx, color: bg, penX: penX, penY: penY,
                                       width: wWidth, fontSize: fontSize, font: font)
                }
                ctx.textPosition = CGPoint(x: penX, y: penY)
                CTLineDraw(wordLine, ctx)
                ctx.restoreGState()
            }
        }
        return finish(ctx)
    }

    /// Rounded highlight block behind a word.
    private static func drawWordBackground(_ ctx: CGContext, color: TextStyle.RGBA,
                                           penX: CGFloat, penY: CGFloat, width: CGFloat,
                                           fontSize: CGFloat, font: NSFont?) {
        let ascent = font?.ascender ?? fontSize * 0.8
        let descent = abs(font?.descender ?? fontSize * 0.2)
        let padX = fontSize * 0.18, padY = fontSize * 0.10
        let rect = CGRect(x: penX - padX, y: penY - descent - padY,
                          width: width + padX * 2, height: ascent + descent + padY * 2)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: fontSize * 0.12,
                           cornerHeight: fontSize * 0.12, transform: nil))
        ctx.setFillColor(cgColor(color))
        ctx.fillPath()
    }

    // MARK: - Typewriter (whole-clip character reveal)

    private static func renderTypewriter(clip: Clip, content: String, style: TextStyle, box: CGRect,
                                         fontSize: CGFloat, frame: Int, renderSize: CGSize) -> CIImage? {
        guard let ctx = beginContext(style: style, box: box, renderSize: renderSize) else { return nil }
        let rel = frame - clip.startFrame
        let ns = content as NSString

        let tokens = words(in: content)
        let timings = tokenTimings(tokens, clip.wordTimings, duration: clip.durationFrames)
        var visLen = 0
        for (i, tok) in tokens.enumerated() {
            let t = timings[i]
            if rel >= t.endFrame {
                visLen = tok.range.location + tok.range.length
            } else if rel >= t.startFrame {
                let p = Double(rel - t.startFrame) / Double(max(1, t.endFrame - t.startFrame))
                visLen = tok.range.location + Int((Double(tok.range.length) * p).rounded(.down))
                break
            } else {
                break
            }
        }
        var visible = ns.substring(to: min(visLen, ns.length))
        // Caret blinks (~0.5s) until shortly after the last word finishes.
        let doneAt = timings.last?.endFrame ?? clip.durationFrames
        if rel <= doneAt + 18, (rel / 15) % 2 == 0 { visible += "|" }
        guard !visible.isEmpty else { return finish(ctx) }
        // Left-anchor so the text reveals rightward in place rather than re-centering as it grows.
        var attrs = style.attributes(size: fontSize)
        let para = NSMutableParagraphStyle()
        para.alignment = .left
        para.lineBreakMode = .byWordWrapping
        attrs[.paragraphStyle] = para
        CTFrameDraw(layoutFrame(NSAttributedString(string: visible, attributes: attrs), box: box), ctx)
        return finish(ctx)
    }

    /// Returns one timing per token. Uses word timings if counts match, otherwise splits duration evenly.
    private static func tokenTimings(_ tokens: [(range: NSRange, text: String)],
                                     _ words: [WordTiming]?, duration: Int) -> [WordTiming] {
        if let words, words.count == tokens.count { return words }
        let n = max(1, tokens.count)
        return tokens.indices.map {
            WordTiming(text: tokens[$0].text, startFrame: duration * $0 / n, endFrame: duration * ($0 + 1) / n)
        }
    }

    private static func words(in content: String) -> [(range: NSRange, text: String)] {
        let ns = content as NSString
        let ws = CharacterSet.whitespacesAndNewlines
        // A surrogate half (emoji etc.) maps to no scalar — treat it as part of a word, not whitespace.
        func isSpace(_ u: unichar) -> Bool { Unicode.Scalar(u).map(ws.contains) ?? false }
        var result: [(NSRange, String)] = []
        var i = 0
        while i < ns.length {
            while i < ns.length, isSpace(ns.character(at: i)) { i += 1 }
            guard i < ns.length else { break }
            let start = i
            while i < ns.length, !isSpace(ns.character(at: i)) { i += 1 }
            let r = NSRange(location: start, length: i - start)
            result.append((r, ns.substring(with: r)))
        }
        return result
    }

    // MARK: - Shared drawing

    private static func drawBox(_ ctx: CGContext, style: TextStyle, box: CGRect) {
        if style.background.enabled {
            ctx.setFillColor(cgColor(style.background.color))
            ctx.fill(box)
        }
    }

    private static func applyShadow(_ ctx: CGContext, style: TextStyle, renderSize: CGSize) {
        guard style.shadow.enabled else { return }
        let scale = renderSize.height / TextLayout.referenceCanvasHeight
        ctx.setShadow(
            offset: CGSize(width: style.shadow.offsetX * scale, height: -style.shadow.offsetY * scale),
            blur: max(0, CGFloat(style.shadow.blur) * scale),
            color: cgColor(style.shadow.color)
        )
    }

    static func cgColor(_ c: TextStyle.RGBA) -> CGColor {
        CGColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a))
    }

    private static func signature(_ content: String, _ s: TextStyle, _ t: Transform, _ size: CGSize) -> NSString {
        var h = Hasher()
        h.combine(content); h.combine(s); h.combine(t); h.combine(size)
        return String(h.finalize()) as NSString
    }
}
