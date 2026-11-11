import UniformTypeIdentifiers
import AppKit
import Foundation

#if canImport(SwiftUI)
import SwiftUI
#endif

/// Interactive visual wizard for creating and editing frame.md / design.md brand specifications.
/// Provides a SwiftUI/AppKit interface for color palettes, typography, canvas geometry, and pacing.
@MainActor
final class DesignSpecWizard: ObservableObject {
    @Published var spec: DesignSpec
    @Published var validationErrors: [String] = []
    @Published var isDirty = false
    @Published var previewImage: NSImage?

    private let editor: EditorViewModel

    init(editor: EditorViewModel, initialSpec: DesignSpec? = nil) {
        self.editor = editor
        self.spec = initialSpec ?? editor.exportCurrentDesignSpec()
        validate()
    }

    /// Validates the current spec and updates validationErrors
    func validate() {
        var errors: [String] = []

        // Check palette colors
        if spec.palette.background == nil && spec.palette.surface == nil {
            errors.append("At least one palette color (background or surface) should be defined")
        }

        // Check typography
        if spec.typography.displayFont == nil && spec.typography.bodyFont == nil {
            errors.append("At least one font (display or body) should be defined")
        }

        // Check canvas
        if spec.canvas.resolvedDimensions() == nil {
            errors.append("Canvas aspect ratio or explicit resolution should be defined")
        }

        validationErrors = errors
    }

    /// Applies the spec to the editor
    func apply() throws {
        let _ = try editor.applyDesignSpec(spec)
        isDirty = false
    }

    /// Exports the spec as frame.md markdown
    func exportMarkdown() -> String {
        DesignSpecParser.exportMarkdown(spec: spec)
    }

