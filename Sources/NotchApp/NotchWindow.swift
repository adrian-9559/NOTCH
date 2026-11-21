#if os(macOS)
import AppKit
import SwiftUI

/// NSHostingView que acepta el primer clic sin que la ventana sea key.
/// Sin esto, el primer clic tras abrir el panel (hover) se lo come el
/// sistema para activar la ventana: "clico y no hace nada".
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Panel flotante bajo el notch: sin bordes, siempre visible,
/// en todos los Spaces, sin robar foco (nonactivating).
final class NotchPanel: NSPanel {
    init(content: some View) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 10),
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
        contentView = FirstMouseHostingView(rootView: content)
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

    /// Aparece cayendo desde el notch: el desplazamiento de ventana entera
    /// lo hace el compositor (sin relayout), así no se entrecorta.
    func show(anchorX: CGFloat? = nil, topY: CGFloat? = nil) {
        reposition(anchorX: anchorX, topY: topY)
        let final = panel.frame
        var start = final
        start.origin.y += 14
        panel.setFrame(start, display: false)
        panel.orderFrontRegardless()
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrameOrigin(final.origin)
            panel.animator().alphaValue = 1
        }
        visible = true
    }

    func hide() {
        let up = panel.frame.origin.applying(CGAffineTransform(translationX: 0, y: 10))
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrameOrigin(up)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
        })
        visible = false
    }

    var isVisible: Bool { visible }

    /// Frame actual para la detección de salida del ratón.
    var frame: NSRect { panel.frame }

    /// Ancla el panel al notch: centrado en `anchorX` y colgando de `topY`
    /// (debajo de la barra de menús). Sin ancla, centra en la pantalla.
    func reposition(anchorX: CGFloat? = nil, topY: CGFloat? = nil) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let w: CGFloat = 680
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
