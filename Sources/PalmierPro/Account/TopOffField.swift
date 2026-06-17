import SwiftUI

struct TopOffField<Trailing: View>: View {
    @Binding var dollars: Int
    var controlSize: ControlSize = .regular
    var fillWidth: Bool = true
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
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
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
                    Text(buttonLabel)
                        .frame(maxWidth: fillWidth ? .infinity : nil)
                }
                .buttonStyle(.capsule(.secondary, size: capsuleSize))
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
        onBuy: @escaping () -> Void
    ) {
        self.init(
            dollars: dollars,
            controlSize: controlSize,
            fillWidth: fillWidth,
            onBuy: onBuy,
            trailing: { EmptyView() }
        )
    }
}
