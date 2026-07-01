import SwiftUI

struct MatteSheet: View {
    @Environment(EditorViewModel.self) private var editor
    @Binding var isPresented: Bool
    @State private var color = Color.black
    @State private var aspect = MatteAspect.project
    @State private var isCreating = false
    @State private var error: String?

    private var dims: (width: Int, height: Int) {
        aspect.pixelSize(timelineWidth: editor.timeline.width, timelineHeight: editor.timeline.height)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            row(icon: "paintpalette", label: "Color") {
                ColorField(displayColor: color, onUserChange: { color = $0 }, supportsOpacity: false)
            }
            row(icon: "aspectratio", label: "Aspect") {
                Picker("", selection: $aspect) {
                    ForEach(MatteAspect.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
            }
            row(icon: "ruler", label: "Size") {
                Text("\(dims.width) × \(dims.height)")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .monospacedDigit()
            }
            if let error {
                Text(error)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.errorColor)
            }
            Button(action: create) {
                Text(isCreating ? "Creating…" : "Create Matte")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Background.baseColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppTheme.Spacing.smMd)
                    .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(AppTheme.Accent.primary))
            }
            .buttonStyle(.plain)
            .disabled(isCreating)
            .padding(.top, AppTheme.Spacing.xs)
        }
        .padding(AppTheme.Spacing.lgXl)
        .frame(width: AppTheme.Matte.sheetWidth)
    }

    private func row<Control: View>(icon: String, label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: AppTheme.Spacing.smMd) {
            Image(systemName: icon)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.IconSize.sm)
            Text(label)
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Spacer(minLength: AppTheme.Spacing.md)
            control()
                .frame(width: AppTheme.Matte.controlWidth, alignment: .trailing)
        }
    }

    private func create() {
        error = nil
        isCreating = true
        Task {
            defer { isCreating = false }
            do {
                _ = try await editor.createMatte(hex: color.matteHex, aspect: aspect, folderId: editor.mediaPanelCurrentFolderId)
                isPresented = false
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
