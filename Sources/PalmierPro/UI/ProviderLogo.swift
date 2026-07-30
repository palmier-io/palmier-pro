import AppKit
import SwiftUI

struct ProviderLogo: View {
    let iconKey: String
    var size: CGFloat = AppTheme.IconSize.sm

    private static let images: [String: NSImage] = {
        guard let directory = BundledResource.url("Images/LabLogos"),
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: nil
              ) else { return [:] }

        return Dictionary(uniqueKeysWithValues: urls.compactMap { url in
            let filename = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "png",
                  filename.hasPrefix("logo-"),
                  let image = NSImage(contentsOf: url) else { return nil }
            image.size = NSSize(width: AppTheme.IconSize.xs, height: AppTheme.IconSize.xs)
            return (String(filename.dropFirst("logo-".count)), image)
        })
    }()

    static func hasBundledLogo(for iconKey: String) -> Bool {
        images[iconKey] != nil
    }

    var body: some View {
        Group {
            if let image = Self.images[iconKey] {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "sparkles")
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs, style: .continuous))
        .accessibilityHidden(true)
    }
}
