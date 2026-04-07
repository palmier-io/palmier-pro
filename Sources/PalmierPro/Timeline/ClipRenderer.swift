import AppKit

enum ClipRenderer {

    static func draw(
        _ clip: Clip,
        type: ClipType,
        in rect: NSRect,
        isSelected: Bool,
        opacity: CGFloat = 1.0,
        context: CGContext,
        cache: MediaVisualCache? = nil
    ) {
        if opacity < 1.0 {
            context.saveGState()
            context.setAlpha(opacity)
        }

        let cornerRadius = Trim.clipCornerRadius
        let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        // Fill
        let fill = isSelected ? AppTheme.ClipFill.selected : AppTheme.ClipFill.base
        context.setFillColor(fill.cgColor)
        context.addPath(path)
        context.fillPath()

        // Visual content (waveform or thumbnails) — drawn after fill, before label
        let stripWidth: CGFloat = 3
        if type == .video, let thumbs = cache?.thumbnails(for: clip.mediaRef), !thumbs.isEmpty {
            drawThumbnailStrip(thumbnails: thumbs, clip: clip, stripWidth: stripWidth, in: rect, cornerRadius: cornerRadius, context: context)
        } else if type == .audio || type == .video {
            if let samples = cache?.samples(for: clip.mediaRef), !samples.isEmpty {
                drawWaveform(samples: samples, clip: clip, type: type, stripWidth: stripWidth, in: rect, context: context)
            }
        }

        // Color-coded left edge strip
        let stripRect = NSRect(x: rect.minX, y: rect.minY, width: stripWidth, height: rect.height)
        let stripPath = CGPath(roundedRect: stripRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        context.setFillColor(type.themeColor.cgColor)
        context.addPath(stripPath)
        context.fillPath()

        // Border
        let borderColor = isSelected
            ? type.themeColor.withAlphaComponent(0.6).cgColor
            : AppTheme.Border.primary.cgColor
        context.setStrokeColor(borderColor)
        context.setLineWidth(isSelected ? 1 : 0.5)
        context.addPath(path)
        context.strokePath()

        // Label
        drawLabel(clip.mediaRef, in: rect, context: context)

        // Trim handles
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
        stripWidth: CGFloat,
        in rect: NSRect,
        context: CGContext
    ) {
        let handleW = Trim.handleWidth
        let drawX = rect.minX + stripWidth + 1
        let drawWidth = rect.width - stripWidth - 1 - handleW
        guard drawWidth > 2 else { return }

        let drawY = rect.minY + 2
        let drawHeight = rect.height - 4

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

        let color = type.themeColor.withAlphaComponent(0.5).cgColor
        context.setFillColor(color)

        for i in 0..<barCount {
            let sampleIdx = i * visibleSamples.count / barCount
            let sample = visibleSamples[min(sampleIdx, visibleSamples.count - 1)]
            // sample is 0=loud, 1=silence; invert for bar height
            let amplitude = CGFloat(1.0 - sample)
            let barHeight = max(1, amplitude * drawHeight)
            let barY = drawY + (drawHeight - barHeight) / 2
            context.fill(CGRect(x: drawX + CGFloat(i), y: barY, width: 1, height: barHeight))
        }
    }

    // MARK: - Video Thumbnails

    private static func drawThumbnailStrip(
        thumbnails: [(time: Double, image: CGImage)],
        clip: Clip,
        stripWidth: CGFloat,
        in rect: NSRect,
        cornerRadius: CGFloat,
        context: CGContext
    ) {
        let handleW = Trim.handleWidth
        let drawX = rect.minX + stripWidth + 1
        let drawWidth = rect.width - stripWidth - 1 - handleW
        let drawY = rect.minY + 1
        let drawHeight = rect.height - 2
        guard drawWidth > 4, drawHeight > 4 else { return }

        let drawRect = CGRect(x: drawX, y: drawY, width: drawWidth, height: drawHeight)

        // Compute thumbnail display width from aspect ratio
        let firstThumb = thumbnails[0].image
        let aspectRatio = CGFloat(firstThumb.width) / CGFloat(firstThumb.height)
        let thumbDisplayWidth = max(1, drawHeight * aspectRatio)

        // Visible time range based on trim
        let fps = 30.0 // default; could be passed through but rarely changes
        let visibleStartSec = Double(clip.trimStartFrame) / fps
        let visibleDurationSec = Double(clip.durationFrames) / fps
        guard visibleDurationSec > 0 else { return }

        context.saveGState()
        let clipPath = CGPath(roundedRect: drawRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        context.addPath(clipPath)
        context.clip()

        // Tile thumbnails across the drawable area
        var x = drawX
        while x < drawX + drawWidth {
            // What time does this x position correspond to?
            let frac = (x - drawX) / drawWidth
            let timeSec = visibleStartSec + frac * visibleDurationSec

            // Find nearest thumbnail
            var best = thumbnails[0]
            var bestDist = abs(best.time - timeSec)
            for thumb in thumbnails {
                let dist = abs(thumb.time - timeSec)
                if dist < bestDist {
                    best = thumb
                    bestDist = dist
                }
            }

            let tileRect = CGRect(x: x, y: drawY, width: thumbDisplayWidth, height: drawHeight)
            // CGContext.draw uses bottom-up coords; flip for the flipped NSView
            context.saveGState()
            context.translateBy(x: 0, y: tileRect.midY * 2)
            context.scaleBy(x: 1, y: -1)
            context.draw(best.image, in: tileRect)
            context.restoreGState()
            x += thumbDisplayWidth
        }

        // Semi-transparent overlay so label is readable
        context.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        context.fill(drawRect)

        context.restoreGState()
    }

    // MARK: - Label

    private static func drawLabel(_ text: String, in rect: NSRect, context: CGContext) {
        guard rect.width > 30 else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: AppTheme.FontSize.xs, weight: .medium),
            .foregroundColor: AppTheme.Text.primary,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let inset: CGFloat = 8 // extra inset to clear the edge strip
        let origin = NSPoint(
            x: rect.minX + inset,
            y: rect.midY - size.height / 2
        )
        context.saveGState()
        context.clip(to: rect.insetBy(dx: inset, dy: 2))
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
