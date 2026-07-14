import SwiftUI

struct TopOffField<Trailing: View>: View {
    @Binding var dollars: Int
    var controlSize: ControlSize = .regular
    var fillWidth: Bool = true
    var fieldFill: Color = AppTheme.Background.surfaceColor
    var buttonFill: AnyShapeStyle? = nil
    var showsExternalLinkIcon: Bool = false
    var onBuy: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    @Bindable private var account = AccountService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text("$")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                TextField("", value: $dollars, format: .number)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, AppTheme.Spacing.smMd)
                    .padding(.vertical, AppTheme.Spacing.xs)
                    .frame(width: AppTheme.Settings.creditInputWidth)
                    .themedSurface(fieldFill, cornerRadius: AppTheme.Radius.sm)
                    .disabled(account.isBuyingCredits)
                Text(credits == 1 ? "= 1 credit" : "= \(credits.formatted()) credits")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .monospacedDigit()
                    .foregroundStyle(
                        isValid
                            ? AppTheme.Text.secondaryColor
                            : AppTheme.Text.tertiaryColor
                    )
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            HStack(spacing: AppTheme.Spacing.sm) {
                Button(action: onBuy) {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        Text(buttonLabel)
                        if showsExternalLinkIcon {
                            Image(systemName: "arrow.up.right")
                                .font(.system(
                                    size: AppTheme.FontSize.xs,
                                    weight: AppTheme.FontWeight.semibold
                                ))
                                .accessibilityHidden(true)
                        }
                    }
                        .frame(maxWidth: fillWidth ? .infinity : nil)
                }
                .buttonStyle(.capsule(.secondary, size: capsuleSize, fill: buttonFill))
                .disabled(account.isBuyingCredits || !isValid)

                trailing()
            }
        }
    }

    private var capsuleSize: CapsuleButtonStyle.Size {
        (controlSize == .small || controlSize == .mini) ? .small : .regular
    }

    private var credits: Int { max(0, dollars) * 100 }

    private var isValid: Bool {
        (TopOffLimits.minDollars...TopOffLimits.maxDollars).contains(dollars)
    }

    private var buttonLabel: String {
        isValid ? "Buy $\(dollars)" : "Buy"
    }
}

extension TopOffField where Trailing == EmptyView {
    init(
        dollars: Binding<Int>,
        controlSize: ControlSize = .regular,
        fillWidth: Bool = true,
        fieldFill: Color = AppTheme.Background.surfaceColor,
        buttonFill: AnyShapeStyle? = nil,
        showsExternalLinkIcon: Bool = false,
        onBuy: @escaping () -> Void
    ) {
        self.init(
            dollars: dollars,
            controlSize: controlSize,
            fillWidth: fillWidth,
            fieldFill: fieldFill,
            buttonFill: buttonFill,
            showsExternalLinkIcon: showsExternalLinkIcon,
            onBuy: onBuy,
            trailing: { EmptyView() }
        )
    }
}
