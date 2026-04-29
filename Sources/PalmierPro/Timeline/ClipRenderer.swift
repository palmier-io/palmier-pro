import AppKit

enum ClipRenderer {

    static let labelBarHeight: CGFloat = 16

    static let fadeHandleSize: CGFloat = 7        // visual square edge length
    static let fadeHandleHitSize: CGFloat = 18    // hit zone edge length
    static let fadeHandleEdgeInset: CGFloat = 9   // min offset from clip edge so handle never overlaps trim

    static func draw(
        _ clip: Clip,
        type: ClipType,
        in rect: NSRect,
        isSelected: Bool,
        opacity: CGFloat = 1.0,
        context: CGContext,
        cache: MediaVisualCache? = nil,
        displayName: String? = nil,
        linkOffset: Int? = nil,
        fps: Int
    ) {
        if opacity < 1.0 {
            context.saveGState()
            context.setAlpha(opacity)
        }

        let cornerRadius = Trim.clipCornerRadius
        let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)


        let colorType = clip.sourceClipType
        let baseColor = colorType.themeColor
        let fill = isSelected
            ? baseColor.withAlphaComponent(0.45)
            : baseColor.withAlphaComponent(0.3)
        context.setFillColor(fill.cgColor)
        context.addPath(path)
        context.fillPath()

        // --- Layout zones ---
        let stripWidth: CGFloat = 3
        let handleW = Trim.handleWidth
        let contentX = rect.minX + stripWidth + 1
        let contentWidth = rect.width - stripWidth - 1 - handleW

        // Label bar at top
        let labelRect = CGRect(x: contentX, y: rect.minY, width: contentWidth, height: labelBarHeight)

        let contentY = rect.minY + labelBarHeight
        let mainHeight = rect.maxY - contentY

        // --- Draw visual content ---

        if type == .video, let thumbs = cache?.thumbnails(for: clip.mediaRef), !thumbs.isEmpty, mainHeight > 4 {
            let thumbRect = CGRect(x: contentX, y: contentY, width: contentWidth, height: mainHeight)
            drawThumbnailStrip(thumbnails: thumbs, clip: clip, in: thumbRect, clipRect: rect, cornerRadius: cornerRadius, fps: fps, context: context)
        } else if type == .image, let image = cache?.imageThumbnail(for: clip.mediaRef), mainHeight > 4 {
            let thumbRect = CGRect(x: contentX, y: contentY, width: contentWidth, height: mainHeight)
            drawTiledImage(image: image, in: thumbRect, clipRect: rect, cornerRadius: cornerRadius, context: context)
        } else if type == .audio, let samples = cache?.samples(for: clip.mediaRef), !samples.isEmpty {
            let audioRect = CGRect(x: contentX, y: contentY, width: contentWidth, height: mainHeight)
            drawWaveform(samples: samples, clip: clip, type: colorType, in: audioRect, context: context)
        }

        if type == .audio {
            drawFadeHandles(clip: clip, in: rect, isSelected: isSelected, context: context)
        }

        // Color-coded left edge strip (uses the same source-type as the fill).
        let stripRect = NSRect(x: rect.minX, y: rect.minY, width: stripWidth, height: rect.height)
        let stripPath = CGPath(roundedRect: stripRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        context.setFillColor(colorType.themeColor.cgColor)
        context.addPath(stripPath)
        context.fillPath()

        // Border
        if isSelected {
            context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
            context.setLineWidth(1.5)
            context.addPath(path)
            context.strokePath()
        } else {
            context.setStrokeColor(AppTheme.Border.primary.cgColor)
            context.setLineWidth(0.5)
            context.addPath(path)
            context.strokePath()
        }

        drawLabelBar(clip: clip, type: type, in: labelRect, clipRect: rect, context: context, displayName: displayName, fps: fps)

        if let linkOffset, linkOffset != 0 {
            drawOffsetBadge(frames: linkOffset, in: rect, context: context)
        }

        drawTrimHandles(in: rect, context: context)

        if opacity < 1.0 {
            context.restoreGState()
        }
    }

    // MARK: - Waveform

