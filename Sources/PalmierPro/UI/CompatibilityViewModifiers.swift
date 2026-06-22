import SwiftUI

enum PalmierGlassEffectStyle {
    case clear
    case regular
}

struct PalmierGlassEffectContainer<Content: View>: View {
    private let spacing: CGFloat?
    private let content: Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            if let spacing {
                GlassEffectContainer(spacing: spacing) {
                    content
                }
            } else {
                GlassEffectContainer {
                    content
                }
            }
        } else {
            content
        }
    }
}

extension View {
    @ViewBuilder
    func palmierGlassEffect<S: Shape>(
        _ style: PalmierGlassEffectStyle,
        in shape: S
    ) -> some View {
        if #available(macOS 26.0, *) {
            switch style {
            case .clear:
                self.glassEffect(.clear, in: shape)
            case .regular:
                self.glassEffect(.regular, in: shape)
            }
        } else {
            self
                .background(shape.fill(fallbackGlassFill(for: style)))
                .overlay(shape.stroke(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline))
        }
    }

    @ViewBuilder
    func palmierGlassButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.plain)
        }
    }

    @ViewBuilder
    func palmierGlassProminentButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.plain)
        }
    }

    @ViewBuilder
    func palmierGlassEffectID<ID: Hashable & Sendable>(_ id: ID, in namespace: Namespace.ID) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffectID(id, in: namespace)
        } else {
            self
        }
    }

    @ViewBuilder
    func palmierTopScrollEdgeEffect() -> some View {
        if #available(macOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }

    @ViewBuilder
    func palmierBottomScrollTracking(isScrolledFromBottom: Binding<Bool>) -> some View {
        if #available(macOS 26.0, *) {
            self
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .onScrollGeometryChange(for: Bool.self) { geo in
                    let distance = geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
                    return distance > 80
                } action: { _, newValue in
                    withAnimation(.easeOut(duration: 0.15)) {
                        isScrolledFromBottom.wrappedValue = newValue
                    }
                }
        } else {
            self.onAppear {
                isScrolledFromBottom.wrappedValue = false
            }
        }
    }

    private func fallbackGlassFill(for style: PalmierGlassEffectStyle) -> Color {
        switch style {
        case .clear:
            Color.white.opacity(AppTheme.Opacity.subtle)
        case .regular:
            Color.white.opacity(AppTheme.Opacity.faint)
        }
    }
}
