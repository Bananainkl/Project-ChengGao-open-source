import AppKit
import SwiftUI

/// Shared visual treatment for the workspace. The ambient color lives behind
/// the system material so panels still behave like native macOS glass instead
/// of opaque, hand-painted cards.
struct WorkspaceAmbientBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            Color(nsColor: .windowBackgroundColor)
        } else {
            ZStack {
                RadialGradient(
                    colors: [
                        Color.accentColor.opacity(colorScheme == .dark ? 0.16 : 0.09),
                        .clear
                    ],
                    center: .topTrailing,
                    startRadius: 24,
                    endRadius: 620
                )
                RadialGradient(
                    colors: [
                        Color.cyan.opacity(colorScheme == .dark ? 0.10 : 0.055),
                        .clear
                    ],
                    center: .bottomLeading,
                    startRadius: 20,
                    endRadius: 540
                )
                Rectangle().fill(.ultraThinMaterial)
            }
        }
    }
}

private struct WorkspaceGlassPanelModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat
    let elevated: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            .overlay {
                shape
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.22 : 0.72),
                                Color.white.opacity(colorScheme == .dark ? 0.035 : 0.10),
                                Color.black.opacity(colorScheme == .dark ? 0.16 : 0.045)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
                    .allowsHitTesting(false)
            }
            .shadow(
                color: Color.black.opacity(
                    elevated
                        ? (colorScheme == .dark ? 0.22 : 0.085)
                        : (colorScheme == .dark ? 0.14 : 0.05)
                ),
                radius: elevated ? 18 : 10,
                x: 0,
                y: elevated ? 8 : 4
            )
    }
}

private struct WorkspaceGlassInsetModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat
    let tint: Color
    let tintOpacity: Double

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(.thinMaterial, in: .rect(cornerRadius: cornerRadius))
            .overlay {
                shape
                    .fill(tint.opacity(tintOpacity))
                    .allowsHitTesting(false)
            }
            .overlay {
                shape
                    .strokeBorder(
                        Color.white.opacity(colorScheme == .dark ? 0.10 : 0.42),
                        lineWidth: 0.65
                    )
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func workspaceGlassPanel(
        cornerRadius: CGFloat = 20,
        elevated: Bool = false
    ) -> some View {
        modifier(
            WorkspaceGlassPanelModifier(
                cornerRadius: cornerRadius,
                elevated: elevated
            )
        )
    }

    func workspaceGlassInset(
        cornerRadius: CGFloat,
        tint: Color = .clear,
        tintOpacity: Double = 0
    ) -> some View {
        modifier(
            WorkspaceGlassInsetModifier(
                cornerRadius: cornerRadius,
                tint: tint,
                tintOpacity: tintOpacity
            )
        )
    }
}