    private static func drawWaveform(
        samples: [Float],
        clip: Clip,
        type: ClipType,
        in drawRect: NSRect,
        context: CGContext
    ) {
        let drawWidth = drawRect.width
        let drawHeight = drawRect.height
        guard drawWidth > 2, drawHeight > 2 else { return }

        // Map visible portion of source to sample indices.
        let totalSource = clip.sourceDurationFrames
        guard totalSource > 0 else { return }
        let startFrac = Double(clip.trimStartFrame) / Double(totalSource)
        let endFrac = Double(clip.trimStartFrame + clip.sourceFramesConsumed) / Double(totalSource)
        let sampleStart = Int(startFrac * Double(samples.count))
        let sampleEnd = min(samples.count, Int(endFrac * Double(samples.count)))
        guard sampleEnd > sampleStart else { return }

        let visibleSamples = Array(samples[sampleStart..<sampleEnd])
        let barCount = Int(drawWidth)
        guard barCount > 0 else { return }

        let color = (type.themeColor.blended(withFraction: 0.3, of: .white) ?? type.themeColor).withAlphaComponent(0.85).cgColor
        context.setFillColor(color)

        let fadeIn = CGFloat(clip.audioFadeInFrames)
        let fadeOut = CGFloat(clip.audioFadeOutFrames)
        let dur = CGFloat(max(1, clip.durationFrames))
        let frameStep = dur / CGFloat(barCount)
        let invFadeIn = fadeIn > 0 ? 1 / fadeIn : 0
        let invFadeOut = fadeOut > 0 ? 1 / fadeOut : 0
        let volF = CGFloat(clip.volume)

        for i in 0..<barCount {
            let sampleIdx = i * visibleSamples.count / barCount
            let sample = visibleSamples[min(sampleIdx, visibleSamples.count - 1)]
            // sample: 0=loud, 1=silence — invert and scale by volume
            let posFrames = CGFloat(i) * frameStep
            let inMul: CGFloat = fadeIn > 0 ? min(1, posFrames * invFadeIn) : 1
            let outMul: CGFloat = fadeOut > 0 ? min(1, (dur - posFrames) * invFadeOut) : 1
            let envelope = min(inMul, outMul)
            let amplitude = min(1.0, CGFloat(1.0 - sample) * volF * envelope)
            let barHeight = max(1, amplitude * (drawHeight - 2))
            let barY = drawRect.maxY - barHeight - 1
            context.fill(CGRect(x: drawRect.minX + CGFloat(i), y: barY, width: 1, height: barHeight))
        }
    }

    // MARK: - Fade handles

    private static func drawFadeHandles(clip: Clip, in rect: NSRect, isSelected: Bool, context: CGContext) {
        let pxPerFrame = clip.durationFrames > 0 ? rect.width / CGFloat(clip.durationFrames) : 0
        let alpha: CGFloat = isSelected ? 0.95 : (clip.audioFadeInFrames > 0 || clip.audioFadeOutFrames > 0 ? 0.75 : 0.0)
        guard alpha > 0 else { return }

        let envTop = rect.minY + labelBarHeight
        let envBottom = rect.maxY - 1
        let color = NSColor.white.withAlphaComponent(alpha).cgColor
        let half = fadeHandleSize / 2

        for edge in FadeEdge.allCases {
            let frames = clip[keyPath: edge.fadeKeyPath]
            let cx = TimelineGeometry.audioFadeHandleX(in: rect, fadeFrames: frames, edge: edge, pxPerFrame: pxPerFrame)

            if frames > 0 {
                let cornerX = edge == .left ? rect.minX : rect.maxX
                context.setStrokeColor(color)
                context.setLineWidth(1)
                context.move(to: CGPoint(x: cornerX, y: envBottom))
                context.addLine(to: CGPoint(x: cx, y: envTop))
                context.strokePath()
            }

            context.setFillColor(color)
            context.fill(CGRect(x: cx - half, y: envTop - half, width: fadeHandleSize, height: fadeHandleSize))
        }
    }

    // MARK: - Video Thumbnails

