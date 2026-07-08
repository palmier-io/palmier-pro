import AppKit

enum ClipRenderer {

    static let labelBarHeight: CGFloat = 16

    static let volumeKeyframeSize: CGFloat = 7
    static let volumeKeyframeHitSize: CGFloat = 14
    static let volumeFadeHandleEdgeInset: CGFloat = Trim.handleWidth + volumeKeyframeHitSize / 2 + AppTheme.Spacing.xxs
    static let volumeRubberBandTopDb: Double = 6
    static let volumeRubberBandBottomDb: Double = -60
    static let fadeKneeTopInset: CGFloat = 4
    static func fadeKneeY(in body: NSRect) -> CGFloat {
        body.minY + fadeKneeTopInset
    }

    /// The clip card's body area below the label bar
    static func clipBodyRect(in clipRect: NSRect) -> NSRect {
        NSRect(
            x: clipRect.minX,
            y: clipRect.minY + labelBarHeight,
            width: clipRect.width,
            height: max(0, clipRect.height - labelBarHeight - 1)
        )
    }

    /// Y axis is flipped: high dB → smaller Y.
    static func y(forDb db: Double, in body: NSRect) -> CGFloat {
        let top = volumeRubberBandTopDb
        let bottom = volumeRubberBandBottomDb
        let clamped = min(top, max(bottom, db))
        let frac = (top - clamped) / (top - bottom)
        return body.minY + CGFloat(frac) * body.height
    }

    static func db(forY y: CGFloat, in body: NSRect) -> Double {
        guard body.height > 0 else { return 0 }
        let frac = max(0, min(1, Double((y - body.minY) / body.height)))
        return volumeRubberBandTopDb - frac * (volumeRubberBandTopDb - volumeRubberBandBottomDb)
    }

    static func fadeHandleRenderX(in clipRect: NSRect, kfOffset: Int, pxPerFrame: CGFloat) -> CGFloat {
        let actual = clipRect.minX + CGFloat(kfOffset) * pxPerFrame
        let edgeInset = min(volumeFadeHandleEdgeInset, max(0, clipRect.width / 2))
        return min(clipRect.maxX - edgeInset, max(clipRect.minX + edgeInset, actual))
    }

    static func draw(
        _ clip: Clip,
        type: ClipType,
        in rect: NSRect,
        isSelected: Bool,
        isHovered: Bool = false,
        opacity: CGFloat = 1.0,
        context: CGContext,
        cache: MediaVisualCache? = nil,
        displayName: String? = nil,
        linkOffset: Int? = nil,
        fps: Int,
        isMissing: Bool = false,
        isGenerating: Bool = false
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
            let mask = markDeadAir ? cache?.deadAirMask(for: clip.mediaRef) : nil
            drawWaveform(samples: samples, deadAirMask: mask,
                         speakerMask: speakerColors.isEmpty ? nil : cache?.speakerMask(for: clip.mediaRef),
                         clip: clip, type: colorType, in: audioRect, context: context)
        }

        let showsFadeControls = isSelected || isHovered
        if type == .audio {
            drawVolumeRubberBand(clip: clip, in: rect, isSelected: isSelected, showsFadeControls: showsFadeControls, context: context)
        } else {
            drawOpacityFades(clip: clip, in: rect, showsFadeControls: showsFadeControls, context: context)
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

        // Subtle wash while the clip's media is being rendered/generated.
        if isGenerating {
            context.setFillColor(NSColor.white.withAlphaComponent(AppTheme.Opacity.faint).cgColor)
            context.addPath(path)
            context.fillPath()
        }

        // Red wash + border for clips whose source media is missing.
        if isMissing && !isGenerating {
            context.setFillColor(AppTheme.Status.error.withAlphaComponent(AppTheme.Opacity.moderate).cgColor)
            context.addPath(path)
            context.fillPath()
            context.setStrokeColor(AppTheme.Status.error.withAlphaComponent(AppTheme.Opacity.prominent).cgColor)
            context.setLineWidth(AppTheme.BorderWidth.medium)
            context.addPath(path)
            context.strokePath()
        }

        let showDetailChrome = isSelected || rect.width >= AppTheme.ComponentSize.timelineClipDetailMinWidth
        let showLabel = isSelected || rect.width >= AppTheme.ComponentSize.timelineClipLabelMinWidth

        if showLabel {
            drawLabelBar(clip: clip, type: type, in: labelRect, clipRect: rect, context: context, displayName: displayName, fps: fps)
        }

        if showDetailChrome, let linkOffset, linkOffset != 0 {
            drawOffsetBadge(frames: linkOffset, in: rect, context: context)
        }

        if showDetailChrome {
            drawKeyframeMarkers(clip: clip, in: rect, context: context)

            drawTrimHandles(in: rect, context: context)
        }

        if markBeats, type == .audio, clip.sourceClipType != .sequence, let beats = cache?.beatAnalysis(for: clip.mediaRef) {
            drawBeatTicks(analysis: beats, clip: clip, in: rect, fps: fps, context: context)
        }

        if opacity < 1.0 {
            context.restoreGState()
        }
    }

