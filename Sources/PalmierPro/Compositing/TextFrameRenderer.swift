import AppKit
import CoreImage
import CoreText
import os

/// Renders a text clip as a CIImage using CoreText on the compositor queue
enum TextFrameRenderer {
    // NSCache is internally thread-safe; the compositor queue and main thread both hit it.
    nonisolated(unsafe) private static let cache: NSCache<NSString, CIImage> = {
        let cache = NSCache<NSString, CIImage>()
        cache.totalCostLimit = 256 * 1024 * 1024
        cache.countLimit = 2048
        return cache
    }()

    /// Test seam: called with the clip content each time a raster is actually drawn (cache miss).
    static let onRasterize = OSAllocatedUnfairLock<(@Sendable (String) -> Void)?>(initialState: nil)

    static func image(clip: Clip, frame: Int, renderSize: CGSize) -> CIImage? {
        guard renderSize.width >= 1, renderSize.height >= 1 else { return nil }
        var style = (clip.textStyle ?? TextStyle()).scaledVisualStyle
        style.blur = 0
        let content = style.displayText(clip.textContent ?? "")
        guard !content.isEmpty else { return nil }
        let transform = clip.transformAt(frame: frame)
        let box = boxRect(transform, renderSize)
        let boxes = layoutBoxes(style: style, box: box, renderSize: renderSize)
        let fontSize = CGFloat(style.fontSize) * (renderSize.height / TextLayout.referenceCanvasHeight)
        let anim = clip.textAnimation
        let wordMotion = anim?.isActive == true && anim?.preset.renderMode != .entrance
        let raster = rasterBounds(style: style, boxes: boxes, fontSize: fontSize,
                                  renderSize: renderSize, coversWordMotion: wordMotion)

        if let anim, anim.isActive {
            switch anim.preset.renderMode {
            case .perWord:
                return renderPerWord(clip: clip, content: content, style: style, boxes: boxes, raster: raster,
                                     fontSize: fontSize, anim: anim, frame: frame, renderSize: renderSize)
            case .typewriter:
                return renderTypewriter(clip: clip, content: content, style: style, boxes: boxes, raster: raster,
                                        fontSize: fontSize, frame: frame, renderSize: renderSize)
            case .entrance:
                break
            }
        }

        // Static text is frame-independent; entrance animation reuses it under a CI transform.
        let base = cachedImage(content: content, style: style, boxes: boxes, raster: raster,
                               renderSize: renderSize) { ctx in
            let textFrame = drawText(ctx, content: content, style: style, fontSize: fontSize, box: boxes.text)
            drawOverlines(ctx, frame: textFrame, style: style, fontSize: fontSize)
        }
        guard let base else { return nil }
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

    private struct LayoutBoxes {
        let text: CGRect
        let background: CGRect
    }

    private static func layoutBoxes(style: TextStyle, box: CGRect, renderSize: CGSize) -> LayoutBoxes {
        guard style.background.enabled else { return LayoutBoxes(text: box, background: box) }
        let scale = renderSize.height / TextLayout.referenceCanvasHeight
        let dx = max(0, CGFloat(style.background.paddingX) * scale)
        let dy = max(0, CGFloat(style.background.paddingY) * scale)
        let inset = box.insetBy(dx: dx, dy: dy)
        let text = inset.width >= 1 && inset.height >= 1
            ? inset
            : CGRect(x: box.midX - 0.5, y: box.midY - 0.5, width: 1, height: 1)
        return LayoutBoxes(text: text, background: box)
    }

    private static func rasterBounds(style: TextStyle, boxes: LayoutBoxes, fontSize: CGFloat,
                                     renderSize: CGSize, coversWordMotion: Bool) -> CGRect {
        let scale = renderSize.height / TextLayout.referenceCanvasHeight
        var rect = boxes.text.union(boxes.background)
        if style.background.enabled {
            let stroke = CGFloat(max(0, style.background.outlineWidth)) * scale / 2
            let offset = boxes.background
                .offsetBy(dx: CGFloat(style.background.offsetX) * scale,
                          dy: -CGFloat(style.background.offsetY) * scale)
                .insetBy(dx: -stroke, dy: -stroke)
            rect = rect.union(offset)
        }
        if style.border.enabled, style.border.width > 0 {
            let pad = style.glyphBorderPadding(fontSize: fontSize)
            rect = rect.insetBy(dx: -pad, dy: -pad)
        }
        if coversWordMotion {
            rect = rect.insetBy(dx: -fontSize, dy: -fontSize)
        }
        if style.shadow.enabled {
            let blur = max(0, CGFloat(style.shadow.blur) * scale)
            let dx = CGFloat(style.shadow.offsetX) * scale
            let dy = -CGFloat(style.shadow.offsetY) * scale
            rect = CGRect(x: rect.minX + min(0, dx) - blur, y: rect.minY + min(0, dy) - blur,
                          width: rect.width + abs(dx) + blur * 2, height: rect.height + abs(dy) + blur * 2)
        }
        return rect.insetBy(dx: -2, dy: -2).integral
    }

    /// Lines with their origins resolved into the frame path's coordinate space.
    private static func positionedLines(in frame: CTFrame) -> [(line: CTLine, origin: CGPoint)] {
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let frameOrigin = CTFrameGetPath(frame).boundingBox.origin
        return lines.indices.map { index in
            (lines[index], CGPoint(x: frameOrigin.x + origins[index].x, y: frameOrigin.y + origins[index].y))
        }
    }

    private static func placed(_ image: CIImage, _ raster: CGRect) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: raster.minX, y: raster.minY))
    }

    private static func cachedImage(content: String, style: TextStyle, boxes: LayoutBoxes,
                                    raster: CGRect, renderSize: CGSize, state: Int? = nil,
                                    draw: (CGContext) -> Void) -> CIImage? {
        let key = signature(content, style, boxes: boxes, raster: raster, renderSize: renderSize, state: state)
        if let cached = cache.object(forKey: key) { return placed(cached, raster) }
        onRasterize.withLock { $0 }?(content)
        guard let ctx = beginContext(style: style, backgroundBox: boxes.background, raster: raster,
                                     renderSize: renderSize) else { return nil }
        draw(ctx)
        guard let image = finish(ctx) else { return nil }
        cache.setObject(image, forKey: key, cost: Int(raster.width * raster.height) * 4)
        return placed(image, raster)
    }

    private static func stateHash<Value: Hashable>(_ value: Value) -> Int {
        var h = Hasher()
        h.combine(value)
        return h.finalize()
    }

    private static func beginContext(style: TextStyle, backgroundBox: CGRect, raster: CGRect,
                                     renderSize: CGSize) -> CGContext? {
        guard raster.width >= 1, raster.height >= 1, let ctx = CGContext(
            data: nil, width: Int(raster.width), height: Int(raster.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(true)
        ctx.setAllowsFontSubpixelPositioning(true)
        ctx.setShouldSubpixelPositionFonts(true)
        ctx.translateBy(x: -raster.minX, y: -raster.minY)
        drawBox(ctx, style: style, box: backgroundBox, renderSize: renderSize)
        applyShadow(ctx, style: style, renderSize: renderSize)
        return ctx
    }

    /// Premultiplied, NO color space — FrameRenderer unpremultiplies it like a source buffer.
    private static func finish(_ ctx: CGContext) -> CIImage? {
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
    }

    private static func drawOverlines(_ ctx: CGContext, frame: CTFrame, style: TextStyle,
                                      fontSize: CGFloat) {
        guard style.isOverlined else { return }
        let font = style.resolvedFont(size: fontSize)
        for (line, origin) in positionedLines(in: frame) {
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line))
            drawOverline(ctx, x: origin.x, y: origin.y, width: width, font: font, color: style.color)
        }
    }

    private static func drawOverline(_ ctx: CGContext, x: CGFloat, y: CGFloat, width: CGFloat,
                                     font: NSFont, color: TextStyle.RGBA) {
        guard width > 0 else { return }
        let ctFont = font as CTFont
        let thickness = max(1, CTFontGetUnderlineThickness(ctFont))
        ctx.setLineWidth(thickness)
        ctx.setStrokeColor(cgColor(color))
        let top = y + CTFontGetAscent(ctFont) - thickness / 2
        ctx.strokeLineSegments(between: [CGPoint(x: x, y: top), CGPoint(x: x + width, y: top)])
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

    /// Lays out each word's position in the raster; `nil` if the word doesn't appear on any line.
    private struct PerWordLayout {
        struct TokenPen { let x: CGFloat; let y: CGFloat; let width: CGFloat }

        let tokens: [(range: NSRange, text: String)]
        let timings: [WordTiming]
        let pens: [TokenPen?]
    }

    private final class Cached<Value> {
        let value: Value; init(_ value: Value) { self.value = value }
    }

    nonisolated(unsafe) private static let layoutCache: NSCache<NSString, Cached<PerWordLayout>> = {
        let cache = NSCache<NSString, Cached<PerWordLayout>>()
        cache.countLimit = 512
        return cache
    }()

    private static func perWordLayout(clip: Clip, content: String, style: TextStyle, boxes: LayoutBoxes,
                                      raster: CGRect, fontSize: CGFloat, renderSize: CGSize) -> PerWordLayout {
        var h = Hasher()
        h.combine(clip.wordTimings); h.combine(clip.durationFrames)
        let key = signature(content, style, boxes: boxes, raster: raster, renderSize: renderSize,
                            state: h.finalize())
        if let cached = layoutCache.object(forKey: key) { return cached.value }

        let ctFrame = TextLayout.frame(
            for: NSAttributedString(string: content, attributes: style.attributes(size: fontSize)),
            in: boxes.text
        )

        let tokens = words(in: content)
        let timings = tokenTimings(tokens, clip.wordTimings, duration: clip.durationFrames)
        var pens = [PerWordLayout.TokenPen?](repeating: nil, count: tokens.count)
        for (line, origin) in positionedLines(in: ctFrame) {
            let lineRange = CTLineGetStringRange(line)
            for (ti, tok) in tokens.enumerated() {
                guard tok.range.location >= lineRange.location,
                      tok.range.location < lineRange.location + lineRange.length else { continue }
                let startOff = CTLineGetOffsetForStringIndex(line, tok.range.location, nil)
                let endOff = CTLineGetOffsetForStringIndex(line, tok.range.location + tok.range.length, nil)
                pens[ti] = PerWordLayout.TokenPen(
                    x: origin.x + startOff - raster.minX,
                    y: origin.y - raster.minY,
                    width: endOff - startOff
                )
            }
        }

        let layout = PerWordLayout(tokens: tokens, timings: timings, pens: pens)
        layoutCache.setObject(Cached(layout), forKey: key)
        return layout
    }

    private static func renderPerWord(clip: Clip, content: String, style: TextStyle, boxes: LayoutBoxes,
                                      raster: CGRect, fontSize: CGFloat, anim: TextAnimation, frame: Int,
                                      renderSize: CGSize) -> CIImage? {
        let layout = perWordLayout(clip: clip, content: content, style: style, boxes: boxes,
                                   raster: raster, fontSize: fontSize, renderSize: renderSize)
        let rel = frame - clip.startFrame
        let states = layout.timings.enumerated().map { index, timing in
            let nextWord = layout.timings.indices.contains(index + 1)
                ? layout.timings[index + 1]
                : nil
            return TextAnimator.wordState(
                anim,
                word: timing,
                nextWord: nextWord,
                rel: rel,
                base: style.color
            )
        }

        // The output depends on the frame only through the word states.
        return cachedImage(content: content, style: style, boxes: boxes, raster: raster,
                           renderSize: renderSize, state: stateHash(states)) { ctx in
            let fillAttrs = style.attributes(size: fontSize)
            let undercoatAttrs = style.drawsGlyphOutline
                ? style.outlineUndercoatAttributes(size: fontSize)
                : nil
            let font = fillAttrs[.font] as? NSFont

            var placements: [WordPlacement] = []
            for (ti, pen) in layout.pens.enumerated() {
                guard let pen else { continue }
                let st = states[ti]
                guard st.opacity > 0 else { continue }
                var wordFillAttrs = fillAttrs
                wordFillAttrs[.foregroundColor] = st.color.nsColor
                placements.append(WordPlacement(
                    state: st,
                    penX: pen.x + raster.minX,
                    penY: pen.y + raster.minY,
                    width: pen.width,
                    fillLine: CTLineCreateWithAttributedString(
                        NSAttributedString(string: layout.tokens[ti].text, attributes: wordFillAttrs) as CFAttributedString),
                    undercoatLine: undercoatAttrs.map {
                        CTLineCreateWithAttributedString(
                            NSAttributedString(string: layout.tokens[ti].text, attributes: $0) as CFAttributedString)
                    }
                ))
            }

            drawWordPlacements(ctx, placements, style: style, fontSize: fontSize, font: font)
        }
    }

    private struct WordPlacement {
        let state: TextAnimator.WordState
        let penX: CGFloat
        let penY: CGFloat
        let width: CGFloat
        let fillLine: CTLine
        let undercoatLine: CTLine?
    }

    /// Backgrounds, then undercoats, then fills, so no word's outline paints over a neighbor's fill.
    private static func drawWordPlacements(_ ctx: CGContext, _ placements: [WordPlacement],
                                           style: TextStyle, fontSize: CGFloat, font: NSFont?) {
        guard !placements.isEmpty else { return }

        func withWordState(_ p: WordPlacement, _ draw: () -> Void) {
            ctx.saveGState()
            ctx.setAlpha(CGFloat(p.state.opacity))
            let cx = p.penX + p.width / 2, cy = p.penY + fontSize * 0.35
            ctx.translateBy(x: 0, y: -p.state.dy * fontSize)
            ctx.translateBy(x: cx, y: cy)
            ctx.scaleBy(x: p.state.scale, y: p.state.scale)
            ctx.translateBy(x: -cx, y: -cy)
            draw()
            ctx.restoreGState()
        }

        func drawFillAndOverline(_ p: WordPlacement) {
            ctx.textPosition = CGPoint(x: p.penX, y: p.penY)
            CTLineDraw(p.fillLine, ctx)
            if style.isOverlined, let font {
                drawOverline(ctx, x: p.penX, y: p.penY, width: p.width, font: font, color: p.state.color)
            }
        }

        // One layer applies the context shadow once to the assembled block.
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        for p in placements where p.state.bgColor.map({ $0.a > 0.001 }) == true {
            withWordState(p) {
                drawWordBackground(ctx, color: p.state.bgColor!, penX: p.penX, penY: p.penY,
                                   width: p.width, fontSize: fontSize, font: font)
            }
        }
        if placements.contains(where: { $0.undercoatLine != nil }) {
            drawUndercoat(ctx) {
                for p in placements {
                    guard let undercoat = p.undercoatLine else { continue }
                    withWordState(p) {
                        ctx.textPosition = CGPoint(x: p.penX, y: p.penY)
                        CTLineDraw(undercoat, ctx)
                    }
                }
            }
        }
        for p in placements {
            withWordState(p) { drawFillAndOverline(p) }
        }
        ctx.endTransparencyLayer()
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

    private static func renderTypewriter(clip: Clip, content: String, style: TextStyle, boxes: LayoutBoxes,
                                         raster: CGRect, fontSize: CGFloat, frame: Int, renderSize: CGSize) -> CIImage? {
        let holdFrames = 18
        let rel = frame - clip.startFrame
        let ns = content as NSString

        let tokens = words(in: content)
        let timings = tokenTimings(tokens, clip.wordTimings, duration: clip.durationFrames)
        var visLen = 0
        for (i, tok) in tokens.enumerated() {
            let t = timings[i]
            let revealEnd: Int
            if i == tokens.count - 1, t.endFrame > t.startFrame {
                let desiredHold = min(holdFrames, max(1, clip.durationFrames / 3))
                let existingHold = max(1, clip.durationFrames - t.endFrame + 1)
                let timingSpan = t.endFrame - t.startFrame
                let minimumRevealFrames = min(timingSpan - 1, tok.range.length) + 1
                let availableHoldFrames = timingSpan - minimumRevealFrames
                let extraHold = min(max(0, desiredHold - existingHold), availableHoldFrames)
                revealEnd = max(t.startFrame + 1, t.endFrame - extraHold)
            } else {
                revealEnd = t.endFrame
            }

            if rel >= revealEnd {
                visLen = tok.range.location + tok.range.length
            } else if rel >= t.startFrame {
                let span = revealEnd - t.startFrame
                let p = span == 1
                    ? 1
                    : Double(rel - t.startFrame) / Double(span - 1)
                visLen = tok.range.location + Int((Double(tok.range.length) * p).rounded(.down))
                break
            } else {
                break
            }
        }
        var visible = ns.substring(to: min(visLen, ns.length))
        // Caret blinks (~0.5s) until shortly after the last word finishes.
        let doneAt = timings.last?.endFrame ?? clip.durationFrames
        if rel <= doneAt + holdFrames, (rel / 15) % 2 == 0 { visible += "|" }

        // The output depends on the frame only through the visible substring.
        return cachedImage(content: content, style: style, boxes: boxes, raster: raster,
                           renderSize: renderSize, state: stateHash(visible)) { ctx in
            guard !visible.isEmpty else { return }
            // Left-anchor so the text reveals rightward in place rather than re-centering as it grows.
            let textFrame = drawText(
                ctx,
                content: visible,
                style: style,
                fontSize: fontSize,
                box: boxes.text,
                alignment: .left,
                verticallySizedFor: content
            )
            drawOverlines(ctx, frame: textFrame, style: style, fontSize: fontSize)
        }
    }

    /// Returns one timing per token, aligning transcript spans when token counts differ.
    static func tokenTimings(_ tokens: [(range: NSRange, text: String)],
                             _ words: [WordTiming]?, duration: Int) -> [WordTiming] {
        guard !tokens.isEmpty else { return [] }
        guard let words, !words.isEmpty else { return evenTokenTimings(tokens, duration: duration) }
        if words.count == tokens.count {
            return zip(tokens, words).map { pair in
                let (token, timing) = pair
                return clampedTiming(timing, text: token.text, duration: duration)
            }
        }
        return alignedTokenTimings(tokens, words: words, duration: duration)
            ?? evenTokenTimings(tokens, duration: duration)
    }

    private static func evenTokenTimings(_ tokens: [(range: NSRange, text: String)], duration: Int) -> [WordTiming] {
        let duration = max(0, duration)
        let n = max(1, tokens.count)
        return tokens.indices.map {
            WordTiming(text: tokens[$0].text, startFrame: duration * $0 / n, endFrame: duration * ($0 + 1) / n)
        }
    }

    private struct TimingAlignmentGroup {
        let tokenRange: Range<Int>
        let wordRange: Range<Int>
    }

    private static func alignedTokenTimings(
        _ tokens: [(range: NSRange, text: String)],
        words: [WordTiming],
        duration: Int
    ) -> [WordTiming]? {
        var result: [WordTiming] = []
        var tokenIndex = 0
        var wordIndex = 0

        while tokenIndex < tokens.count, wordIndex < words.count {
            guard let group = nextAlignedTimingGroup(
                tokens,
                words: words,
                tokenStart: tokenIndex,
                wordStart: wordIndex
            ) else { return nil }

            result.append(contentsOf: timingsForAlignedGroup(
                tokens,
                words: words,
                tokenRange: group.tokenRange,
                wordRange: group.wordRange,
                duration: duration
            ))
            tokenIndex = group.tokenRange.upperBound
            wordIndex = group.wordRange.upperBound
        }

        guard tokenIndex == tokens.count, wordIndex == words.count, result.count == tokens.count else { return nil }
        return result
    }

    private static func nextAlignedTimingGroup(
        _ tokens: [(range: NSRange, text: String)],
        words: [WordTiming],
        tokenStart: Int,
        wordStart: Int
    ) -> TimingAlignmentGroup? {
        var tokenEnd = tokenStart
        var wordEnd = wordStart
        var tokenText = ""
        var wordText = ""

        while tokenEnd < tokens.count || wordEnd < words.count {
            if shouldAppendTokenText(
                tokenText: tokenText,
                wordText: wordText,
                tokenEnd: tokenEnd,
                wordEnd: wordEnd,
                tokenCount: tokens.count,
                wordCount: words.count
            ) {
                tokenText += normalizedTimingText(tokens[tokenEnd].text)
                tokenEnd += 1
            } else {
                wordText += normalizedTimingText(words[wordEnd].text)
                wordEnd += 1
            }

            if !tokenText.isEmpty, tokenText == wordText {
                return TimingAlignmentGroup(
                    tokenRange: tokenStart..<tokenEnd,
                    wordRange: wordStart..<wordEnd
                )
            }
        }

        return nil
    }

    private static func shouldAppendTokenText(
        tokenText: String,
        wordText: String,
        tokenEnd: Int,
        wordEnd: Int,
        tokenCount: Int,
        wordCount: Int
    ) -> Bool {
        if wordEnd >= wordCount { return true }
        if tokenEnd >= tokenCount { return false }
        return tokenText.count <= wordText.count
    }

    private static func timingsForAlignedGroup(
        _ tokens: [(range: NSRange, text: String)],
        words: [WordTiming],
        tokenRange: Range<Int>,
        wordRange: Range<Int>,
        duration: Int
    ) -> [WordTiming] {
        if tokenRange.count == wordRange.count {
            return zip(tokenRange, wordRange).map { pair in
                let (tokenIndex, wordIndex) = pair
                return clampedTiming(words[wordIndex], text: tokens[tokenIndex].text, duration: duration)
            }
        }

        let maxFrame = max(0, duration)
        let start = min(max(0, words[wordRange.lowerBound].startFrame), maxFrame)
        let end = min(max(start, words[wordRange.upperBound - 1].endFrame), maxFrame)
        let span = max(0, end - start)
        return tokenRange.enumerated().map { offset, tokenIndex in
            let tokenStart = start + span * offset / tokenRange.count
            let tokenEnd: Int
            if offset == tokenRange.count - 1 {
                tokenEnd = end
            } else {
                tokenEnd = start + span * (offset + 1) / tokenRange.count
            }
            return WordTiming(text: tokens[tokenIndex].text, startFrame: tokenStart, endFrame: tokenEnd)
        }
    }

    private static func clampedTiming(_ timing: WordTiming, text: String, duration: Int) -> WordTiming {
        let maxFrame = max(0, duration)
        let start = min(max(0, timing.startFrame), maxFrame)
        let end = min(max(start, timing.endFrame), maxFrame)
        return WordTiming(text: text, startFrame: start, endFrame: end)
    }

    private static func normalizedTimingText(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            out += String(scalar).lowercased()
        }
        return out
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

    /// Outlined text draws undercoat then fill in one layer so the context shadow applies once.
    @discardableResult
    private static func drawText(
        _ ctx: CGContext,
        content: String,
        style: TextStyle,
        fontSize: CGFloat,
        box: CGRect,
        alignment: NSTextAlignment? = nil,
        verticallySizedFor sizingContent: String? = nil
    ) -> CTFrame {
        func attributed(_ attrs: [NSAttributedString.Key: Any], _ string: String) -> NSAttributedString {
            var attrs = attrs
            if let alignment {
                attrs[.paragraphStyle] = style.paragraphStyle(size: fontSize, alignment: alignment)
            }
            return NSAttributedString(string: string, attributes: attrs)
        }

        let fillAttrs = style.attributes(size: fontSize)
        let sizing = sizingContent.map { attributed(fillAttrs, $0) }
        let fillFrame = TextLayout.frame(for: attributed(fillAttrs, content), in: box, verticallySizedFor: sizing)

        guard style.drawsGlyphOutline else {
            CTFrameDraw(fillFrame, ctx)
            return fillFrame
        }

        let undercoatFrame = TextLayout.frame(
            for: attributed(style.outlineUndercoatAttributes(size: fontSize), content),
            in: box,
            verticallySizedFor: sizing
        )
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        drawUndercoat(ctx) { CTFrameDraw(undercoatFrame, ctx) }
        CTFrameDraw(fillFrame, ctx)
        ctx.endTransparencyLayer()
        return fillFrame
    }

    /// Core Text strokes honor context join state; round joins prevent miter spikes on pointed glyphs.
    private static func drawUndercoat(_ ctx: CGContext, _ draw: () -> Void) {
        ctx.saveGState()
        ctx.setLineJoin(.round)
        draw()
        ctx.restoreGState()
    }

    private static func drawBox(_ ctx: CGContext, style: TextStyle, box: CGRect, renderSize: CGSize) {
        guard style.background.enabled else { return }
        let scale = renderSize.height / TextLayout.referenceCanvasHeight
        let background = style.background
        let rect = box.offsetBy(
            dx: CGFloat(background.offsetX) * scale,
            dy: -CGFloat(background.offsetY) * scale
        )
        let radius = min(
            max(0, CGFloat(background.cornerRadius) * scale),
            min(rect.width, rect.height) / 2
        )
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )

        if background.color.a > 0 {
            ctx.addPath(path)
            ctx.setFillColor(cgColor(background.color))
            ctx.fillPath()
        }
        if background.outlineWidth > 0, background.outlineColor.a > 0 {
            ctx.addPath(path)
            ctx.setStrokeColor(cgColor(background.outlineColor))
            ctx.setLineWidth(CGFloat(background.outlineWidth) * scale)
            ctx.strokePath()
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

    private static func signature(_ content: String, _ s: TextStyle, boxes: LayoutBoxes, raster: CGRect,
                                  renderSize: CGSize, state: Int? = nil) -> NSString {
        func quantized(_ v: CGFloat) -> Int { Int((v * 64).rounded()) }
        var h = Hasher()
        h.combine(content); h.combine(s)
        h.combine(quantized(boxes.text.minX - raster.minX)); h.combine(quantized(boxes.text.minY - raster.minY))
        h.combine(quantized(boxes.text.width)); h.combine(quantized(boxes.text.height))
        h.combine(quantized(boxes.background.minX - raster.minX)); h.combine(quantized(boxes.background.minY - raster.minY))
        h.combine(quantized(boxes.background.width)); h.combine(quantized(boxes.background.height))
        h.combine(raster.width); h.combine(raster.height)
        h.combine(renderSize)
        if let state { h.combine(state) }
        return String(h.finalize()) as NSString
    }
}
