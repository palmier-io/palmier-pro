import AppKit
import SwiftUI

struct ExternalAgentLogo: View {
    let agent: SkillExternalAgent
    var size: CGFloat = AppTheme.IconSize.sm

    var body: some View {
        Group {
            if let image = ExternalAgentAssets.image(for: agent) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app")
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs, style: .continuous))
        .accessibilityHidden(true)
    }
}

private enum ExternalAgentAssets {
    static func image(for agent: SkillExternalAgent) -> NSImage? {
        switch agent {
        case .claude: claude
        case .codex: codex
        case .cursor: cursor
        }
    }

    private static let claude = load("claude")
    private static let codex = load("codex")
    private static let cursor = load("cursor")

    private static func load(_ name: String) -> NSImage? {
        BundledResource.url("Images/Agents/\(name).png").flatMap(NSImage.init(contentsOf:))
    }
}