    // MARK: - Keyframe markers

    /// Volume kfs render on the rubber band, not here.
    private static func drawKeyframeMarkers(clip: Clip, in rect: NSRect, context: CGContext) {
        var frameSet = Set<Int>()
        let absStart = clip.startFrame
        for kf in clip.opacityTrack?.keyframes ?? [] { frameSet.insert(kf.frame + absStart) }
        for kf in clip.positionTrack?.keyframes ?? [] { frameSet.insert(kf.frame + absStart) }
        for kf in clip.scaleTrack?.keyframes ?? [] { frameSet.insert(kf.frame + absStart) }
        for kf in clip.cropTrack?.keyframes ?? [] { frameSet.insert(kf.frame + absStart) }
        let frames = frameSet.sorted()
        guard !frames.isEmpty, clip.durationFrames > 0 else { return }
        let pxPerFrame = (rect.width - 2 * Trim.handleWidth) / CGFloat(clip.durationFrames)
        guard pxPerFrame > 0 else { return }
        let baseX = rect.minX + Trim.handleWidth
        let y = rect.maxY - 5
        let half: CGFloat = 3
        context.setFillColor(NSColor.systemYellow.withAlphaComponent(0.95).cgColor)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        context.setLineWidth(0.5)
        for f in frames where clip.contains(timelineFrame: f) {
            let x = baseX + CGFloat(f - clip.startFrame) * pxPerFrame
            let p = CGMutablePath()
            p.move(to: CGPoint(x: x, y: y - half))
            p.addLine(to: CGPoint(x: x + half, y: y))
            p.addLine(to: CGPoint(x: x, y: y + half))
            p.addLine(to: CGPoint(x: x - half, y: y))
            p.closeSubpath()
            context.addPath(p)
            context.drawPath(using: .fillStroke)
        }
    }

    private static let beatTickColor = NSColor.systemOrange.withAlphaComponent(0.7).cgColor
    private static let downbeatTickColor = NSColor.systemOrange.cgColor
    private static let beatTickBackingColor = NSColor.black.withAlphaComponent(0.55).cgColor
    private static let beatTickWidth: CGFloat = 1
    private static let beatTickHeight: CGFloat = 7
    private static let downbeatTickHeight: CGFloat = 14
    private static let beatTickMinSpacing: CGFloat = 4

