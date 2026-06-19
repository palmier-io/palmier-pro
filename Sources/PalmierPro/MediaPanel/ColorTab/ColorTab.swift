import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Lumetri-style colour panel. Grades the selected clip (per-clip) or adjustment
/// layer, and keys video clips. The target clip is cached so clicking a control
/// in this dock — which clears the timeline selection — doesn't drop the panel.
struct ColorTab: View {
    @Environment(EditorViewModel.self) var editor
    @State private var targetClipId: String?
    @State private var lutError: String?

    private var target: (id: String, clip: Clip)? {
        guard let id = targetClipId, let loc = editor.findClip(id: id) else { return nil }
        return (id, editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex])
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.mdLg) {
                    if let t = target, t.clip.mediaType == .adjustment {
                        targetHeader("Adjustment Layer", icon: "circle.lefthalf.filled")
                        gradeSections(clipId: t.id, grade: t.clip.colorGrade ?? ColorGrade())
                    } else if let t = target, t.clip.mediaType.isVisual {
                        targetHeader(editor.mediaResolver.displayName(for: t.clip.mediaRef), icon: t.clip.mediaType.sfSymbolName)
                        gradeSections(clipId: t.id, grade: t.clip.colorGrade ?? ColorGrade())
                        chromaSection(clipId: t.id, key: t.clip.chromaKey ?? ChromaKey())
                    } else {
                        emptyState
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.lgXl)
                .padding(.vertical, AppTheme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            newLayerBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Background.surfaceColor)
        .onAppear { rememberTarget() }
        .onChange(of: editor.selectedClipIds) { _, _ in rememberTarget() }
    }

    /// Mirror CaptionTab: keep the cached target when the selection is cleared by a
    /// click into this (media) dock; only clear it on a genuine timeline deselect.
    private func rememberTarget() {
        let sel = editor.selectedClipIds.first
        guard sel != nil || editor.focusedPanel != .media else { return }
        targetClipId = sel
    }

    private func targetHeader(_ name: String, icon: String) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: icon).font(.system(size: AppTheme.FontSize.sm))
            Text(name).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.semibold))
        .foregroundStyle(AppTheme.Text.primaryColor)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Grade

    private func gradeSections(clipId: String, grade: ColorGrade) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.mdLg) {
            InspectorSection("Basic Correction") {
                enableRow(isOn: grade.basicEnabled) { v in updateGrade(clipId) { $0.basicEnabled = v } }
                slider("thermometer.medium", "Temperature", grade.temperature, -100...100) { v in updateGrade(clipId) { $0.temperature = v } }
                slider("dial.medium", "Tint", grade.tint, -100...100) { v in updateGrade(clipId) { $0.tint = v } }
                slider("sun.max", "Exposure", grade.exposure, -100...100) { v in updateGrade(clipId) { $0.exposure = v } }
                slider("circle.lefthalf.filled", "Contrast", grade.contrast, -100...100) { v in updateGrade(clipId) { $0.contrast = v } }
                slider("drop", "Saturation", grade.saturation, -100...100) { v in updateGrade(clipId) { $0.saturation = v } }
            }

            InspectorSection("Creative (LUT)") {
                enableRow(isOn: grade.creativeEnabled) { v in updateGrade(clipId) { $0.creativeEnabled = v } }
                InspectorRow(icon: "camera.filters", label: "Look") {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Text(lutName(grade.lutRef))
                            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                            .lineLimit(1).truncationMode(.middle)
                        Button("Import…") { importLUT(clipId) }
                            .buttonStyle(.plain).focusable(false)
                            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                            .foregroundStyle(AppTheme.Accent.primary)
                        if grade.lutRef != nil {
                            Button { updateGrade(clipId) { $0.lutRef = nil } } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).focusable(false)
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                        }
                    }
                }
                if grade.lutRef != nil {
                    slider("slider.horizontal.below.square.filled.and.square", "Intensity", grade.lutIntensity * 100, 0...100) { v in
                        updateGrade(clipId) { $0.lutIntensity = v / 100 }
                    }
                }
                if let lutError {
                    Text(lutError)
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Status.errorColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Chroma key

    private func chromaSection(clipId: String, key: ChromaKey) -> some View {
        InspectorSection("Chroma Key (Ultra Key)") {
            enableRow(isOn: key.enabled) { v in updateKey(clipId) { $0.enabled = v } }
            InspectorRow(icon: "eyedropper", label: "Key Color") {
                ColorField(displayColor: key.keyColor.swiftUIColor, onUserChange: { c in
                    updateKey(clipId) { $0.keyColor = TextStyle.RGBA(c) }
                }, supportsOpacity: false)
            }
            slider("scope", "Tolerance", key.tolerance, 0...100) { v in updateKey(clipId) { $0.tolerance = v } }
            slider("aqi.medium", "Softness", key.softness, 0...100) { v in updateKey(clipId) { $0.softness = v } }
            slider("paintbrush.pointed", "Spill", key.spill, 0...100) { v in updateKey(clipId) { $0.spill = v } }
            slider("circle.dashed", "Edge Feather", key.edgeFeather, 0...50) { v in updateKey(clipId) { $0.edgeFeather = v } }
        }
    }

    // MARK: - Shared rows

    private func enableRow(isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        InspectorRow(icon: "power", label: "Enabled") {
            Toggle("", isOn: Binding(get: { isOn }, set: set))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .tint(AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.strong))
        }
    }

    private func slider(_ icon: String, _ label: String, _ value: Double,
                        _ range: ClosedRange<Double>, set: @escaping (Double) -> Void) -> some View {
        InspectorRow(icon: icon, label: label) {
            ScrubbableNumberField(value: value, range: range, format: "%.0f", onChanged: set, onCommit: set)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("Color")
                .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Text("Select a clip to grade it (LUT + colour) and key out a green screen, or add an adjustment layer to grade everything below it.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, AppTheme.Spacing.sm)
    }

    private var newLayerBar: some View {
        Button(action: { targetClipId = editor.addAdjustmentLayer() }) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "plus")
                Text("New Adjustment Layer")
            }
            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
            .foregroundStyle(AppTheme.Background.baseColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppTheme.Spacing.smMd)
            .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(AppTheme.Accent.primary))
        }
        .buttonStyle(.plain).focusable(false)
        .padding(.horizontal, AppTheme.Spacing.lgXl)
        .padding(.vertical, AppTheme.Spacing.md)
        .overlay(alignment: .top) {
            Rectangle().fill(AppTheme.Border.subtleColor).frame(height: AppTheme.BorderWidth.hairline)
        }
    }

    // MARK: - Mutation helpers

    private func updateGrade(_ clipId: String, _ mutate: (inout ColorGrade) -> Void) {
        guard let loc = editor.findClip(id: clipId) else { return }
        var g = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].colorGrade ?? ColorGrade()
        mutate(&g)
        editor.setColorGrade(clipId: clipId, g)
    }

    private func updateKey(_ clipId: String, _ mutate: (inout ChromaKey) -> Void) {
        guard let loc = editor.findClip(id: clipId) else { return }
        var k = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].chromaKey ?? ChromaKey()
        mutate(&k)
        editor.setChromaKey(clipId: clipId, k)
    }

    private func lutName(_ ref: String?) -> String {
        guard let ref else { return "None" }
        return (ref as NSString).lastPathComponent
    }

    private func importLUT(_ clipId: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Import LUT (.cube)"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                _ = try CubeLUT.parse(contentsOf: url)
            } catch {
                lutError = "Invalid .cube file: \(error.localizedDescription)"
                return
            }
            lutError = nil
            updateGrade(clipId) { $0.lutRef = url.path; $0.creativeEnabled = true }
        }
    }
}