    /// Saves the spec to a file
    func save(to url: URL) throws {
        let markdown = exportMarkdown()
        try markdown.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Loads a spec from a file
    static func load(from url: URL) throws -> DesignSpec {
        let markdown = try String(contentsOf: url, encoding: .utf8)
        return try DesignSpecParser.parse(markdown: markdown)
    }

    /// Creates a spec from the current editor state
    static func fromEditor(_ editor: EditorViewModel) -> DesignSpec {
        editor.exportCurrentDesignSpec()
    }

    /// Resets to editor's current state
    func resetToEditor() {
        spec = editor.exportCurrentDesignSpec()
        isDirty = false
        validate()
    }

    // MARK: - Color Palette Helpers

    func bindingForPaletteColor(_ keyPath: WritableKeyPath<DesignSpec.Palette, TextStyle.RGBA?>) -> Binding<TextStyle.RGBA?> {
        Binding(
            get: { self.spec.palette[keyPath: keyPath] },
            set: { newValue in
                self.spec.palette[keyPath: keyPath] = newValue
                self.isDirty = true
                self.validate()
            }
        )
    }

    func bindingForPaletteCustomColor(key: String) -> Binding<TextStyle.RGBA?> {
        Binding(
            get: { self.spec.palette.custom[key] },
            set: { newValue in
                if let newValue {
                    self.spec.palette.custom[key] = newValue
                } else {
                    self.spec.palette.custom.removeValue(forKey: key)
                }
                self.isDirty = true
                self.validate()
            }
        )
    }

    // MARK: - Typography Helpers

    var displayFontBinding: Binding<String?> {
        Binding(
            get: { self.spec.typography.displayFont },
            set: { newValue in
                self.spec.typography.displayFont = newValue
                self.isDirty = true
                self.validate()
            }
        )
    }

    var bodyFontBinding: Binding<String?> {
        Binding(
            get: { self.spec.typography.bodyFont },
            set: { newValue in
                self.spec.typography.bodyFont = newValue
                self.isDirty = true
                self.validate()
            }
        )
    }

    var baseSizeBinding: Binding<Double?> {
        Binding(
            get: { self.spec.typography.baseSize },
            set: { newValue in
                self.spec.typography.baseSize = newValue
                self.isDirty = true
                self.validate()
            }
        )
    }

    // MARK: - Canvas Helpers

    var aspectRatioBinding: Binding<String> {
        Binding(
            get: { self.spec.canvas.aspectRatio ?? "" },
            set: { newValue in
                self.spec.canvas.aspectRatio = newValue.isEmpty ? nil : newValue
                self.spec.canvas.width = nil
                self.spec.canvas.height = nil
                self.isDirty = true
                self.validate()
            }
        )
    }

    var widthBinding: Binding<Int?> {
        Binding(
            get: { self.spec.canvas.width },
            set: { newValue in
                self.spec.canvas.width = newValue
                if newValue != nil { self.spec.canvas.aspectRatio = nil }
                self.isDirty = true
                self.validate()
            }
        )
    }

    var heightBinding: Binding<Int?> {
        Binding(
            get: { self.spec.canvas.height },
            set: { newValue in
                self.spec.canvas.height = newValue
                if newValue != nil { self.spec.canvas.aspectRatio = nil }
                self.isDirty = true
                self.validate()
            }
        )
    }

    var resolvedDimensions: (width: Int, height: Int)? {
        spec.canvas.resolvedDimensions()
    }

    // MARK: - Pacing Helpers

    var targetShotDurationBinding: Binding<Double?> {
        Binding(
            get: { self.spec.pacing.targetShotDurationSeconds },
            set: { newValue in
                self.spec.pacing.targetShotDurationSeconds = newValue
                self.isDirty = true
                self.validate()
            }
        )
    }

    var minShotDurationBinding: Binding<Double?> {
        Binding(
            get: { self.spec.pacing.minShotDurationSeconds },
            set: { newValue in
                self.spec.pacing.minShotDurationSeconds = newValue
                self.isDirty = true
                self.validate()
            }
        )
    }

    var maxShotDurationBinding: Binding<Double?> {
        Binding(
            get: { self.spec.pacing.maxShotDurationSeconds },
            set: { newValue in
                self.spec.pacing.maxShotDurationSeconds = newValue
                self.isDirty = true
                self.validate()
            }
        )
    }

    // MARK: - Grade Helpers

    var gradePresetBinding: Binding<String> {
        Binding(
            get: { self.spec.grade.preset ?? "" },
            set: { newValue in
                self.spec.grade.preset = newValue.isEmpty ? nil : newValue
                self.isDirty = true
                self.validate()
            }
        )
    }

    var exposureBinding: Binding<Double?> {
        Binding(
            get: { self.spec.grade.exposure },
            set: { newValue in
                self.spec.grade.exposure = newValue
                self.isDirty = true
                self.validate()
            }
        )
    }

    var contrastBinding: Binding<Double?> {
        Binding(
            get: { self.spec.grade.contrast },
            set: { newValue in
                self.spec.grade.contrast = newValue
                self.isDirty = true
                self.validate()
            }
        )
    }

    // MARK: - Caption Helpers

    var captionTemplateBinding: Binding<String> {
        Binding(
            get: { self.spec.caption.templateId ?? "" },
            set: { newValue in
                self.spec.caption.templateId = newValue.isEmpty ? nil : newValue
                self.isDirty = true
                self.validate()
            }
        )
    }

    var captionFormatBinding: Binding<String> {
        Binding(
            get: { self.spec.caption.format ?? "" },
            set: { newValue in
                self.spec.caption.format = newValue.isEmpty ? nil : newValue
                self.isDirty = true
                self.validate()
            }
        )
    }
}

#if canImport(SwiftUI)
/// SwiftUI view for the Design Spec Wizard
struct DesignSpecWizardView: View {
    @StateObject var wizard: DesignSpecWizard
    @Environment(\.dismiss) private var dismiss
    @State private var showingFileImporter = false
    @State private var showingFileExporter = false
    @State private var exportURL: URL?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                    // Header
                    headerSection

                    // Validation errors
                    if !wizard.validationErrors.isEmpty {
                        validationSection
                    }

                    // Palette
                    paletteSection

                    // Typography
                    typographySection

                    // Canvas
                    canvasSection

                    // Pacing
                    pacingSection

                    // Grade
                    gradeSection