    private static func drawBeatTicks(analysis: BeatAnalysis, clip: Clip, in rect: NSRect, fps: Int, context: CGContext) {
        guard clip.durationFrames > 0, !analysis.beats.isEmpty || !analysis.downbeats.isEmpty else { return }
        let pxPerFrame = rect.width / CGFloat(clip.durationFrames)
        guard pxPerFrame > 0 else { return }
        let body = clipBodyRect(in: rect)
        guard body.height > downbeatTickHeight * 2 else { return }

        // Merge beats and downbeats: if a beat is close to a downbeat, treat it as the downbeat.
        // Always show downbeats; show beats where there's space.
        let tolerance = 0.03
        var ticks: [CGRect] = []
        var downTicks: [CGRect] = []
        var beatIndex = 0
        var lastX = -CGFloat.greatestFiniteMagnitude
        func appendTick(_ t: Double, isDown: Bool) {
            guard let frame = clip.timelineFrame(sourceSeconds: t, fps: fps) else { return }
            let x = rect.minX + CGFloat(frame - clip.startFrame) * pxPerFrame
            guard isDown || x - lastX >= beatTickMinSpacing else { return }
            lastX = x
            let height = isDown ? downbeatTickHeight : beatTickHeight
            let tick = CGRect(x: x - beatTickWidth / 2, y: body.minY, width: beatTickWidth, height: height)
            if isDown { downTicks.append(tick) } else { ticks.append(tick) }
        }
        for down in analysis.downbeats {
            while beatIndex < analysis.beats.count, analysis.beats[beatIndex] < down - tolerance {
                appendTick(analysis.beats[beatIndex], isDown: false)
                beatIndex += 1
            }
            if beatIndex < analysis.beats.count, abs(analysis.beats[beatIndex] - down) <= tolerance {
                beatIndex += 1  // coincident beat renders as the downbeat
            }
            appendTick(down, isDown: true)
        }
        while beatIndex < analysis.beats.count {
            appendTick(analysis.beats[beatIndex], isDown: false)
            beatIndex += 1
        }
        guard !(ticks.isEmpty && downTicks.isEmpty) else { return }
        context.setFillColor(beatTickBackingColor)
        context.fill((ticks + downTicks).map { CGRect(x: $0.minX - 1, y: $0.minY, width: $0.width + 2, height: $0.height + 1) })
        context.setFillColor(beatTickColor)
        context.fill(ticks)
        context.setFillColor(downbeatTickColor)
        context.fill(downTicks)
    }

    // MARK: - Waveform

    private static let washColor = AppTheme.Status.error.withAlphaComponent(AppTheme.Opacity.medium).cgColor
    nonisolated(unsafe) static var speakerColors: [Int: CGColor] = [:]
    private static var markDeadAir: Bool { UserDefaults.standard.object(forKey: "markDeadAir") as? Bool ?? true }
    private static var markBeats: Bool { UserDefaults.standard.object(forKey: "markBeats") as? Bool ?? true }

