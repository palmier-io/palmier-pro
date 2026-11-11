import Foundation

extension EditorViewModel {

    struct DesignSpecApplyReceipt: Codable, Sendable, Equatable {
        var appliedAspectRatio: String?
        var newDimensions: [Int]?
        var retypedClipsCount: Int
        var updatedClipIds: [String]
        var gradedClipsCount: Int
        var appliedGradePreset: String?
        var appliedCaptionTemplate: String?
        var updatedPreferences: Bool
    }

    /// Applies a parsed `DesignSpec` to timeline geometry, clip typography, color grading, and style preferences.
    @discardableResult
    func applyDesignSpec(
        _ spec: DesignSpec,
        updateTimelineGeometry: Bool = true,
        restyleClips: Bool = true,
        applyGrade: Bool = true,
        updatePreferences: Bool = true
    ) throws -> DesignSpecApplyReceipt {
        var receipt = DesignSpecApplyReceipt(
            retypedClipsCount: 0,
            updatedClipIds: [],
            gradedClipsCount: 0,
            updatedPreferences: false
        )

        // 1. Timeline Geometry & Aspect Ratio
        if updateTimelineGeometry, let dims = spec.canvas.resolvedDimensions() {
            if dims.width != timeline.width || dims.height != timeline.height {
                applyTimelineSettings(fps: timeline.fps, width: dims.width, height: dims.height)
                receipt.appliedAspectRatio = spec.canvas.aspectRatio ?? "\(dims.width):\(dims.height)"
                receipt.newDimensions = [dims.width, dims.height]
            }
        }

        // 2. Caption Template Application (base styling & animation preset)
        if let templateId = spec.caption.templateId, CaptionStyles.preset(id: templateId) != nil {
            let format = spec.caption.format.flatMap { SocialCaptionFormat(rawValue: $0) }
            if let templateReceipt = try? applyCaptionTemplate(templateId: templateId, format: format) {
                receipt.appliedCaptionTemplate = templateReceipt.templateId
            }
        }

        // 3. Restyle existing Text & Caption Clips with brand fonts and colors
        if restyleClips {
            let allTextClips = timeline.tracks.flatMap(\.clips).filter { $0.mediaType == .text }
            if !allTextClips.isEmpty {
                commitClipProperties(clipIds: allTextClips.map(\.id), actionName: "Apply Design Spec Styling") { clip in
                    var style = clip.textStyle ?? TextStyle()
                    let isCaption = clip.captionGroupId != nil
                    if isCaption {
                        if let font = spec.typography.bodyFont ?? spec.typography.displayFont {
                            style.fontName = font
                        }
                        if let color = spec.palette.text ?? spec.palette.primary {
                            style.color = color
                        }
                        if let border = spec.palette.border ?? spec.palette.accent {
                            if style.border.enabled {
                                style.border.color = border
                            }
                        }
                        if let bg = spec.palette.surface ?? spec.palette.background {
                            if style.background.enabled {
                                style.background.color = bg
                            }
                        }
                    } else {
                        if let font = spec.typography.displayFont ?? spec.typography.bodyFont {
                            style.fontName = font
                        }
                        if let color = spec.palette.primary ?? spec.palette.text {
                            style.color = color
                        }
                        if let border = spec.palette.border {
                            if style.border.enabled {
                                style.border.color = border
                            }
                        }
                        if let bg = spec.palette.surface ?? spec.palette.background {
                            if style.background.enabled {
                                style.background.color = bg
                            }
                        }
                    }
                    clip.textStyle = style
                }
                receipt.retypedClipsCount = allTextClips.count
                receipt.updatedClipIds = allTextClips.map(\.id)
            }
        }

        // 4. Color Grading
        if applyGrade {
            let visualClips = timeline.tracks.flatMap(\.clips).filter { $0.mediaType == .video || $0.mediaType == .image }
            if !visualClips.isEmpty {
                if let presetId = spec.grade.preset, let preset = StylePresets.preset(id: presetId) {
                    let stack = GradeState(colorDict: preset.color).buildStack()
                    let actionName = "Apply Design Grade: \(preset.id)"
                    undo.perform(actionName) {
                        mutateClips(ids: Set(visualClips.map(\.id)), actionName: actionName) { clip in
                            clip.effects = (clip.effects ?? []).filter { !$0.type.hasPrefix("color.") } + stack
                        }
                    }
                    receipt.gradedClipsCount = visualClips.count
                    receipt.appliedGradePreset = preset.id
                } else if spec.grade.exposure != nil || spec.grade.contrast != nil || spec.grade.saturation != nil || spec.grade.temperature != nil {
                    var colorDict: [String: Any] = [:]
                    if let exp = spec.grade.exposure { colorDict["exposure"] = exp }
                    if let con = spec.grade.contrast { colorDict["contrast"] = con }
                    if let sat = spec.grade.saturation { colorDict["saturation"] = sat }
                    if let temp = spec.grade.temperature { colorDict["temperature"] = temp }
                    if let tint = spec.grade.tint { colorDict["tint"] = tint }
                    let stack = GradeState(colorDict: colorDict).buildStack()
                    let actionName = "Apply Custom Grade"
                    undo.perform(actionName) {
                        mutateClips(ids: Set(visualClips.map(\.id)), actionName: actionName) { clip in
                            clip.effects = (clip.effects ?? []).filter { !$0.type.hasPrefix("color.") } + stack
                        }
                    }
                    receipt.gradedClipsCount = visualClips.count
                    receipt.appliedGradePreset = "custom"
                }
            }
        }

        // 5. Filmmaking Style Preferences
        if updatePreferences {
            var pacing = FilmmakingStylePreferences.shared.data.pacing
            if let tgt = spec.pacing.targetShotDurationSeconds { pacing.targetShotDurationSeconds = tgt }
            if let mn = spec.pacing.minShotDurationSeconds { pacing.minShotDurationSeconds = mn }
            if let mx = spec.pacing.maxShotDurationSeconds { pacing.maxShotDurationSeconds = mx }
            FilmmakingStylePreferences.shared.updatePacing(pacing)

            if let template = spec.caption.templateId {
                var cap = FilmmakingStylePreferences.shared.data.caption
                cap.captionStyle = template
                FilmmakingStylePreferences.shared.updateCaption(cap)
            }
            receipt.updatedPreferences = true
        }

        return receipt
    }