                    // Caption
                    captionSection

                    // Actions
                    actionSection
                }
                .padding(AppTheme.Spacing.lg)
            }
            .navigationTitle("Design Spec Wizard")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        do {
                            try wizard.apply()
                            dismiss()
                        } catch {
                            // Error handled by validation
                        }
                    }
                    .disabled(!wizard.isDirty || !wizard.validationErrors.isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.plainText, UTType(filenameExtension: "md")!],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        do {
                            wizard.spec = try DesignSpecWizard.load(from: url)
                            wizard.isDirty = true
                            wizard.validate()
                        } catch {
                            wizard.validationErrors = ["Failed to load: \(error.localizedDescription)"]
                        }
                    }
                case .failure(let error):
                    wizard.validationErrors = ["Import failed: \(error.localizedDescription)"]
                }
            }
            .fileExporter(
                isPresented: $showingFileExporter,
                document: FrameMDDocument(content: wizard.exportMarkdown()),
                contentType: .plainText,
                defaultFilename: "frame.md"
            ) { result in
                if case .failure(let error) = result {
                    wizard.validationErrors = ["Export failed: \(error.localizedDescription)"]
                }
            }
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("frame.md Visual Wizard")
                .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.bold))
            Text("Create and edit video design specifications for consistent branding across your project.")
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, AppTheme.Spacing.sm)
    }

    private var validationSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Label("Validation Issues", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(.orange)
            ForEach(wizard.validationErrors, id: \.self) { error in
                Text(error)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(AppTheme.Spacing.md)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
    }

    private var paletteSection: some View {
        WizardSection(title: "Color Palette", systemImage: "paintpalette") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: AppTheme.Spacing.md) {
                PaletteColorRow(
                    label: "Background",
                    color: wizard.bindingForPaletteColor(\.background),
                    help: "Main background color"
                )
                PaletteColorRow(
                    label: "Surface",
                    color: wizard.bindingForPaletteColor(\.surface),
                    help: "Card/surface background color"
                )
                PaletteColorRow(
                    label: "Text",
                    color: wizard.bindingForPaletteColor(\.text),
                    help: "Primary text color"
                )
                PaletteColorRow(
                    label: "Primary",
                    color: wizard.bindingForPaletteColor(\.primary),
                    help: "Primary brand color"
                )
                PaletteColorRow(
                    label: "Accent",
                    color: wizard.bindingForPaletteColor(\.accent),
                    help: "Accent/highlight color"
                )
                PaletteColorRow(
                    label: "Border",
                    color: wizard.bindingForPaletteColor(\.border),
                    help: "Border/divider color"
                )
            }

            // Custom colors
            if !wizard.spec.palette.custom.isEmpty {
                Divider()
                Text("Custom Colors")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                ForEach(Array(wizard.spec.palette.custom.keys.sorted()), id: \.self) { key in
                    HStack {
                        PaletteColorRow(
                            label: key,
                            color: wizard.bindingForPaletteCustomColor(key: key),
                            help: "Custom palette color"
                        )
                        Button {
                            wizard.spec.palette.custom.removeValue(forKey: key)
                            wizard.isDirty = true
                            wizard.validate()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button {
                let newKey = "custom\(wizard.spec.palette.custom.count + 1)"
                wizard.spec.palette.custom[newKey] = TextStyle.RGBA(r: 0, g: 0, b: 0, a: 1)
                wizard.isDirty = true
                wizard.validate()
            } label: {
                Label("Add Custom Color", systemImage: "plus")
            }
            .buttonStyle(.bordered)
        }
    }

    private var typographySection: some View {
        WizardSection(title: "Typography", systemImage: "textformat") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                FontPickerRow(
                    label: "Display Font",
                    fontName: wizard.displayFontBinding,
                    help: "Font for headlines and titles"
                )
                FontPickerRow(
                    label: "Body Font",
                    fontName: wizard.bodyFontBinding,
                    help: "Font for body text and captions"
                )

                HStack {
                    Text("Base Size")
                        .frame(width: 100, alignment: .leading)
                    TextField("pt", value: wizard.baseSizeBinding, formatter: NumberFormatter())
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("pt")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var canvasSection: some View {
        WizardSection(title: "Canvas Geometry", systemImage: "rectangle.portrait") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                Picker("Mode", selection: Binding(
                    get: { wizard.spec.canvas.aspectRatio != nil ? 0 : 1 },
                    set: { newValue in
                        if newValue == 0 {
                            wizard.spec.canvas.width = nil
                            wizard.spec.canvas.height = nil
                            wizard.spec.canvas.aspectRatio = "16:9"
                        } else {
                            wizard.spec.canvas.aspectRatio = nil
                        }
                        wizard.isDirty = true
                        wizard.validate()
                    }
                )) {
                    Text("Aspect Ratio").tag(0)
                    Text("Explicit Resolution").tag(1)
                }
                .pickerStyle(.segmented)

                if wizard.spec.canvas.aspectRatio != nil {
                    HStack {
                        Text("Aspect Ratio")
                            .frame(width: 100, alignment: .leading)
                        TextField("e.g., 16:9, 9:16, 1:1", text: wizard.aspectRatioBinding)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)
                    }

                    // Quick presets
                    HStack(spacing: AppTheme.Spacing.xs) {
                        ForEach(["16:9", "9:16", "1:1", "4:5", "21:9", "4:3"], id: \.self) { preset in
                            Button(preset) {
                                wizard.spec.canvas.aspectRatio = preset
                                wizard.isDirty = true
                                wizard.validate()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                } else {
                    HStack {
                        Text("Width")
                            .frame(width: 100, alignment: .leading)
                        TextField("px", value: wizard.widthBinding, formatter: NumberFormatter())
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Text("Height")
                            .frame(width: 50, alignment: .leading)
                        TextField("px", value: wizard.heightBinding, formatter: NumberFormatter())
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                }

                if let dims = wizard.resolvedDimensions {
                    Text("Resolved: \(dims.width) × \(dims.height)")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var pacingSection: some View {
        WizardSection(title: "Pacing", systemImage: "metronome") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                HStack {
                    Text("Target Shot Duration")
                        .frame(width: 180, alignment: .leading)
                    TextField("s", value: wizard.targetShotDurationBinding, formatter: NumberFormatter())
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("seconds")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Min Shot Duration")
                        .frame(width: 180, alignment: .leading)
                    TextField("s", value: wizard.minShotDurationBinding, formatter: NumberFormatter())
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("seconds")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Max Shot Duration")
                        .frame(width: 180, alignment: .leading)
                    TextField("s", value: wizard.maxShotDurationBinding, formatter: NumberFormatter())
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("seconds")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var gradeSection: some View {
        WizardSection(title: "Color Grade", systemImage: "camera.filters") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                HStack {
                    Text("Preset")
                        .frame(width: 100, alignment: .leading)
                    TextField("e.g., cinematic, vibrant, muted", text: wizard.gradePresetBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }

                Grid(horizontalSpacing: AppTheme.Spacing.md, verticalSpacing: AppTheme.Spacing.xs) {
                    GridRow {
                        Text("Exposure")
                            .frame(width: 100, alignment: .leading)
                        Slider(value: Binding(
                            get: { wizard.spec.grade.exposure ?? 0 },
                            set: { wizard.spec.grade.exposure = $0; wizard.isDirty = true }
                        ), in: -2...2)
                        Text(String(format: "%.1f", wizard.spec.grade.exposure ?? 0))
                            .frame(width: 40)
                    }
                    GridRow {
                        Text("Contrast")
                            .frame(width: 100, alignment: .leading)
                        Slider(value: Binding(
                            get: { wizard.spec.grade.contrast ?? 1 },
                            set: { wizard.spec.grade.contrast = $0; wizard.isDirty = true }
                        ), in: 0...3)
                        Text(String(format: "%.1f", wizard.spec.grade.contrast ?? 1))
                            .frame(width: 40)
                    }
                    GridRow {
                        Text("Saturation")
                            .frame(width: 100, alignment: .leading)
                        Slider(value: Binding(
                            get: { wizard.spec.grade.saturation ?? 1 },
                            set: { wizard.spec.grade.saturation = $0; wizard.isDirty = true }
                        ), in: 0...3)
                        Text(String(format: "%.1f", wizard.spec.grade.saturation ?? 1))
                            .frame(width: 40)
                    }
                    GridRow {
                        Text("Temperature")
                            .frame(width: 100, alignment: .leading)
                        Slider(value: Binding(
                            get: { wizard.spec.grade.temperature ?? 0 },
                            set: { wizard.spec.grade.temperature = $0; wizard.isDirty = true }
                        ), in: -100...100)
                        Text(String(format: "%.0f", wizard.spec.grade.temperature ?? 0))
                            .frame(width: 40)
                    }
                    GridRow {
                        Text("Tint")
                            .frame(width: 100, alignment: .leading)
                        Slider(value: Binding(
                            get: { wizard.spec.grade.tint ?? 0 },
                            set: { wizard.spec.grade.tint = $0; wizard.isDirty = true }
                        ), in: -100...100)
                        Text(String(format: "%.0f", wizard.spec.grade.tint ?? 0))
                            .frame(width: 40)
                    }
                }
            }
        }
    }

    private var captionSection: some View {
        WizardSection(title: "Captions", systemImage: "captions.bubble") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                HStack {
                    Text("Template")
                        .frame(width: 100, alignment: .leading)
                    TextField("Template ID", text: wizard.captionTemplateBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
                HStack {
                    Text("Format")
                        .frame(width: 100, alignment: .leading)
                    TextField("e.g., word-by-word, line-by-line", text: wizard.captionFormatBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
            }
        }
    }

    private var actionSection: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Button {
                showingFileImporter = true
            } label: {
                Label("Import frame.md", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)

            Button {
                showingFileExporter = true
            } label: {
                Label("Export frame.md", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)

            Button {
                wizard.resetToEditor()
            } label: {
                Label("Reset to Project", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .padding(.top, AppTheme.Spacing.md)
    }
}

/// Wizard section container
struct WizardSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Label(title, systemImage: systemImage)
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))

            content
        }
        .padding(AppTheme.Spacing.md)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
    }
}

/// Color picker row for palette
struct PaletteColorRow: View {
    let label: String
    @Binding var color: TextStyle.RGBA?
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack {
                Text(label)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(.secondary)
                Spacer()
                if color != nil {
                    Button {
                        color = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear")
                }
            }

            if let color {
                ColorPicker("", selection: Binding(
                    get: { Color(red: color.r, green: color.g, blue: color.b, opacity: color.a) },
                    set: { newColor in
                        let nsColor = NSColor(newColor)
                        self.color = TextStyle.RGBA(
                            r: nsColor.redComponent,
                            g: nsColor.greenComponent,
                            b: nsColor.blueComponent,
                            a: nsColor.alphaComponent
                        )
                    }
                ))
                .labelsHidden()
                .help(help)
            } else {
                Button("Set Color") {
                    color = TextStyle.RGBA(r: 0, g: 0, b: 0, a: 1)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(help)
            }
        }
        .padding(AppTheme.Spacing.xs)
    }
}

/// Font picker row
struct FontPickerRow: View {
    let label: String
    @Binding var fontName: String?
    let help: String

    var body: some View {
        HStack {
            Text(label)
                .frame(width: 100, alignment: .leading)
            Picker("", selection: Binding(
                get: { fontName ?? "" },
                set: { fontName = $0.isEmpty ? nil : $0 }
            )) {
                Text("System Default").tag(nil as String?)
                Divider()
                ForEach(NSFontManager.shared.availableFontFamilies.sorted(), id: \.self) { family in
                    Text(family).tag(family as String?)
                }
            }
            .frame(maxWidth: 250)
            .help(help)
        }
    }
}

/// Document wrapper for file export
struct FrameMDDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    static var writableContentTypes: [UTType] { [.plainText] }

    var content: String

    init(content: String) { self.content = content }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        content = string
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(content.utf8))
    }
}
#endif