import SwiftUI

/// The features page. Reads `FeatureCatalog` and nothing else, so the copy has one owner.
struct FeaturesPane: View {
    private var categories: [FeatureCatalog.Category] { FeatureCatalog.categories }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xlXxl) {
                intro
                ForEach(categories) { category in
                    section(category)
                }
                footer
            }
            .frame(maxWidth: AppTheme.Settings.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, AppTheme.Spacing.xlXxl)
            .padding(.bottom, AppTheme.Spacing.xxl)
        }
    }

    private var intro: some View {
        Text(
            L10n.string(
                """
                What the editor can do, and when to reach for it. Ask the agent for any of these \
                in plain language — it applies them to the timeline as a single undoable step.
                """
            )
        )
        .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.regular))
        .foregroundStyle(AppTheme.Text.secondaryColor)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func section(_ category: FeatureCatalog.Category) -> some View {
        SettingsSection(title: L10n.string(key: category.title)) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lgXl) {
                ForEach(category.features) { feature in
                    row(feature)
                }
            }
        }
    }

    private func row(_ feature: FeatureCatalog.Feature) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.regular))
                    .foregroundStyle(AppTheme.Accent.primary)
                Text(L10n.string(key: feature.title))
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
            }
            Text(L10n.string(key: feature.summary))
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.regular))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
            howTo(feature)
        }
    }

    /// A concrete request, set apart from the description. This app is driven by asking for
    /// things, so showing the shape of a good request is more useful than more prose.
    private func howTo(_ feature: FeatureCatalog.Feature) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
            Text(L10n.string("Ask the agent"))
                .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Text(L10n.string(key: feature.howTo))
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.regular))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, AppTheme.Spacing.xxs)
        .padding(.leading, AppTheme.Spacing.xl)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Text(
                L10n.string(
                    "Keyboard shortcuts are on the Shortcuts tab. The Skills tab holds playbooks for the work you do often."
                )
            )
            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.regular))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    FeaturesPane()
        .frame(width: 820, height: 600)
        .background(AppTheme.Background.baseColor)
}