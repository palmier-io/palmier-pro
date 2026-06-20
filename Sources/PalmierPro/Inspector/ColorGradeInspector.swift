import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ColorGradeInspector: View {
    @Environment(EditorViewModel.self) var editor
    @State private var lutLibrary = LUTLibrary.shared

    private var grade: LUTRef? { editor.timeline.lut }

    private let sliderWidth: CGFloat = 90
    private let valueWidth: CGFloat = 32

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            InspectorRow(icon: "camera.filters", label: "Look") {
                Picker("", selection: lookBinding) {
                    Text("None").tag("none")
                    ForEach(ColorGradeCatalog.all, id: \.id) { look in
                        Text(look.name).tag(look.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .tint(AppTheme.Text.secondaryColor)
            }

            if grade != nil {
                InspectorRow(icon: "slider.horizontal.3", label: "Intensity") {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Slider(value: intensityBinding, in: 0...1)
                            .controlSize(.mini)
                            .tint(AppTheme.Accent.primary)
                            .frame(width: sliderWidth)
                        Text("\(Int((grade?.clampedIntensity ?? 1) * 100))%")
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                            .monospacedDigit()
                            .frame(width: valueWidth, alignment: .trailing)
                    }
                }
            }

            InspectorRow(icon: "square.stack.3d.forward.dottedline", label: "Custom LUT") {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Button(action: loadLUT) {
                        Text(cubeLabel)
                            .font(.system(size: AppTheme.FontSize.xs))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.Accent.primary)
                    if grade?.kind == .cube {
                        Button { editor.setColorGrade(nil) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                        }
                        .buttonStyle(.plain)
                        .help("Remove LUT")
                    }
                }
            }

            InspectorRow(icon: "swatchpalette", label: "LUT Library") {
                if lutLibrary.isConfigured {
                    Menu(lutLibrary.folderName) {
                        ForEach(lutLibrary.groups, id: \.category) { group in
                            Menu(group.category) {
                                ForEach(group.luts) { lut in
                                    Button(lut.name) { applyCube(at: lut.url) }
                                }
                            }
                        }
                        Divider()
                        Button("Change Folder…") { chooseLUTFolder() }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                } else {
                    Button("Choose Folder…") { chooseLUTFolder() }
                        .buttonStyle(.plain)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Accent.primary)
                }
            }

            if grade != nil {
                Button { editor.setColorGrade(nil) } label: {
                    Text("Clear grade")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                .buttonStyle(.plain)
            }

            Divider().opacity(AppTheme.Opacity.faint)

            sliderRow("Temperature", "thermometer.medium", \.temperature)
            sliderRow("Tint", "drop", \.tint)
            sliderRow("Exposure", "sun.max", \.exposure)
            sliderRow("Contrast", "circle.lefthalf.filled", \.contrast)
            sliderRow("Saturation", "paintpalette", \.saturation)
            sliderRow("Vibrance", "sparkles", \.vibrance)
            sliderRow("Highlights", "sun.max.fill", \.highlights)
            sliderRow("Shadows", "moon.fill", \.shadows)

            Divider().opacity(AppTheme.Opacity.faint)
            CurveEditorView()

            if editor.timeline.primaries != nil {
                Button { editor.setColorPrimaries(nil) } label: {
                    Text("Reset adjustments")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func sliderRow(_ label: String, _ icon: String, _ kp: WritableKeyPath<PrimaryGrade, Double>) -> some View {
        InspectorRow(icon: icon, label: label) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Slider(value: primaryBinding(kp), in: -100...100)
                    .controlSize(.mini)
                    .tint(AppTheme.Accent.primary)
                    .frame(width: sliderWidth)
                Text("\(Int(editor.timeline.primaries?[keyPath: kp] ?? 0))")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .monospacedDigit()
                    .frame(width: valueWidth, alignment: .trailing)
            }
        }
    }

    private func primaryBinding(_ kp: WritableKeyPath<PrimaryGrade, Double>) -> Binding<Double> {
        Binding(
            get: { editor.timeline.primaries?[keyPath: kp] ?? 0 },
            set: { value in
                var p = editor.timeline.primaries ?? PrimaryGrade()
                p[keyPath: kp] = value
                editor.setColorPrimaries(p)
            }
        )
    }

    private var cubeLabel: String {
        if grade?.kind == .cube, let name = grade?.cubeName { return name }
        return "Load .cube…"
    }

    private var lookBinding: Binding<String> {
        Binding(
            get: { grade?.kind == .look ? (grade?.lookID ?? "none") : "none" },
            set: { id in
                if id == "none" {
                    editor.setColorGrade(nil)
                } else {
                    editor.setColorGrade(.look(id, intensity: grade?.clampedIntensity ?? 1.0))
                }
            }
        )
    }

    private var intensityBinding: Binding<Double> {
        Binding(
            get: { grade?.clampedIntensity ?? 1.0 },
            set: { value in
                guard var updated = editor.timeline.lut else { return }
                updated.intensity = value
                editor.setColorGrade(updated)
            }
        )
    }

    private func loadLUT() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.allowsMultipleSelection = false
        panel.prompt = "Load LUT"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        applyCube(at: url)
    }

    private func applyCube(at url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let cube = try? CubeLUTParser.parse(text) else { return }
        let name = url.deletingPathExtension().lastPathComponent
        editor.setColorGrade(.cube(cube, name: name, intensity: grade?.clampedIntensity ?? 1.0))
    }

    private func chooseLUTFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose a folder of .cube LUTs (e.g. your DaVinci Resolve LUT folder)."
        if let suggested = LUTLibrary.suggestedFolder { panel.directoryURL = suggested }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        lutLibrary.setFolder(url)
    }
}
