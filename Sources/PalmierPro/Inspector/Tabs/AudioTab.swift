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
                    sectionTitleLabel(title: "Enhance")
                        .padding(.top, AppTheme.Spacing.md)
                    denoiseRow(audios: audios)
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
                VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                    sectionTitleLabel(title: "Enhance")
                    denoiseRow(audios: audios)
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
    private func denoiseRow(audios: [Clip]) -> some View {
        if !audios.isEmpty {
            let allOn = audios.allSatisfy(\.hasDenoiseEnabled)
            let baking = audios.contains { editor.denoiseInFlight.contains($0.mediaRef) }
            let failed = allOn && !baking && audios.contains {
                editor.denoiseFailed.contains($0.mediaRef)
            }
            VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                propertyRow(label: "Denoise") {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        if allOn {
                            ScrubbableNumberField(
                                value: sharedClipValue(audios) { $0.denoiseAmount * 100 },
                                range: 0...100,
                                format: "%.0f",
                                valueSuffix: "%",
                                dragSensitivity: 0.5,
                                fieldWidth: 56
                            ) { percent in
                                editor.setDenoise(
                                    clipIds: Set(audios.map(\.id)),
                                    enabled: true,
                                    amount: percent / 100,
                                    actionName: "Change Denoise Strength"
                                )
                            }
                            .help("Blends denoised and original audio — lower this if voices sound thin or over-compressed.")
                        }
                        Toggle("", isOn: Binding(
                            get: { allOn },
                            set: { enabled in
                                editor.setDenoise(
                                    clipIds: Set(audios.map(\.id)),
                                    enabled: enabled,
                                    actionName: enabled ? "Enable Denoise" : "Disable Denoise"
                                )
                            }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                    }
                }
                .help("Removes background noise from this audio using an on-device model.")
                if baking {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Removing background noise…")
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.mutedColor)
                    }
                } else if failed {
                    Text("Denoise failed. Playback uses the original audio — adjust Strength to retry.")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Status.errorColor)
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