    private static func drawWaveform(
        samples: [Float],
        deadAirMask: [Bool]?,
        speakerMask: [Int]? = nil,
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
        let sampleStart = max(0, min(samples.count, Int(startFrac * Double(samples.count))))
        let sampleEnd = max(sampleStart, min(samples.count, Int(endFrac * Double(samples.count))))
        guard sampleEnd > sampleStart else { return }

        let barCount = Int(drawWidth)
        guard barCount > 0 else { return }

        // Only emit bars inside the context's clip region (the dirty rect).
        let visible = context.boundingBoxOfClipPath.intersection(drawRect)
        guard !visible.isEmpty else { return }
        let firstBar = max(0, Int(visible.minX - drawRect.minX))
        let lastBar = min(barCount, Int(ceil(visible.maxX - drawRect.minX)))
        guard firstBar < lastBar else { return }

        let color = (type.themeColor.blended(withFraction: 0.3, of: .white) ?? type.themeColor).withAlphaComponent(0.85).cgColor
        context.setFillColor(color)

        let dur = CGFloat(max(1, clip.durationFrames))
        let frameStep = dur / CGFloat(barCount)
        let visCount = sampleEnd - sampleStart

        // Samples are dB-normalized over this range, so volume shifts the dB axis (not multiplies).
        let dbRange: CGFloat = 50
        // Volume is constant across the clip unless keyframed or faded.
        let needsPerBarVolume = (clip.volumeTrack?.isActive ?? false) || clip.fadeInFrames > 0 || clip.fadeOutFrames > 0
        let staticShift = CGFloat(VolumeScale.dbFromLinear(clip.volume)) / dbRange

        // Dead-air shading maps the mask through the same source fractions as samples.
        let maskCount = deadAirMask?.count ?? 0
        let maskStart = max(0, min(maskCount, Int(startFrac * Double(maskCount))))
        let maskEnd = max(maskStart, min(maskCount, Int(endFrac * Double(maskCount))))
        let maskVisCount = maskEnd - maskStart
        var washes: [CGRect] = []
        let spkCount = speakerMask?.count ?? 0
        let spkStart = max(0, min(spkCount, Int(startFrac * Double(spkCount))))
        let spkEnd = max(spkStart, min(spkCount, Int(endFrac * Double(spkCount))))
        let spkVisCount = spkEnd - spkStart
        var tintedBars: [Int: [CGRect]] = [:]

        var bars: [CGRect] = []
        bars.reserveCapacity(lastBar - firstBar)
        for i in firstBar..<lastBar {
            // Peak-detect (min, since 0=loud) over the bar's range so zero crossings don't flatten loud audio.
            let sStart = sampleStart + i * visCount / barCount
            let sEnd = max(sStart + 1, sampleStart + (i + 1) * visCount / barCount)
            var loudest: Float = 1
            for j in sStart..<min(sEnd, sampleEnd) {
                let s = samples[j]
                if s < loudest { loudest = s }
            }
            let dbShift: CGFloat
            if needsPerBarVolume {
                let posFrames = CGFloat(i) * frameStep
                dbShift = CGFloat(VolumeScale.dbFromLinear(clip.volumeAt(frame: clip.startFrame + Int(posFrames)))) / dbRange
            } else {
                dbShift = staticShift
            }
            let dbAmp = max(0, CGFloat(1 - loudest) + dbShift)
            let amplitude = min(1, dbAmp)
            let barHeight = max(1, amplitude * (drawHeight - 2))
            let barY = drawRect.maxY - barHeight - 1
            let bar = CGRect(x: drawRect.minX + CGFloat(i), y: barY, width: 1, height: barHeight)
            var speaker = -1
            if let speakerMask, spkVisCount > 0 {
                let c = min(spkEnd - 1, spkStart + i * spkVisCount / barCount)
                speaker = speakerMask[c]
            }
            if speaker >= 0, speakerColors[speaker] != nil {
                tintedBars[speaker, default: []].append(bar)
            } else {
                bars.append(bar)
            }

            if let deadAirMask, maskVisCount > 0 {
                let m0 = maskStart + i * maskVisCount / barCount
                let m1 = min(maskEnd, max(m0 + 1, maskStart + (i + 1) * maskVisCount / barCount))
                if deadAirMask[m0..<m1].contains(true) {
                    washes.append(CGRect(x: drawRect.minX + CGFloat(i), y: drawRect.minY, width: 1, height: drawRect.height))
                }
            }
        }
        context.fill(bars)
        for (speaker, rects) in tintedBars {
            if let tint = speakerColors[speaker] {
                context.setFillColor(tint)
                context.fill(rects)
            }
        }

        if !washes.isEmpty {
            context.setFillColor(washColor)
            context.fill(washes)
        }
    }

    // MARK: - Volume rubber band

