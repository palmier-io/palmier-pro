import SwiftUI

struct ProjectSettingsPopover: View {
    @Environment(EditorViewModel.self) var editor
    @State private var selectedFPS: Int = 30
    @State private var selectedAspect: AspectPreset = .landscape16x9
    @State private var selectedQuality: QualityPreset = .p1080
    @State private var customWidth: String = ""
    @State private var customHeight: String = ""

    private static let fpsOptions = [24, 25, 30, 60]

    enum AspectPreset: String, CaseIterable, Identifiable {
        case landscape16x9 = "16:9"
        case ultrawide = "21:9"
        case square = "1:1"
        case portrait4x5 = "4:5"
        case portrait9x16 = "9:16"
        case custom = "Custom"

        var id: String { rawValue }

        var ratio: (w: Int, h: Int)? {
            switch self {
            case .landscape16x9: (16, 9)
            case .ultrawide: (21, 9)
            case .square: (1, 1)
            case .portrait4x5: (4, 5)
            case .portrait9x16: (9, 16)
            case .custom: nil
            }
        }

        var qualities: [QualityPreset] {
            switch self {
            case .landscape16x9: [.p4K, .p1080, .p720, .p480]
            case .ultrawide: [.p1080Ultra]
            case .square: [.p1080Sq, .p720Sq]
            case .portrait4x5: [.p1080x1350]
            case .portrait9x16: [.p4KVert, .p1080Vert, .p720Vert]
            case .custom: []
            }
        }

        static func from(width: Int, height: Int) -> AspectPreset {
            let aspect = Double(width) / Double(height)
            let tol = Defaults.aspectTolerance
            if abs(aspect - 16.0/9.0) < tol { return .landscape16x9 }
            if abs(aspect - 21.0/9.0) < tol { return .ultrawide }
            if abs(aspect - 1.0) < tol { return .square }
            if abs(aspect - 4.0/5.0) < tol { return .portrait4x5 }
            if abs(aspect - 9.0/16.0) < tol { return .portrait9x16 }
            return .custom
        }
    }

    enum QualityPreset: String, Identifiable {
        // 16:9
        case p4K = "4k-16x9"
        case p1080 = "1080-16x9"
        case p720 = "720-16x9"
        case p480 = "480-16x9"
        // 21:9
        case p1080Ultra = "1080-21x9"
        // 1:1
        case p1080Sq = "1080-1x1"
        case p720Sq = "720-1x1"
        // 4:5
        case p1080x1350 = "1080x1350"
        // 9:16
        case p4KVert = "4k-9x16"
        case p1080Vert = "1080-9x16"
        case p720Vert = "720-9x16"

        var id: String { rawValue }

        var size: (width: Int, height: Int) {
            switch self {
            case .p4K: (3840, 2160)
            case .p1080: (1920, 1080)
            case .p720: (1280, 720)
            case .p480: (854, 480)
            case .p1080Ultra: (2560, 1080)
            case .p1080Sq: (1080, 1080)
            case .p720Sq: (720, 720)
            case .p1080x1350: (1080, 1350)
            case .p4KVert: (2160, 3840)
            case .p1080Vert: (1080, 1920)
            case .p720Vert: (720, 1280)
            }
        }

        var label: String {
            switch self {
            case .p4K, .p4KVert: "4K"
            case .p1080, .p1080Ultra, .p1080Vert: "1080p"
            case .p720, .p720Vert: "720p"
            case .p480: "480p"
            case .p1080Sq: "1080"
            case .p720Sq: "720"
            case .p1080x1350: "1080 x 1350"
            }
        }

        static func from(width: Int, height: Int, aspect: AspectPreset) -> QualityPreset? {
            aspect.qualities.first { $0.size.width == width && $0.size.height == height }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            Text("Project Settings")
                .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)

            // FPS
            settingSection("Frame Rate") {
                HStack(spacing: AppTheme.Spacing.xs) {
                    ForEach(Self.fpsOptions, id: \.self) { fps in
                        chipButton(label: "\(fps)", isSelected: selectedFPS == fps) {
                            selectedFPS = fps
                            applySettings()
                        }
                    }
                }
            }

            // Aspect Ratio
            settingSection("Aspect Ratio") {
                let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
                LazyVGrid(columns: columns, spacing: AppTheme.Spacing.xs) {
                    ForEach(AspectPreset.allCases) { preset in
                        chipButton(label: preset.rawValue, isSelected: selectedAspect == preset) {
                            selectedAspect = preset
                            // Auto-select first quality for this aspect
                            if let first = preset.qualities.first {
                                selectedQuality = first
                                applySettings()
                            }
                        }
                    }
                }
            }

            // Quality / Resolution
            if selectedAspect != .custom {
                let qualities = selectedAspect.qualities
                if qualities.count > 1 {
                    settingSection("Quality") {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            ForEach(qualities) { quality in
                                chipButton(label: quality.label, isSelected: selectedQuality == quality) {
                                    selectedQuality = quality
                                    applySettings()
                                }
                            }
                        }
                    }
                }
            } else {
                settingSection("Size") {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        TextField("Width", text: $customWidth)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                            .frame(width: 70)
                            .onSubmit { applySettings() }

                        Text("x")
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)

                        TextField("Height", text: $customHeight)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                            .frame(width: 70)
                            .onSubmit { applySettings() }
                    }
                }
            }

            // Summary
            Text("\(editor.timeline.width) x \(editor.timeline.height) @ \(editor.timeline.fps) fps")
                .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                .foregroundStyle(AppTheme.Text.mutedColor)
        }
        .padding(AppTheme.Spacing.lg)
        .frame(width: 240)
        .onAppear {
            selectedFPS = editor.timeline.fps
            selectedAspect = AspectPreset.from(width: editor.timeline.width, height: editor.timeline.height)
            selectedQuality = QualityPreset.from(width: editor.timeline.width, height: editor.timeline.height, aspect: selectedAspect)
                ?? selectedAspect.qualities.first ?? .p1080
            customWidth = "\(editor.timeline.width)"
            customHeight = "\(editor.timeline.height)"
        }
    }

    // MARK: - Helpers

    private func settingSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(title)
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            content()
        }
    }

    private func chipButton(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .white : AppTheme.Text.secondaryColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppTheme.Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .fill(isSelected ? Color.accentColor : Color.white.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
    }

    private func applySettings() {
        let width: Int
        let height: Int
        if selectedAspect == .custom {
            guard let w = Int(customWidth), let h = Int(customHeight), w > 0, h > 0 else { return }
            width = w
            height = h
        } else {
            width = selectedQuality.size.width
            height = selectedQuality.size.height
        }
        guard width != editor.timeline.width || height != editor.timeline.height || selectedFPS != editor.timeline.fps else { return }
        editor.applyTimelineSettings(fps: selectedFPS, width: width, height: height)
    }
}
