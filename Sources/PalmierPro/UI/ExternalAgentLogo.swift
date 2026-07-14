import AppKit
import SwiftUI

struct ExternalAgentLogo: View {
    let agent: SkillExternalAgent
    var size: CGFloat = AppTheme.IconSize.sm

    private static let images: [SkillExternalAgent: NSImage] = Dictionary(
        uniqueKeysWithValues: SkillExternalAgent.allCases.compactMap { agent in
            guard let url = BundledResource.url("Images/Agents/\(agent.rawValue).png"),
                  let image = NSImage(contentsOf: url) else { return nil }
            return (agent, image)
        }
    )

    var body: some View {
        Group {
            if let image = Self.images[agent] {
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
