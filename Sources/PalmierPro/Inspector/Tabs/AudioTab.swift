import SwiftUI

extension InspectorView {

    @ViewBuilder
    func audioTabContent() -> some View {
        let audios = selectedAudioClips
        let single = audios.count == 1 ? audios.first : nil
        let kfVisible = single != nil && editor.keyframesPanelVisible

        if let clip = single, kfVisible {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                    // Match the kf panel's ruler+strip header height so Volume aligns with its lane.
                    sectionTitleLabel(title: "Levels")
                        .frame(height: KeyframesMetrics.headerHeight, alignment: .bottomLeading)
                    volumeRow(audios: audios)
                    fadeRow(label: "Fade In", clips: audios, edge: .left)
                        .padding(.trailing, KeyframesMetrics.controlsColumnWidth + AppTheme.Spacing.sm)
                    fadeRow(label: "Fade Out", clips: audios, edge: .right)
                        .padding(.trailing, KeyframesMetrics.controlsColumnWidth + AppTheme.Spacing.sm)
                    if nonTextVisualClips.isEmpty {
                        speedSection(clips: audios)
                            .padding(.trailing, KeyframesMetrics.controlsColumnWidth + AppTheme.Spacing.sm)
                            .padding(.top, AppTheme.Spacing.md)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, AppTheme.Spacing.sm)
                Divider()
                KeyframesPanel(clip: clip)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, AppTheme.Spacing.sm)
            }
        } else {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                    sectionTitleLabel(title: "Levels")
                    volumeRow(audios: audios)
                    fadeRow(label: "Fade In", clips: audios, edge: .left)
                    fadeRow(label: "Fade Out", clips: audios, edge: .right)
                }
                if nonTextVisualClips.isEmpty {
                    speedSection(clips: audios)
                }
            }
        }

        keyframesToggleBar(enabled: single != nil)
    }

    @ViewBuilder
    private func volumeRow(audios: [Clip]) -> some View {
        let single = audios.count == 1 ? audios.first : nil
        animatableRow(label: "Volume", clipId: single?.id, property: .volume) {
            ScrubbableNumberField(
                value: sharedClipValue(audios) { clip in
                    clip.liveVolumeKfDb(at: editor.activeFrame) ?? VolumeScale.dbFromLinear(clip.volume)
                },
                range: VolumeScale.floorDb...VolumeScale.ceilingDb,
                format: "%.1f",
                valueSuffix: " dB",
                dragSensitivity: 0.3,
                fieldWidth: 56,
                displayTextOverride: { db in db <= VolumeScale.floorDb ? "-∞ dB" : nil },
                onChanged: { db in
                    for c in audios { editor.applyVolume(clipId: c.id, valueDb: db) }
                }
            ) { db in
                commitToClips(audios, actionName: "Change Volume") { c in
                    editor.commitVolume(clipId: c.id, valueDb: db)
                }
            }
        }
    }

    @ViewBuilder
    private func fadeRow(label: String, clips: [Clip], edge: FadeEdge) -> some View {
        let fps = Double(max(1, editor.timeline.fps))
        let single = clips.count == 1 ? clips.first : nil
        let maxSeconds = single.map { Double($0.durationFrames) / fps } ?? 60.0
        let actionName = edge == .left ? "Change Fade In" : "Change Fade Out"
        propertyRow(label: label) {
            ScrubbableNumberField(
                value: sharedClipValue(clips) { clip in
                    Double(clip.fadeFrames(edge)) / fps
                },
                range: 0...maxSeconds,
                format: "%.2f",
                valueSuffix: " s",
                dragSensitivity: 0.02,
                fieldWidth: 56,
                onChanged: { seconds in
                    let frames = Int((seconds * fps).rounded())
                    for c in clips { editor.applyFade(clipId: c.id, edge: edge, frames: frames) }
                }
            ) { seconds in
                let frames = Int((seconds * fps).rounded())
                commitToClips(clips, actionName: actionName) { c in
                    editor.commitFade(clipId: c.id, edge: edge, frames: frames)
                }
            }
        }
        .frame(height: KeyframesMetrics.rowHeight)
    }
}
