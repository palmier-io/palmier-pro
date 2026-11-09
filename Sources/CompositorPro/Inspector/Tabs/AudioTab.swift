import AppKit
import SwiftUI

extension InspectorView {

    @ViewBuilder
    func audioTabContent(audioClips: [Clip], hasNonTextVisualClips: Bool) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
            levelsSection(audios: audioClips)
            EditorPanelGroup(L10n.string("Enhance"), contentSpacing: AppTheme.Spacing.smMd) {
                enhanceRow(audios: audioClips)
                if !audioClips.contains(where: { $0.hasEnhanceEnabled }) {
                    denoiseRow(audios: audioClips)
                    debreathRow(audios: audioClips)
                }
                loudnessRow(audios: audioClips)
                if !audioClips.isEmpty, !AudioEnhancer.availability.canStart {
                    Text(AudioEnhancer.availability.localizedMessage)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
            }
            if !hasNonTextVisualClips {
                speedSection(clips: audioClips)
            }
        }
        .onDisappear { audioFinishingTask?.cancel() }
    }

    private func levelsSection(audios: [Clip]) -> some View {
        return EditorPanelGroup(
            L10n.string("Levels"),
            isExpanded: $audioLevelsExpanded
        ) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                volumeRow(audios: audios)
                fadeRow(label: L10n.string("Fade In"), clips: audios, edge: .left)
                fadeRow(label: L10n.string("Fade Out"), clips: audios, edge: .right)
            }
        }
    }

    @ViewBuilder
    private func volumeRow(audios: [Clip]) -> some View {
        animatableRow(
            label: L10n.string("Volume"),
            clips: audios,
            property: .volume,
            onReset: {
                commitPropertiesToClips(audios, actionName: "Reset Volume") { clip in
                    clip.volume = 1
                    clip.volumeTrack = nil
                }
            }
        )
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
                propertyRow(
                    label: L10n.string("Denoise"),
                    onReset: {
                        changeAudioEnhancement {
                            try editor.setDenoise(
                                clipIds: Set(audios.map(\.id)), enabled: false, actionName: "Reset Denoise"
                            )
                        }
                    }
                ) {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        if allOn {
                            ScrubbableNumberField(
                                value: sharedClipValue(audios) { $0.denoiseAmount * 100 },
                                range: 0...100,
                                format: "%.0f",
                                valueSuffix: "%",
                                dragSensitivity: 0.5,
                                fieldWidth: AppTheme.EditorPanel.numericFieldWidth
                            ) { percent in
                                changeAudioEnhancement {
                                    try editor.setDenoise(
                                        clipIds: Set(audios.map(\.id)), enabled: true,
                                        amount: percent / 100, actionName: "Change Denoise Strength"
                                    )
                                }
                            }
                            .disabled(!AudioEnhancer.availability.canStart)
                            .help(L10n.string("Blends denoised and original audio — lower this if voices sound thin or over-compressed."))
                        }
                        Toggle(String(), isOn: Binding(
                            get: { allOn },
                            set: { enabled in
                                changeAudioEnhancement {
                                    try editor.setDenoise(
                                        clipIds: Set(audios.map(\.id)), enabled: enabled,
                                        actionName: enabled ? "Enable Denoise" : "Disable Denoise"
                                    )
                                }
                            }
                        ))
                        .disabled(!AudioEnhancer.availability.canStart && !allOn)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .accessibilityLabel(L10n.string("Denoise"))
                    }
                }
                .help(L10n.string("Removes background noise from this audio using an on-device model."))
                if baking {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        ProgressView()
                            .controlSize(.small)
                        Text(L10n.string("Removing background noise…"))
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.mutedColor)
                    }
                } else if failed {
                    Text(L10n.string("Denoise failed. Playback uses the original audio — adjust Strength to retry."))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Status.errorColor)
                }
            }
        }
    }


    @ViewBuilder
    private func enhanceRow(audios: [Clip]) -> some View {
        if !audios.isEmpty {
            let allOn = audios.allSatisfy(\.hasEnhanceEnabled)
            let working = audios.contains {
                editor.loudnessInFlight.contains($0.id) || editor.denoiseInFlight.contains($0.mediaRef)
            }
            VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                propertyRow(
                    label: L10n.string("Enhance Voice"),
                    onReset: {
                        changeAudioEnhancement {
                            try editor.setEnhance(
                                clipIds: Set(audios.map(\.id)), enabled: false, actionName: "Reset Enhance Voice"
                            )
                        }
                    }
                ) {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        if allOn {
                            ScrubbableNumberField(
                                value: sharedClipValue(audios) { $0.enhanceAmount * 100 },
                                range: 0...100,
                                format: "%.0f",
                                valueSuffix: "%",
                                dragSensitivity: 0.5,
                                fieldWidth: AppTheme.EditorPanel.numericFieldWidth
                            ) { percent in
                                changeAudioEnhancement {
                                    try editor.setEnhance(
                                        clipIds: Set(audios.map(\.id)), enabled: true,
                                        amount: percent / 100, actionName: "Change Enhance Voice Amount"
                                    )
                                }
                            }
                            .disabled(!AudioEnhancer.availability.canStart)
                            .help(L10n.string("Overall strength of the denoise, de-breath, de-esser, and loudness chain."))
                        }
                        Toggle(String(), isOn: Binding(
                            get: { allOn },
                            set: { enabled in
                                if enabled {
                                    finishAudio {
                                        try await editor.enhanceVoice(
                                            clipIds: Set(audios.map(\.id)),
                                            amount: (sharedClipValue(audios) { $0.enhanceAmount * 100 } ?? Clip.defaultEnhanceAmount * 100) / 100,
                                            deess: (sharedClipValue(audios) { $0.enhanceDeess * 100 } ?? Clip.defaultEnhanceDeess * 100) / 100,
                                            actionName: "Enable Enhance Voice"
                                        )
                                    }
                                } else {
                                    changeAudioEnhancement {
                                        try editor.setEnhance(
                                            clipIds: Set(audios.map(\.id)), enabled: false, actionName: "Disable Enhance Voice"
                                        )
                                    }
                                }
                            }
                        ))
                        .disabled(working || (!AudioEnhancer.availability.canStart && !allOn))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .accessibilityLabel(L10n.string("Enhance Voice"))
                    }
                }
                .help(L10n.string("One-click voice cleanup: denoise, de-breath, de-esser, and loudness match in a single chain."))
                if allOn {
                    propertyRow(
                        label: L10n.string("De-Ess"),
                        onReset: {
                            changeAudioEnhancement {
                                try editor.setEnhance(
                                    clipIds: Set(audios.map(\.id)), enabled: true,
                                    deess: 0.6, actionName: "Reset De-Ess"
                                )
                            }
                        }
                    ) {
                        ScrubbableNumberField(
                            value: sharedClipValue(audios) { $0.enhanceDeess * 100 },
                            range: 0...100,
                            format: "%.0f",
                            valueSuffix: "%",
                            dragSensitivity: 0.5,
                            fieldWidth: AppTheme.EditorPanel.numericFieldWidth
                        ) { percent in
                            changeAudioEnhancement {
                                try editor.setEnhance(
                                    clipIds: Set(audios.map(\.id)), enabled: true,
                                    deess: percent / 100, actionName: "Change De-Ess Amount"
                                )
                            }
                        }
                        .disabled(!AudioEnhancer.availability.canStart)
                        .help(L10n.string("How strongly sibilance (\"s\" and \"sh\" sounds) is lowered."))
                    }
                }
                if working {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        ProgressView()
                            .controlSize(.small)
                        Text(L10n.string("Enhancing voice…"))
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.mutedColor)
                    }
                }
            }
        }
    }

    private func changeAudioEnhancement(_ operation: () throws -> Void) {
        do {
            try operation()
        } catch let error as RuntimeCapabilityError {
            NSApp.presentError(NSError(
                domain: "AudioEnhancement", code: 1,
                userInfo: [NSLocalizedDescriptionKey: error.capability.localizedMessage]
            ))
        } catch {
            NSApp.presentError(error)
        }
    }

    private func finishAudio(_ operation: @escaping @MainActor () async throws -> [String]) {
        audioFinishingTask?.cancel()
        audioFinishingTask = Task { @MainActor in
            do {
                let warnings = try await operation()
                if !warnings.isEmpty {
                    NSApp.presentError(NSError(domain: "AudioEnhancement", code: 2,
                                               userInfo: [NSLocalizedDescriptionKey: warnings.joined(separator: "\n")]))
                }
            } catch is CancellationError {
            } catch {
                NSApp.presentError(error)
            }
        }
    }

    @ViewBuilder
    private func debreathRow(audios: [Clip]) -> some View {
        if !audios.isEmpty {
            let allOn = audios.allSatisfy(\.hasDebreathEnabled)
            let detecting = audios.contains { editor.denoiseInFlight.contains($0.mediaRef) }
            let failed = allOn && !detecting && audios.contains {
                editor.breathFailed.contains($0.mediaRef)
            }
            VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                propertyRow(
                    label: L10n.string("De-Breath"),
                    onReset: {
                        editor.setDebreath(
                            clipIds: Set(audios.map(\.id)),
                            enabled: false,
                            actionName: "Reset De-Breath"
                        )
                    }
                ) {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        if allOn {
                            ScrubbableNumberField(
                                value: sharedClipValue(audios) { $0.debreathAmount * 100 },
                                range: 0...100,
                                format: "%.0f",
                                valueSuffix: "%",
                                dragSensitivity: 0.5,
                                fieldWidth: AppTheme.EditorPanel.numericFieldWidth
                            ) { percent in
                                editor.setDebreath(
                                    clipIds: Set(audios.map(\.id)),
                                    enabled: true,
                                    amount: percent / 100,
                                    actionName: "Change De-Breath Strength"
                                )
                            }
                            .help(L10n.string("How much to lower detected breaths — lower it if speech sounds dull."))
                        }
                        Toggle(String(), isOn: Binding(
                            get: { allOn },
                            set: { enabled in
                                editor.setDebreath(
                                    clipIds: Set(audios.map(\.id)),
                                    enabled: enabled,
                                    actionName: enabled ? "Enable De-Breath" : "Disable De-Breath"
                                )
                            }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .accessibilityLabel(L10n.string("De-Breath"))
                    }
                }
                .help(L10n.string("Lowers the volume of detected breath sounds while keeping the natural rhythm of speech."))
                if detecting {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        ProgressView()
                            .controlSize(.small)
                        Text(L10n.string("Analyzing breaths…"))
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.mutedColor)
                    }
                } else if failed {
                    Text(L10n.string("Breath detection failed. Playback uses the original audio — adjust Strength to retry."))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Status.errorColor)
                }
            }
        }
    }

    @ViewBuilder
    private func loudnessRow(audios: [Clip]) -> some View {
        if !audios.isEmpty {
            let matching = audios.contains { editor.loudnessInFlight.contains($0.id) }
            let anyMatched = audios.contains { $0.hasLoudnessMatchEnabled }
            propertyRow(
                label: L10n.string("Match Loudness"),
                onReset: {
                    editor.mutateClips(ids: Set(audios.map(\.id)), actionName: "Reset Loudness Match") { clip in
                        clip.effects = clip.effects?.filter { $0.type != Clip.loudnessEffectType }
                        if clip.effects?.isEmpty == true { clip.effects = nil }
                    }
                }
            ) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Button {
                        finishAudio {
                            try await editor.matchLoudness(
                                clipIds: Set(audios.map(\.id)),
                                targetLUFS: -16.0,
                                actionName: "Match Loudness"
                            )
                        }
                    } label: {
                        Text(L10n.string("Match Loudness"))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(matching)
                    .help(L10n.string("Measures each clip's loudness and adjusts it to a common target (-16 LUFS) so clips sit at the same level."))
                    if matching {
                        ProgressView()
                            .controlSize(.small)
                    } else if anyMatched {
                        Text(L10n.string("Matched"))
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.mutedColor)
                    }
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
        propertyRow(
            label: label,
            onReset: {
                commitToClips(clips, actionName: "Reset \(label)") { clip in
                    editor.commitFade(clipId: clip.id, edge: edge, frames: 0)
                }
            },
            reservesKeyframeControls: true
        ) {
            ScrubbableNumberField(
                value: sharedClipValue(clips) { clip in
                    Double(clip.fadeFrames(edge)) / fps
                },
                range: 0...maxSeconds,
                format: "%.2f",
                valueSuffix: " s",
                dragSensitivity: 0.02,
                fieldWidth: AppTheme.EditorPanel.numericFieldWidth,
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
        .frame(height: AppTheme.EditorPanel.fieldMinHeight)
    }
}
