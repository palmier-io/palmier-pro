import AppKit
import SwiftUI

/// Swatch that drives the shared `NSColorPanel`. SwiftUI's `ColorPicker`
/// binding only fires on mouse-up; `colorDidChangeNotification` fires during drag.
struct ColorField: View {
    let displayColor: Color
    let onUserChange: (Color) -> Void
    var supportsOpacity: Bool = true

    var body: some View {
        Button(action: open) {
            RoundedRectangle(cornerRadius: 3)
                .fill(displayColor)
                .frame(width: 24, height: 14)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.white.opacity(0.3), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
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
        ) { [weak self] note in
            // Extract primitives here so no non-Sendable crosses into MainActor.
            guard let ns = (note.object as? NSColorPanel)?.color.usingColorSpace(.sRGB) else { return }
            let r = Double(ns.redComponent)
            let g = Double(ns.greenComponent)
            let b = Double(ns.blueComponent)
            let a = Double(ns.alphaComponent)
            MainActor.assumeIsolated {
                self?.relay(r: r, g: g, b: b, a: a)
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
