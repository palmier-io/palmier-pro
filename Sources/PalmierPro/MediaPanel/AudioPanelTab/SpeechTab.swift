import SwiftUI

struct SpeechTab: View {
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
                    speakersSection
                    silenceSection
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            if let phase = editor.speakerIdentifyPhase {
                AppTheme.Background.surfaceColor.opacity(AppTheme.Opacity.prominent)
                GeneratingOverlay(label: phase, size: .preview)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var speakersSection: some View {
        EditorPanelGroup(L10n.string("Speakers"), contentInsets: sectionContentInsets) {
            InspectorRow(
                label: L10n.string("Mark Speakers"),
                labelHelp: L10n.string("Tints waveforms by speaker. Voices are matched across clips using cloud transcripts."),
                labelAlignment: .leading,
                onReset: { editor.markSpeakers = false }
            ) {
                Toggle(String(), isOn: Binding(
                    get: { editor.markSpeakers },
                    set: { editor.markSpeakers = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityLabel(L10n.string("Mark Speakers"))
            }
            Button(editor.projectSpeakers.isEmpty ? L10n.string("Identify Speakers") : L10n.string("Refresh")) {
                editor.identifySpeakers(transcribeMissing: true)
            }
            .buttonStyle(.capsule(.secondary))
            .disabled(editor.speakerIdentifyInFlight)
            .help(L10n.string("Matches voices across clips, transcribing untranscribed timeline clips first (uses credits). Transcripts and voice fingerprints are cached, so re-runs are fast."))
            if let error = editor.speakerIdentifyError {
                Text(error)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !editor.projectSpeakers.isEmpty {
                Text(L10n.string("Labels"))
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .padding(.top, AppTheme.Spacing.xs)
            }
            ForEach(editor.projectSpeakers) { speaker in
                HStack(spacing: AppTheme.Spacing.sm) {
                    ColorPicker(String(), selection: Binding(
                        get: { editor.projectSpeakers.first(where: { $0.id == speaker.id })?.color ?? speaker.color },
                        set: { editor.setSpeakerColor(id: speaker.id, color: $0) }
                    ))
                    .labelsHidden()
                    .controlSize(.small)
                    TextField(L10n.string("Name"), text: Binding(
                        get: { editor.projectSpeakers.first(where: { $0.id == speaker.id })?.name ?? speaker.name },
                        set: { editor.renameSpeaker(id: speaker.id, name: $0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.system(size: AppTheme.FontSize.sm))
                    Button {
                        editor.removeSpeaker(id: speaker.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.string("Removes this label and tint. Identify recreates it if the voice is still present."))
                }
            }
        }
    }

    private var silenceSection: some View {
        EditorPanelGroup(L10n.string("Silence Detection"), contentInsets: sectionContentInsets) {
            InspectorRow(
                label: L10n.string("Mark Silence"),
                labelHelp: L10n.string("Speech is detected on-device in the background. Dims quiet, speech-free spans on timeline waveforms."),
                labelAlignment: .leading,
                onReset: { editor.markDeadAir = false }
            ) {
                Toggle(String(), isOn: Binding(
                    get: { editor.markDeadAir },
                    set: { editor.markDeadAir = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityLabel(L10n.string("Mark Silence"))
            }
            if editor.speechAnalyzingCount > 0 {
                HStack(spacing: AppTheme.Spacing.xs) {
                    ProgressView()
                        .controlSize(.small)
                    Text(editor.speechAnalyzingCount == 1
                        ? L10n.string("Detecting speech…")
                        : L10n.string("Detecting speech in \(editor.speechAnalyzingCount) files…"))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
            }
            silenceTimingControls
            removeSilenceRow
        }
    }

    private var silenceTimingControls: some View {
        Group {
            InspectorRow(
                label: L10n.string("Minimum Pause"),
                labelHelp: L10n.string("Ignores speech-free pauses shorter than this."),
                labelAlignment: .leading,
                onReset: {
                    editor.setMinimumSilenceDuration(SilenceRemovalSettings.default.minimumPauseSeconds)
                }
            ) {
                durationField(
                    label: L10n.string("Minimum Pause"),
                    value: editor.silenceRemovalSettings.minimumPauseSeconds,
                    range: SilenceRemovalSettings.minimumPauseRange,
                    step: 0.05,
                    set: editor.setMinimumSilenceDuration
                )
            }
            InspectorRow(
                label: L10n.string("Speech Padding"),
                labelHelp: L10n.string("Keeps this much audio before and after detected speech."),
                labelAlignment: .leading,
                onReset: {
                    editor.setSpeechPaddingDuration(SilenceRemovalSettings.default.speechPaddingSeconds)
                }
            ) {
                durationField(
                    label: L10n.string("Speech Padding"),
                    value: editor.silenceRemovalSettings.speechPaddingSeconds,
                    range: SilenceRemovalSettings.speechPaddingRange,
                    step: 0.025,
                    set: editor.setSpeechPaddingDuration
                )
            }
        }
    }

    private func durationField(
        label: String,
        value: Double,
        range: ClosedRange<Double>,
        step: Double,
        set: @escaping (Double) -> Void
    ) -> some View {
        ScrubbableNumberField(
            value: value,
            range: range,
            displayMultiplier: 1_000,
            format: "%.0f",
            valueSuffix: " ms",
            dragSensitivity: 10,
            dragValueAdjustment: { ($0 / step).rounded() * step },
            onChanged: set,
            onCommit: set
        )
        .accessibilityLabel(L10n.string(key: label))
    }

    private var removeSilenceRow: some View {
        let count = editor.allDeadAir().reduce(0) { $0 + $1.ranges.count }
        return HStack(spacing: AppTheme.Spacing.sm) {
            Button(L10n.string("Remove")) { editor.removeAllDeadAir() }
                .buttonStyle(.capsule(.secondary))
                .disabled(count == 0)
                .help(L10n.string("Ripple-deletes every silent section; downstream clips close the gaps."))
            if count > 0 {
                Text(count == 1 ? L10n.string("1 section") : L10n.string("\(count) sections"))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
        }
    }

    private var sectionContentInsets: EdgeInsets {
        EdgeInsets(
            top: AppTheme.Spacing.smMd,
            leading: AppTheme.Spacing.mdLg,
            bottom: AppTheme.Spacing.smMd,
            trailing: AppTheme.Spacing.mdLg
        )
    }
}