    private static func drawThumbnailStrip(
        thumbnails: [(time: Double, image: CGImage)],
        clip: Clip,
        in drawRect: NSRect,
        clipRect: NSRect,
        cornerRadius: CGFloat,
        fps: Int,
        context: CGContext
    ) {
        guard drawRect.width > 4, drawRect.height > 4 else { return }

        // Compute thumbnail display width from aspect ratio
        let firstThumb = thumbnails[0].image
        let aspectRatio = CGFloat(firstThumb.width) / CGFloat(firstThumb.height)
        let thumbDisplayWidth = max(1, drawRect.height * aspectRatio)

        // Visible time range based on trim
        let fpsD = Double(max(1, fps))
        let visibleStartSec = Double(clip.trimStartFrame) / fpsD
        let visibleDurationSec = Double(clip.sourceFramesConsumed) / fpsD
        guard visibleDurationSec > 0 else { return }

        context.saveGState()
        let clipPath = CGPath(roundedRect: clipRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        context.addPath(clipPath)
        context.clip()
        context.clip(to: drawRect)

        // Tile thumbnails across the drawable area, selecting the nearest frame per tile
        let maxTiles = 200
        var x = drawRect.minX
        var tileCount = 0
        while x < drawRect.maxX, tileCount < maxTiles {
            let frac = (x - drawRect.minX) / drawRect.width
            let timeSec = visibleStartSec + frac * visibleDurationSec

            var best = thumbnails[0]
            var bestDist = abs(best.time - timeSec)
            for thumb in thumbnails {
                let dist = abs(thumb.time - timeSec)
                if dist < bestDist {
                    best = thumb
                    bestDist = dist
                }
            }

            let tileRect = CGRect(x: x, y: drawRect.minY, width: thumbDisplayWidth, height: drawRect.height)
            context.saveGState()
            context.translateBy(x: 0, y: tileRect.midY * 2)
            context.scaleBy(x: 1, y: -1)
            context.draw(best.image, in: tileRect)
            context.restoreGState()
            x += thumbDisplayWidth
            tileCount += 1
        }

        context.restoreGState()
    }

    // MARK: - Image Thumbnail (tiled)

    private static func drawTiledImage(
        image: CGImage,
        in drawRect: NSRect,
        clipRect: NSRect,
        cornerRadius: CGFloat,
        context: CGContext
    ) {
        guard drawRect.width > 4, drawRect.height > 4 else { return }
        let aspectRatio = CGFloat(image.width) / CGFloat(image.height)
        let thumbDisplayWidth = max(1, drawRect.height * aspectRatio)

        context.saveGState()
        let clipPath = CGPath(roundedRect: clipRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        context.addPath(clipPath)
        context.clip()
        context.clip(to: drawRect)

        tileImage(image, width: thumbDisplayWidth, in: drawRect, context: context)

        context.restoreGState()
    }

    // MARK: - Shared tiling

    private static func tileImage(
        _ image: CGImage,
        width thumbDisplayWidth: CGFloat,
        in drawRect: NSRect,
        context: CGContext
    ) {
        let maxTiles = 200
        var x = drawRect.minX
        var tileCount = 0
        while x < drawRect.maxX, tileCount < maxTiles {
            let tileRect = CGRect(x: x, y: drawRect.minY, width: thumbDisplayWidth, height: drawRect.height)
            context.saveGState()
            context.translateBy(x: 0, y: tileRect.midY * 2)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: tileRect)
            context.restoreGState()
            x += thumbDisplayWidth
            tileCount += 1
        }
    }

    // MARK: - Label Bar

    private static func drawLabelBar(clip: Clip, type: ClipType, in labelRect: NSRect, clipRect: NSRect, context: CGContext, displayName: String? = nil, fps: Int) {
        guard clipRect.width > 20 else { return }

        let timecode = formatTimecode(frame: clip.durationFrames, fps: fps)
        let rawName = displayName ?? clip.mediaRef
        let name = rawName.firstNonEmptyLine()
        let text = "\(name)  \(timecode)"

        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: AppTheme.FontSize.xs, weight: .medium),
            .foregroundColor: AppTheme.Text.primary,
        ]
        let attributed = NSMutableAttributedString(string: text, attributes: baseAttrs)
        if clip.linkGroupId != nil {
            attributed.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: (name as NSString).length))
        }
        let size = attributed.size()
        let inset: CGFloat = 6
        let origin = NSPoint(
            x: labelRect.minX + inset,
            y: labelRect.minY + (labelRect.height - size.height) / 2
        )

        context.saveGState()
        context.clip(to: labelRect.insetBy(dx: inset, dy: 0))
        attributed.draw(at: origin)
        context.restoreGState()
    }

    // MARK: - Out-of-sync offset badge

    private static let offsetBadgeColor = NSColor(red: 1.0, green: 0.28, blue: 0.28, alpha: 1.0)

    private static func drawOffsetBadge(frames: Int, in rect: NSRect, context: CGContext) {
        let text = frames > 0 ? "+\(frames)" : "\(frames)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: AppTheme.FontSize.xs, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let textSize = str.size()
        let padH: CGFloat = 4
        let padV: CGFloat = 1
        let badgeWidth = textSize.width + padH * 2
        let badgeHeight = textSize.height + padV * 2
        let handleW = Trim.handleWidth
        let badgeRect = NSRect(
            x: rect.maxX - handleW - badgeWidth - 2,
            y: rect.minY + 2,
            width: badgeWidth,
            height: badgeHeight
        )
        guard badgeRect.minX > rect.minX + 6 else { return }

        context.saveGState()
        let path = CGPath(roundedRect: badgeRect, cornerWidth: 3, cornerHeight: 3, transform: nil)
        context.setFillColor(offsetBadgeColor.cgColor)
        context.addPath(path)
        context.fillPath()
        str.draw(at: NSPoint(x: badgeRect.minX + padH, y: badgeRect.minY + padV))
        context.restoreGState()
    }

    // MARK: - Trim handles

    private static func drawTrimHandles(in rect: NSRect, context: CGContext) {
        let w = Trim.handleWidth
        context.setFillColor(AppTheme.Text.muted.cgColor)
        // Left handle
        context.fill(NSRect(x: rect.minX, y: rect.minY, width: w, height: rect.height))
        // Right handle
        context.fill(NSRect(x: rect.maxX - w, y: rect.minY, width: w, height: rect.height))
    }
}

private extension String {
    func firstNonEmptyLine() -> String {
        for line in split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return self
    }
}