    /// Extracts the active project's styling into a `DesignSpec`.
    func exportCurrentDesignSpec() -> DesignSpec {
        var spec = DesignSpec()

        // Canvas
        spec.canvas.width = timeline.width
        spec.canvas.height = timeline.height
        let w = timeline.width
        let h = timeline.height
        if 16 * h == 9 * w {
            spec.canvas.aspectRatio = "16:9"
        } else if 9 * h == 16 * w {
            spec.canvas.aspectRatio = "9:16"
        } else if w == h {
            spec.canvas.aspectRatio = "1:1"
        } else if 4 * h == 5 * w {
            spec.canvas.aspectRatio = "4:5"
        } else if 21 * h == 9 * w {
            spec.canvas.aspectRatio = "21:9"
        } else {
            spec.canvas.aspectRatio = "\(w):\(h)"
        }

        // Typography & Palette from active clips
        let textClips = timeline.tracks.flatMap(\.clips).filter { $0.mediaType == .text }
        if let titleClip = textClips.first(where: { $0.captionGroupId == nil }), let style = titleClip.textStyle {
            spec.typography.displayFont = style.fontName
            spec.palette.primary = style.color
            if style.border.enabled { spec.palette.border = style.border.color }
            if style.background.enabled { spec.palette.surface = style.background.color }
        }
        if let captionClip = textClips.first(where: { $0.captionGroupId != nil }), let style = captionClip.textStyle {
            spec.typography.bodyFont = style.fontName
            spec.palette.text = style.color
            if style.border.enabled { spec.palette.accent = style.border.color }
        }

        // Pacing & Caption Preferences
        let prefs = FilmmakingStylePreferences.shared.data
        spec.pacing.targetShotDurationSeconds = prefs.pacing.targetShotDurationSeconds
        spec.pacing.minShotDurationSeconds = prefs.pacing.minShotDurationSeconds
        spec.pacing.maxShotDurationSeconds = prefs.pacing.maxShotDurationSeconds
        spec.caption.templateId = prefs.caption.captionStyle

        return spec
    }
}