    private static func drawVolumeRubberBand(
        clip: Clip,
        in rect: NSRect,
        isSelected: Bool,
        showsFadeControls: Bool,
        context: CGContext
    ) {
        guard clip.durationFrames > 0 else { return }
        let pxPerFrame = rect.width / CGFloat(clip.durationFrames)
        guard pxPerFrame > 0 else { return }

        let body = clipBodyRect(in: rect)
        let alpha: CGFloat = showsFadeControls ? 0.95 : 0.75
        let lineColor = NSColor.white.withAlphaComponent(alpha).cgColor
        let fadeColor = NSColor.white.withAlphaComponent(alpha * 0.7).cgColor

        // 1) Volume line — through kfs, or flat at static volume when no kfs.
        context.setStrokeColor(lineColor)
        context.setLineWidth(1.5)
        context.beginPath()
        if let track = clip.volumeTrack, track.isActive {
            let kfs = track.keyframes.filter { $0.frame >= 0 && $0.frame <= clip.durationFrames }
            if let first = kfs.first {
                let firstX = rect.minX + CGFloat(first.frame) * pxPerFrame
                let firstY = y(forDb: first.value, in: body)
                context.move(to: CGPoint(x: rect.minX, y: firstY))
                context.addLine(to: CGPoint(x: firstX, y: firstY))
                for i in 0..<(kfs.count - 1) {
                    let a = kfs[i], b = kfs[i + 1]
                    let aX = rect.minX + CGFloat(a.frame) * pxPerFrame
                    let bX = rect.minX + CGFloat(b.frame) * pxPerFrame
                    let aY = y(forDb: a.value, in: body)
                    let bY = y(forDb: b.value, in: body)
                    switch a.interpolationOut {
                    case .linear:
                        context.addLine(to: CGPoint(x: bX, y: bY))
                    case .hold:
                        context.addLine(to: CGPoint(x: bX, y: aY))
                        context.addLine(to: CGPoint(x: bX, y: bY))
                    case .smooth:
                        let steps = 12
                        for s in 1...steps {
                            let t = Double(s) / Double(steps)
                            let x = aX + (bX - aX) * CGFloat(t)
                            let dB = a.value + (b.value - a.value) * smoothstep(t)
                            context.addLine(to: CGPoint(x: x, y: y(forDb: dB, in: body)))
                        }
                    }
                }
                let lastY = y(forDb: kfs.last!.value, in: body)
                context.addLine(to: CGPoint(x: rect.maxX, y: lastY))
            }
        } else {
            let volDb = VolumeScale.dbFromLinear(clip.volume)
            let volY = y(forDb: volDb, in: body)
            context.move(to: CGPoint(x: rect.minX, y: volY))
            context.addLine(to: CGPoint(x: rect.maxX, y: volY))
        }
        context.strokePath()

        // Fade endpoints. Knees sit in a fixed "fade lane" near the top of the body
        let leftOffset = min(clip.fadeInFrames, clip.durationFrames)
        let rightOffset = max(0, clip.durationFrames - clip.fadeOutFrames)
        let leftKneeX = fadeHandleRenderX(in: rect, kfOffset: leftOffset, pxPerFrame: pxPerFrame)
        let rightKneeX = fadeHandleRenderX(in: rect, kfOffset: rightOffset, pxPerFrame: pxPerFrame)
        let kneeY = fadeKneeY(in: body)
        let silenceY = body.maxY

        // 2) Fade-in: darken the wedge above the curve, stroke the fade curve.
        if clip.fadeInFrames > 0 {
            drawFadeWedge(
                silentCorner: CGPoint(x: rect.minX, y: silenceY),
                knee: CGPoint(x: leftKneeX, y: kneeY),
                interpolation: clip.fadeInInterpolation,
                color: fadeColor,
                context: context
            )
        }

        // 3) Fade-out: symmetric on the right edge.
        if clip.fadeOutFrames > 0 {
            drawFadeWedge(
                silentCorner: CGPoint(x: rect.maxX, y: silenceY),
                knee: CGPoint(x: rightKneeX, y: kneeY),
                interpolation: clip.fadeOutInterpolation,
                color: fadeColor,
                context: context
            )
        }

        guard showsFadeControls else { return }

        let half = volumeKeyframeSize / 2

        if isSelected {
            context.setFillColor(lineColor)
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            context.setLineWidth(0.5)

            // 4) Keyframe diamonds — independent of the fade knees.
            for kf in clip.volumeTrack?.keyframes ?? []
                where kf.frame >= 0 && kf.frame <= clip.durationFrames {
                let cx = rect.minX + CGFloat(kf.frame) * pxPerFrame
                let cy = y(forDb: kf.value, in: body)
                let p = CGMutablePath()
                p.move(to: CGPoint(x: cx, y: cy - half))
                p.addLine(to: CGPoint(x: cx + half, y: cy))
                p.addLine(to: CGPoint(x: cx, y: cy + half))
                p.addLine(to: CGPoint(x: cx - half, y: cy))
                p.closeSubpath()
                context.addPath(p)
                context.drawPath(using: .fillStroke)
            }
        }

        // 5) Knees — sit in the fade lane near the top of the body.
        let leftKneeRect = CGRect(x: leftKneeX - half, y: kneeY - half, width: volumeKeyframeSize, height: volumeKeyframeSize)
        let rightKneeRect = CGRect(x: rightKneeX - half, y: kneeY - half, width: volumeKeyframeSize, height: volumeKeyframeSize)
        drawFadeHandle(in: leftKneeRect, edge: .left, fillColor: lineColor, context: context)
        drawFadeHandle(in: rightKneeRect, edge: .right, fillColor: lineColor, context: context)
    }

