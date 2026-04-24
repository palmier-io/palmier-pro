import AppKit
import SwiftUI

struct FontPickerField: View {
    let current: String
    let onPreview: (String) -> Void
    let onChange: (String) -> Void
    let onCancel: () -> Void

    @State private var anchorHolder = FontMenuAnchorHolder()

    var body: some View {
        Button {
            presentMenu()
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
        .buttonStyle(.plain)
        .fixedSize()
        .background(FontMenuAnchorView(holder: anchorHolder))
    }

    private func presentMenu() {
        guard let anchor = anchorHolder.view else { return }

        let handler = FontMenuHandler(
            onPreview: onPreview,
            onChange: onChange,
            onCancel: onCancel
        )

        let menu = NSMenu()
        menu.delegate = handler
        menu.autoenablesItems = false

        if !BundledFonts.families.isEmpty {
            let header = NSMenuItem(title: "Featured", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for family in BundledFonts.families {
                menu.addItem(makeItem(name: family, previewFamily: family, handler: handler))
            }
            menu.addItem(.separator())
            let all = NSMenuItem(title: "All fonts", action: nil, keyEquivalent: "")
            all.isEnabled = false
            menu.addItem(all)
        }

        for entry in BundledFonts.systemFamiliesForPicker {
            menu.addItem(
                makeItem(
                    name: entry.name,
                    previewFamily: entry.previewable ? entry.name : nil,
                    handler: handler
                )
            )
        }

        let origin = NSPoint(x: 0, y: anchor.bounds.height + 2)
        menu.popUp(positioning: nil, at: origin, in: anchor)
    }

    private func makeItem(name: String, previewFamily: String?, handler: FontMenuHandler) -> NSMenuItem {
        let item = NSMenuItem(
            title: name,
            action: #selector(FontMenuHandler.pick(_:)),
            keyEquivalent: ""
        )
        item.target = handler
        item.representedObject = name
        if name == current {
            item.state = .on
        }
        if let family = previewFamily, let font = NSFont(name: family, size: 13) {
            item.attributedTitle = NSAttributedString(string: name, attributes: [.font: font])
        }
        return item
    }

    private var displayName: String {
        NSFont(name: current, size: 12)?.familyName ?? current
    }
}

@MainActor
private final class FontMenuHandler: NSObject, NSMenuDelegate {
    let onPreview: (String) -> Void
    let onChange: (String) -> Void
    let onCancel: () -> Void
    private var didPick = false
    private var lastPreviewed: String?

    init(
        onPreview: @escaping (String) -> Void,
        onChange: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onPreview = onPreview
        self.onChange = onChange
        self.onCancel = onCancel
    }

    @objc func pick(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        didPick = true
        onChange(name)
    }

    nonisolated func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        nonisolated(unsafe) let unsafeItem = item
        MainActor.assumeIsolated {
            guard let name = unsafeItem?.representedObject as? String,
                  name != lastPreviewed else { return }
            lastPreviewed = name
            onPreview(name)
        }
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            if !didPick { onCancel() }
        }
    }
}

@MainActor
private final class FontMenuAnchorHolder {
    weak var view: NSView?
}

private struct FontMenuAnchorView: NSViewRepresentable {
    let holder: FontMenuAnchorHolder

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        holder.view = v
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        holder.view = nsView
    }
}
