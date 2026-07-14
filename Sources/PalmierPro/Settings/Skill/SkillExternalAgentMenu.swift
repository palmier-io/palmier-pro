import SwiftUI

struct SkillExternalAgentMenu: View {
    let skill: Skill
    let store: SkillStore
    let onCopied: (SkillExternalAgent, URL) -> Void
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text("Add to External Agent")
                Image(systemName: "chevron.down")
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
            }
        }
        .buttonStyle(.capsule(.secondary, fill: AnyShapeStyle(AppTheme.Background.raisedColor)))
        .help("Add this skill to an external agent")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
                ForEach(SkillExternalAgent.allCases, id: \.self) { agent in
                    Button {
                        if let url = store.copy(skill, to: agent) {
                            onCopied(agent, url)
                        }
                        isPresented = false
                    } label: {
                        HStack(spacing: AppTheme.Spacing.smMd) {
                            ExternalAgentLogo(agent: agent)
                            Text("Add to \(agent.label)")
                                .font(.system(size: AppTheme.FontSize.sm))
                                .foregroundStyle(AppTheme.Text.primaryColor)
                            Spacer(minLength: AppTheme.Spacing.sm)
                        }
                        .padding(.horizontal, AppTheme.Spacing.md)
                        .padding(.vertical, AppTheme.Spacing.sm)
                        .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, AppTheme.Spacing.xs)
            .frame(minWidth: AppTheme.Settings.skillMenuWidth)
        }
    }
}
