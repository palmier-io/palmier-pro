import AppKit
import SwiftUI

struct FontPickerField: View {
    let current: String
    let onChange: (String) -> Void

    var body: some View {
        Menu {
            if !BundledFonts.families.isEmpty {
                Section("Featured") {
                    ForEach(BundledFonts.families, id: \.self) { family in
                        Button { onChange(family) } label: {
                            Text(family).font(.custom(family, size: 14))
                        }
                    }
                }
                Section("All fonts") { systemList }
            } else {
                systemList
            }
        } label: {
            HStack(spacing: 4) {
                Text(displayName)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: 160, alignment: .trailing)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(Color.white.opacity(0.06))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private var systemList: some View {
        ForEach(BundledFonts.systemFamiliesForPicker, id: \.name) { entry in
            Button { onChange(entry.name) } label: {
                if entry.previewable {
                    Text(entry.name).font(.custom(entry.name, size: 14))
                } else {
                    Text(entry.name)
                }
            }
        }
    }

    /// Show family name ("Helvetica") instead of stored PostScript name ("Helvetica-Bold").
    private var displayName: String {
        NSFont(name: current, size: 12)?.familyName ?? current
    }
}