    private static func drawOpacityFades(clip: Clip, in rect: NSRect, showsFadeControls: Bool, context: CGContext) {
        guard clip.durationFrames > 0 else { return }
        guard clip.fadeInFrames > 0 || clip.fadeOutFrames > 0 || showsFadeControls else { return }
        let pxPerFrame = rect.width / CGFloat(clip.durationFrames)
        guard pxPerFrame > 0 else { return }

        let body = clipBodyRect(in: rect)
        let alpha: CGFloat = showsFadeControls ? 0.95 : 0.75
        let lineColor = NSColor.white.withAlphaComponent(alpha).cgColor
        let fadeColor = NSColor.white.withAlphaComponent(alpha * 0.7).cgColor

        let leftOffset = min(clip.fadeInFrames, clip.durationFrames)
        let rightOffset = max(0, clip.durationFrames - clip.fadeOutFrames)
        let leftKneeX = fadeHandleRenderX(in: rect, kfOffset: leftOffset, pxPerFrame: pxPerFrame)
        let rightKneeX = fadeHandleRenderX(in: rect, kfOffset: rightOffset, pxPerFrame: pxPerFrame)
        let kneeY = fadeKneeY(in: body)
        let silenceY = body.maxY

        if clip.fadeInFrames > 0 {
            drawFadeWedge(
                silentCorner: CGPoint(x: rect.minX, y: silenceY),
                knee: CGPoint(x: leftKneeX, y: kneeY),
                interpolation: clip.fadeInInterpolation,
                color: fadeColor,
                fillTopY: body.minY,
                fillAlpha: 0.6,
                context: context
            )
        }

        if clip.fadeOutFrames > 0 {
            drawFadeWedge(
                silentCorner: CGPoint(x: rect.maxX, y: silenceY),
                knee: CGPoint(x: rightKneeX, y: kneeY),
                interpolation: clip.fadeOutInterpolation,
                color: fadeColor,
                fillTopY: body.minY,
                fillAlpha: 0.6,
                context: context
            )
        }

        guard showsFadeControls else { return }

        let half = volumeKeyframeSize / 2
        let leftKneeRect = CGRect(x: leftKneeX - half, y: kneeY - half, width: volumeKeyframeSize, height: volumeKeyframeSize)
        let rightKneeRect = CGRect(x: rightKneeX - half, y: kneeY - half, width: volumeKeyframeSize, height: volumeKeyframeSize)
        drawFadeHandle(in: leftKneeRect, edge: .left, fillColor: lineColor, context: context)
        drawFadeHandle(in: rightKneeRect, edge: .right, fillColor: lineColor, context: context)
    }

    private static func drawFadeHandle(
        in rect: CGRect,
        edge: FadeEdge,
        fillColor: CGColor,
        context: CGContext
    ) {
        context.saveGState()
        defer { context.restoreGState() }

        context.setFillColor(fillColor)
        context.setStrokeColor(AppTheme.Background.base.withAlphaComponent(CGFloat(AppTheme.Opacity.strong)).cgColor)
        context.setLineWidth(AppTheme.BorderWidth.hairline)
        context.fill(rect)
        context.stroke(rect)

        let glyphRect = rect.insetBy(dx: AppTheme.BorderWidth.medium, dy: AppTheme.BorderWidth.medium)
        guard glyphRect.width > 0, glyphRect.height > 0 else { return }

        let start: CGPoint
        let end: CGPoint
        let fillCorner: CGPoint
        switch edge {
        case .left:
            start = CGPoint(x: glyphRect.minX, y: glyphRect.maxY)
            end = CGPoint(x: glyphRect.maxX, y: glyphRect.minY)
            fillCorner = CGPoint(x: glyphRect.maxX, y: glyphRect.maxY)
        case .right:
            start = CGPoint(x: glyphRect.minX, y: glyphRect.minY)
            end = CGPoint(x: glyphRect.maxX, y: glyphRect.maxY)
            fillCorner = CGPoint(x: glyphRect.minX, y: glyphRect.maxY)
        }

        let fill = CGMutablePath()
        fill.move(to: start)
        fill.addLine(to: fillCorner)
        fill.addLine(to: end)
        fill.closeSubpath()
        context.addPath(fill)
        context.setFillColor(AppTheme.Background.base.withAlphaComponent(CGFloat(AppTheme.Opacity.strong)).cgColor)
        context.fillPath()

        context.beginPath()
        context.move(to: start)
        context.addLine(to: end)
        context.setStrokeColor(AppTheme.Background.base.withAlphaComponent(CGFloat(AppTheme.Opacity.prominent)).cgColor)
        context.setLineWidth(AppTheme.BorderWidth.thin)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
    }

