import AppKit

enum ClipRenderer {

    private static let labelBarHeight: CGFloat = 16
    private static let waveformStripMinHeight: CGFloat = 14

    static func draw(
        _ clip: Clip,
        type: ClipType,
        in rect: NSRect,
        isSelected: Bool,
        opacity: CGFloat = 1.0,
        context: CGContext,
        cache: MediaVisualCache? = nil,
        displayName: String? = nil
    ) {
        if opacity < 1.0 {
            context.saveGState()
            context.setAlpha(opacity)
        }

        let cornerRadius = Trim.clipCornerRadius
        let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        let baseColor = type.themeColor
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

        let hasWaveform = cache?.samples(for: clip.mediaRef) != nil
        let hasThumbnails = type == .video && (cache?.thumbnails(for: clip.mediaRef) != nil)

        // Label bar at top
        let labelRect = CGRect(x: contentX, y: rect.minY, width: contentWidth, height: labelBarHeight)

        // Waveform strip at bottom (for video clips with audio, or audio-only clips)
        let waveformStripHeight = max(waveformStripMinHeight, rect.height * 0.4)
        let waveformRect: CGRect?
        if hasWaveform && (type == .audio || hasThumbnails) {
            waveformRect = CGRect(x: contentX, y: rect.maxY - waveformStripHeight, width: contentWidth, height: waveformStripHeight)
        } else {
            waveformRect = nil
        }

        // Thumbnail / main content area (between label and waveform)
        let contentY = rect.minY + labelBarHeight
        let contentBottom = waveformRect?.minY ?? rect.maxY
        let mainHeight = contentBottom - contentY

        // --- Draw visual content ---

        if type == .video, let thumbs = cache?.thumbnails(for: clip.mediaRef), !thumbs.isEmpty, mainHeight > 4 {
            let thumbRect = CGRect(x: contentX, y: contentY, width: contentWidth, height: mainHeight)
            drawThumbnailStrip(thumbnails: thumbs, clip: clip, in: thumbRect, clipRect: rect, cornerRadius: cornerRadius, context: context)
        } else if type == .image, let image = cache?.imageThumbnail(for: clip.mediaRef), mainHeight > 4 {
            let thumbRect = CGRect(x: contentX, y: contentY, width: contentWidth, height: mainHeight)
            drawTiledImage(image: image, in: thumbRect, clipRect: rect, cornerRadius: cornerRadius, context: context)
        } else if type == .audio, let samples = cache?.samples(for: clip.mediaRef), !samples.isEmpty {
            // Audio-only: waveform fills the full area below label
            let audioRect = CGRect(x: contentX, y: contentY, width: contentWidth, height: rect.maxY - contentY)
            drawWaveform(samples: samples, clip: clip, type: type, in: audioRect, context: context)
        }

        // Waveform strip at bottom (for video clips)
        if let wfRect = waveformRect, let samples = cache?.samples(for: clip.mediaRef), !samples.isEmpty {
            drawWaveform(samples: samples, clip: clip, type: type, in: wfRect, context: context)
        }

        // Color-coded left edge strip
        let stripRect = NSRect(x: rect.minX, y: rect.minY, width: stripWidth, height: rect.height)
        let stripPath = CGPath(roundedRect: stripRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        context.setFillColor(type.themeColor.cgColor)
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

        drawLabelBar(clip: clip, type: type, in: labelRect, clipRect: rect, context: context, displayName: displayName)

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

        // Map visible portion of source to sample indices
        let totalSource = clip.sourceDurationFrames
        guard totalSource > 0 else { return }
        let startFrac = Double(clip.trimStartFrame) / Double(totalSource)
        let endFrac = Double(clip.trimStartFrame + clip.durationFrames) / Double(totalSource)
        let sampleStart = Int(startFrac * Double(samples.count))
        let sampleEnd = min(samples.count, Int(endFrac * Double(samples.count)))
        guard sampleEnd > sampleStart else { return }

        let visibleSamples = Array(samples[sampleStart..<sampleEnd])
        let barCount = Int(drawWidth)
        guard barCount > 0 else { return }

        let color = type.themeColor.withAlphaComponent(0.6).cgColor
        context.setFillColor(color)

        for i in 0..<barCount {
            let sampleIdx = i * visibleSamples.count / barCount
            let sample = visibleSamples[min(sampleIdx, visibleSamples.count - 1)]
            // sample: 0=loud, 1=silence — invert and scale by volume
            let amplitude = CGFloat(1.0 - sample) * CGFloat(clip.volume)
            let barHeight = max(1, amplitude * (drawHeight - 2))
            let barY = drawRect.maxY - barHeight - 1
            context.fill(CGRect(x: drawRect.minX + CGFloat(i), y: barY, width: 1, height: barHeight))
        }
    }

    // MARK: - Video Thumbnails

    private static func drawThumbnailStrip(
        thumbnails: [(time: Double, image: CGImage)],
        clip: Clip,
        in drawRect: NSRect,
        clipRect: NSRect,
        cornerRadius: CGFloat,
        context: CGContext
    ) {
        guard drawRect.width > 4, drawRect.height > 4 else { return }

        // Compute thumbnail display width from aspect ratio
        let firstThumb = thumbnails[0].image
        let aspectRatio = CGFloat(firstThumb.width) / CGFloat(firstThumb.height)
        let thumbDisplayWidth = max(1, drawRect.height * aspectRatio)

        // Visible time range based on trim
        let fps = 30.0
        let visibleStartSec = Double(clip.trimStartFrame) / fps
        let visibleDurationSec = Double(clip.durationFrames) / fps
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

    private static func drawLabelBar(clip: Clip, type: ClipType, in labelRect: NSRect, clipRect: NSRect, context: CGContext, displayName: String? = nil) {
        guard clipRect.width > 20 else { return }

        let timecode = formatTimecode(frame: clip.durationFrames, fps: 30)
        let name = displayName ?? clip.mediaRef
        let text = "\(name)  \(timecode)"

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: AppTheme.FontSize.xs, weight: .medium),
            .foregroundColor: AppTheme.Text.primary,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let inset: CGFloat = 6
        let origin = NSPoint(
            x: labelRect.minX + inset,
            y: labelRect.minY + (labelRect.height - size.height) / 2
        )

        context.saveGState()
        context.clip(to: labelRect.insetBy(dx: inset, dy: 0))
        str.draw(at: origin)
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
