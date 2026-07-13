import SwiftUI

struct SpeechTab: View {
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.mdLg) {
                    speakersSection
                    silenceSection
                }
                .padding(.horizontal, AppTheme.Spacing.lgXl)
                .padding(.top, AppTheme.Spacing.md)
                .padding(.bottom, AppTheme.Spacing.md)
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
        InspectorSection("Speakers") {
            InspectorRow(
                icon: "person.wave.2",
                label: "Mark Speakers",
                labelHelp: "Tints waveforms by speaker. Voices are matched across clips using cloud transcripts."
            ) {
                Toggle("", isOn: Binding(
                    get: { editor.markSpeakers },
                    set: { editor.markSpeakers = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }
            HStack(spacing: AppTheme.Spacing.sm) {
                Button(editor.projectSpeakers.isEmpty ? "Identify Speakers" : "Refresh") { editor.identifySpeakers(transcribeMissing: true) }
                    .controlSize(.small)
                    .disabled(editor.speakerIdentifyInFlight)
                    .help("Matches voices across clips, transcribing untranscribed timeline clips first (uses credits). Transcripts and voice fingerprints are cached, so re-runs are fast.")
            }
            if let error = editor.speakerIdentifyError {
                Text(error)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !editor.projectSpeakers.isEmpty {
                Text("Labels")
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .padding(.top, AppTheme.Spacing.xs)
            }
            ForEach(editor.projectSpeakers) { speaker in
                HStack(spacing: AppTheme.Spacing.sm) {
                    ColorPicker("", selection: Binding(
                        get: { editor.projectSpeakers.first(where: { $0.id == speaker.id })?.color ?? speaker.color },
                        set: { editor.setSpeakerColor(id: speaker.id, color: $0) }
                    ))
                    .labelsHidden()
                    .controlSize(.small)
                    TextField("Name", text: Binding(
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
                    .help("Removes this label and tint. Identify recreates it if the voice is still present.")
                }
            }
        }
    }

    private var silenceSection: some View {
        InspectorSection("Silence Detection") {
            InspectorRow(
                icon: "waveform.badge.mic",
                label: "Mark Silence",
                labelHelp: "Speech is detected on-device in the background. Dims quiet, speech-free spans on timeline waveforms."
            ) {
                Toggle("", isOn: Binding(
                    get: { editor.markDeadAir },
                    set: { editor.markDeadAir = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }
            if editor.speechAnalyzingCount > 0 {
                HStack(spacing: AppTheme.Spacing.xs) {
                    ProgressView()
                        .controlSize(.small)
                    Text(editor.speechAnalyzingCount == 1
                        ? "Detecting speech…"
                        : "Detecting speech in \(editor.speechAnalyzingCount) files…")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
            }
            removeSilenceRow
        }
    }

    private var removeSilenceRow: some View {
        let count = editor.allDeadAir().reduce(0) { $0 + $1.ranges.count }
        return HStack(spacing: AppTheme.Spacing.sm) {
            Button("Remove Silence") { editor.removeAllDeadAir() }
                .controlSize(.small)
                .disabled(count == 0)
                .help("Ripple-deletes every silent section; downstream clips close the gaps.")
            if count > 0 {
                Text(count == 1 ? "1 section" : "\(count) sections")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
        }
    }
}
