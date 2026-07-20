import AppKit
import SwiftUI

/// SwiftUI owns all visible material. This bridge only removes AppKit's opaque
/// window backing so the system material can sample the desktop underneath.
struct WindowGlassConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        GlassWindowProbeView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? GlassWindowProbeView)?.configureWindow()
    }
}

private final class GlassWindowProbeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindow()
    }

    func configureWindow() {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.hasShadow = true
    }
}
