import SwiftUI

struct EditorPanelGroup<Content: View, HeaderAccessory: View>: View {
    let title: String
    private let isExpanded: Binding<Bool>?
    private let contentSpacing: CGFloat
    private let contentInsets: EdgeInsets
    private let onReset: (() -> Void)?
    @ViewBuilder private let headerAccessory: () -> HeaderAccessory
    @ViewBuilder private let content: () -> Content
    @State private var localIsExpanded = true

    init(
        _ title: String,
        isExpanded: Binding<Bool>? = nil,
        contentSpacing: CGFloat = AppTheme.Spacing.smMd,
        contentInsets: EdgeInsets = EdgeInsets(
            top: AppTheme.Spacing.smMd,
            leading: AppTheme.Spacing.smMd,
            bottom: AppTheme.Spacing.smMd,
            trailing: AppTheme.Spacing.smMd
        ),
        onReset: (() -> Void)? = nil,
        @ViewBuilder headerAccessory: @escaping () -> HeaderAccessory,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.isExpanded = isExpanded
        self.contentSpacing = contentSpacing
        self.contentInsets = contentInsets
        self.onReset = onReset
        self.headerAccessory = headerAccessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
            header
            if expanded {
                VStack(alignment: .leading, spacing: contentSpacing) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(contentInsets)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Background.surfaceColor)
        .overlay(alignment: .bottom) { divider }
    }

    private var header: some View {
        ZStack {
            Button(action: toggleExpansion) {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityLabel(Text(verbatim: "\(expanded ? L10n.string("Collapse") : L10n.string("Expand")) \(title)"))

            HStack(spacing: AppTheme.Spacing.sm) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .frame(width: AppTheme.IconSize.xs, height: AppTheme.IconSize.xs)
                    titleLabel
                }
                .allowsHitTesting(false)

                Spacer(minLength: AppTheme.Spacing.sm)

                headerAccessory()

                if let onReset {
                    EditorResetButton(title: title, action: onReset)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.smMd)
        }
        .frame(maxWidth: .infinity, minHeight: AppTheme.EditorPanel.groupHeaderHeight)
        .background(AppTheme.Background.surfaceColor)
        .contentShape(Rectangle())
    }

    private var titleLabel: some View {
        Text(L10n.string(key: title))
            .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(AppTheme.Text.primaryColor)
            .lineLimit(1)
    }

    private var expanded: Bool {
        isExpanded?.wrappedValue ?? localIsExpanded
    }

    private func toggleExpansion() {
        withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) {
            if let isExpanded {
                isExpanded.wrappedValue.toggle()
            } else {
                localIsExpanded.toggle()
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(AppTheme.Border.primaryColor)
            .frame(height: AppTheme.BorderWidth.thin)
    }
}

extension EditorPanelGroup where HeaderAccessory == EmptyView {
    init(
        _ title: String,
        isExpanded: Binding<Bool>? = nil,
        contentSpacing: CGFloat = AppTheme.Spacing.smMd,
        contentInsets: EdgeInsets = EdgeInsets(
            top: AppTheme.Spacing.smMd,
            leading: AppTheme.Spacing.smMd,
            bottom: AppTheme.Spacing.smMd,
            trailing: AppTheme.Spacing.smMd
        ),
        onReset: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            title,
            isExpanded: isExpanded,
            contentSpacing: contentSpacing,
            contentInsets: contentInsets,
            onReset: onReset,
            headerAccessory: { EmptyView() },
            content: content
        )
    }
}
