#if os(macOS)
import AppKit
import SwiftUI

/// Panel flotante bajo el notch: sin bordes, siempre visible,
/// en todos los Spaces, sin robar foco (nonactivating).
final class NotchPanel: NSPanel {
    init(content: some View) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        contentView = NSHostingView(rootView: content)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Posiciona el panel centrado bajo el notch (o centro superior si no hay).
/// Lupa: también dibuja un notch virtual cuando el Mac no tiene.
final class NotchWindowController {
    private let panel: NotchPanel
    private var visible = false

    init<Content: View>(content: Content) {
        panel = NotchPanel(content: content)
    }

    func toggle(anchorX: CGFloat? = nil, topY: CGFloat? = nil) { visible ? hide() : show(anchorX: anchorX, topY: topY) }

    func show(anchorX: CGFloat? = nil, topY: CGFloat? = nil) {
        reposition(anchorX: anchorX, topY: topY)
        panel.orderFrontRegardless()
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        visible = true
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
        })
        visible = false
    }

    var isVisible: Bool { visible }

    /// Ancla el panel al notch: centrado en `anchorX` y colgando de `topY`
    /// (debajo de la barra de menús). Sin ancla, centra en la pantalla.
    func reposition(anchorX: CGFloat? = nil, topY: CGFloat? = nil) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let w: CGFloat = 520
        let x = (anchorX ?? frame.midX) - w / 2
        // Debajo del notch: unos 8pt desde arriba del área visible.
        let y = (topY ?? frame.maxY - 8) - panel.frame.height
        var f = panel.frame
        f.origin = NSPoint(x: x, y: y)
        f.size.width = w
        panel.setFrame(f, display: true)
    }
}
#endif