    private static func drawFadeWedge(
        silentCorner: CGPoint,
        knee: CGPoint,
        interpolation: Interpolation,
        color: CGColor,
        fillTopY: CGFloat? = nil,
        fillAlpha: CGFloat = 0.35,
        context: CGContext
    ) {
        let curve = fadeCurvePoints(from: silentCorner, to: knee, interpolation: interpolation)
        let topY = fillTopY ?? knee.y

        // Fill the wedge above the curve
        let fill = CGMutablePath()
        fill.move(to: silentCorner)
        fill.addLine(to: CGPoint(x: silentCorner.x, y: topY))
        fill.addLine(to: CGPoint(x: knee.x, y: topY))
        if topY != knee.y { fill.addLine(to: knee) }
        for p in curve.reversed().dropFirst() { fill.addLine(to: p) }
        fill.closeSubpath()
        context.saveGState()
        context.addPath(fill)
        context.setFillColor(NSColor.black.withAlphaComponent(fillAlpha).cgColor)
        context.fillPath()
        context.restoreGState()

        // Stroke the curve.
        context.setStrokeColor(color)
        context.setLineWidth(1.5)
        context.beginPath()
        context.move(to: silentCorner)
        for p in curve { context.addLine(to: p) }
        context.strokePath()
    }

    /// Sample points along a fade ramp from `start` to `end` according to interpolation.
    private static func fadeCurvePoints(from start: CGPoint, to end: CGPoint, interpolation: Interpolation) -> [CGPoint] {
        switch interpolation {
        case .linear, .hold:
            return [end]
        case .smooth:
            let steps = 12
            var out: [CGPoint] = []
            out.reserveCapacity(steps)
            for s in 1...steps {
                let t = Double(s) / Double(steps)
                let x = start.x + (end.x - start.x) * CGFloat(t)
                let y = start.y + (end.y - start.y) * CGFloat(smoothstep(t))
                out.append(CGPoint(x: x, y: y))
            }
            return out
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

        // Tile available thumbnails across the strip; unfilled tiles remain empty until loaded.
        let startTime = thumbnails[0].time
        let spacing = thumbnails.count > 1 ? max(0.5, thumbnails[1].time - startTime) : 2.0
        let maxCoveredSec = thumbnails.last!.time + spacing
        tileImage(width: thumbDisplayWidth, in: drawRect, context: context) { tileRect in
            let frac = (tileRect.minX - drawRect.minX) / drawRect.width
            let timeSec = visibleStartSec + frac * visibleDurationSec
            guard timeSec <= maxCoveredSec else { return nil }
            // Times are uniformly spaced, so the nearest thumbnail is an index away.
            let index = Int(((timeSec - startTime) / spacing).rounded())
            return thumbnails[max(0, min(thumbnails.count - 1, index))].image
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

        tileImage(width: thumbDisplayWidth, in: drawRect, context: context) { _ in image }

        context.restoreGState()
    }

    // MARK: - Shared tiling

    /// Tiles the visible portion of `drawRect`; `image` returns nil to stop tiling.
    private static func tileImage(
        width thumbDisplayWidth: CGFloat,
        in drawRect: NSRect,
        context: CGContext,
        image: (NSRect) -> CGImage?
    ) {
        let visible = context.boundingBoxOfClipPath
        guard !visible.isEmpty else { return }
        let maxTiles = 200
        var x = drawRect.minX
        if visible.minX > x {
            x += floor((visible.minX - x) / thumbDisplayWidth) * thumbDisplayWidth
        }
        var tileCount = 0
        while x < min(drawRect.maxX, visible.maxX), tileCount < maxTiles {
            let tileRect = CGRect(x: x, y: drawRect.minY, width: thumbDisplayWidth, height: drawRect.height)
            guard let image = image(tileRect) else { break }
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
