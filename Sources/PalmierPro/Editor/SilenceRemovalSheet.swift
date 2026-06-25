import SwiftUI

struct SilenceRemovalSheet: View {
    @Environment(EditorViewModel.self) private var editor
    @Environment(\.dismiss) private var dismiss

    @State private var config = SilenceConfig()
    @State private var detectedCount: Int?
    @State private var detectedSilences: [(start: Double, end: Double)] = []
    @State private var isDetecting = false
    @State private var errorMessage: String?

    // dB ↔ linear helpers (display only; SilenceConfig stores linear).
    private var thresholdDb: Double {
        get { 20.0 * log10(max(Double(config.thresholdLinear), 1e-6)) }
        nonmutating set { config.thresholdLinear = Float(pow(10.0, newValue / 20.0)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            Text("Remove Silence")
                .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)

            Divider()

            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                labeledSlider(
                    label: "Threshold",
                    value: Binding(get: { thresholdDb }, set: { thresholdDb = $0 }),
                    range: -60 ... -6,
                    format: { "\(Int($0)) dB" }
                )
                labeledSlider(
                    label: "Min duration",
                    value: $config.minSilenceDuration,
                    range: 0.1 ... 3.0,
                    format: { String(format: "%.1f s", $0) }
                )
                labeledSlider(
                    label: "Edge padding",
                    value: $config.edgePaddingSeconds,
                    range: 0.0 ... 0.3,
                    format: { String(format: "%.2f s", $0) }
                )
            }

            statusRow

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Remove Silences") { applyAndDismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(detectedSilences.isEmpty || isDetecting)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: 360)
        .task { await runDetect() }
        .onChange(of: config) { _, _ in
            detectedCount = nil
            detectedSilences = []
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            if isDetecting {
                ProgressView()
                    .controlSize(.small)
                Text("Detecting…")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            } else if let count = detectedCount {
                Image(systemName: count > 0 ? "waveform.badge.minus" : "checkmark.circle")
                    .foregroundStyle(count > 0 ? AppTheme.Text.secondaryColor : AppTheme.Text.mutedColor)
                Text(count > 0 ? "\(count) silence\(count == 1 ? "" : "s") detected" : "No silences found")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            } else if let err = errorMessage {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Text(err)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            Spacer()
            Button("Detect") { Task { await runDetect() } }
                .disabled(isDetecting)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private func labeledSlider<V>(
        label: String,
        value: Binding<V>,
        range: ClosedRange<V>,
        format: @escaping (V) -> String
    ) -> some View where V: BinaryFloatingPoint, V.Stride: BinaryFloatingPoint {
        HStack {
            Text(label)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: 88, alignment: .leading)
            Slider(value: value, in: range)
                .tint(AppTheme.Accent.primary)
            Text(format(value.wrappedValue))
                .font(.system(size: AppTheme.FontSize.sm).monospacedDigit())
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: 52, alignment: .trailing)
        }
    }

    private func runDetect() async {
        isDetecting = true
        errorMessage = nil
        detectedCount = nil
        detectedSilences = []
        do {
            let silences = try await editor.detectSilences(config: config)
            detectedSilences = silences
            detectedCount = silences.count
        } catch {
            errorMessage = error.localizedDescription
        }
        isDetecting = false
    }

    private func applyAndDismiss() {
        guard let clip = editor.silenceRemovalCandidate else { return }
        editor.removeSilences(clip: clip, silences: detectedSilences)
        dismiss()
    }
}
