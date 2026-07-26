import AppKit
import SwiftUI

/// Swatch that drives the shared `NSColorPanel`. SwiftUI's `ColorPicker`
/// binding only fires on mouse-up; `colorDidChangeNotification` fires during drag.
struct ColorField: View {
    let displayColor: Color
    let onUserChange: (Color) -> Void
    var supportsOpacity: Bool = true
    var accessibilityLabel: String = "Choose color"

    var body: some View {
        Button(action: open) {
            RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                .fill(displayColor)
                .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.xs)
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                        .stroke(Color.white.opacity(AppTheme.Opacity.medium), lineWidth: AppTheme.BorderWidth.thin)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func open() {
        ColorPanelBridge.shared.activate(
            initial: displayColor,
            supportsOpacity: supportsOpacity,
            onChange: onUserChange
        )
    }
}

/// Relays `NSColorPanel` changes to the last-clicked `ColorField`.
@MainActor
private final class ColorPanelBridge {
    static let shared = ColorPanelBridge()

    private var onChange: ((Color) -> Void)?
    private var suppressNext = false

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSColorPanel.colorDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let ns = NSColorPanel.shared.color.usingColorSpace(.sRGB) else { return }
                self?.relay(
                    r: Double(ns.redComponent), g: Double(ns.greenComponent),
                    b: Double(ns.blueComponent), a: Double(ns.alphaComponent))
            }
        }
    }

    func activate(initial: Color, supportsOpacity: Bool, onChange: @escaping (Color) -> Void) {
        self.onChange = onChange
        let panel = NSColorPanel.shared
        panel.showsAlpha = supportsOpacity
        let ns = NSColor(initial).usingColorSpace(.sRGB) ?? .black
        // Setting panel.color fires a notification — ignore it to avoid a round-trip into the model.
        suppressNext = true
        panel.color = ns
        panel.makeKeyAndOrderFront(nil)
    }

    private func relay(r: Double, g: Double, b: Double, a: Double) {
        if suppressNext {
            suppressNext = false
            return
        }
        onChange?(Color(.sRGB, red: r, green: g, blue: b, opacity: a))
    }
}
