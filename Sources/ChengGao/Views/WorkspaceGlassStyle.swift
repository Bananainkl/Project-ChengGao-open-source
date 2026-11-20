import AppKit
import SwiftUI

private struct WorkspaceGlassInsetModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color
    let tintOpacity: Double

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(Color(nsColor: .textBackgroundColor), in: shape)
            .overlay {
                shape
                    .fill(tint.opacity(tintOpacity))
                    .allowsHitTesting(false)
            }
            .overlay {
                shape
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
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

private struct WorkspaceEditorSurface: ViewModifier {
    var focused: Bool
    @Environment(\.accessibilityShowBorders) private var showBorders
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        content
            .background(Color(nsColor: .textBackgroundColor), in: shape)
            .overlay {
                shape.strokeBorder(focused ? Color.accentColor : Color(nsColor: .separatorColor),
                                   lineWidth: focused || showBorders || contrast == .increased ? 2 : 1)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func workspaceEditorSurface(focused: Bool) -> some View {
        modifier(WorkspaceEditorSurface(focused: focused))
    }
}
