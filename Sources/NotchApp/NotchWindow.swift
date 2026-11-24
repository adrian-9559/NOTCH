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

    /// El panel no roba foco al abrirse por hover, pero un clic explícito
    /// SÍ activa la app (ver mouseDown en la vista no vale: los controles
    /// consumen el clic antes). Sin esto no se puede escribir en los campos.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        super.sendEvent(event)
    }
}

/// Posiciona el panel centrado bajo el notch (o centro superior si no hay).
/// Lupa: también dibuja un notch virtual cuando el Mac no tiene.
final class NotchWindowController {
    private let panel: NotchPanel
    private var visible = false
    /// Testigo de la animación de cierre en curso (ver `hide()`).
    private var hideToken = 0

    init<Content: View>(content: Content) {
        panel = NotchPanel(content: content)
    }

    func toggle(anchorX: CGFloat? = nil, topY: CGFloat? = nil) { visible ? hide() : show(anchorX: anchorX, topY: topY) }

    /// Aparece deslizándose desde el notch con una curva suave de
    /// deceleración larga (sin el golpe del easeOut corto): caída de
    ///10 pt + fundido en0,42 s.
    func show(anchorX: CGFloat? = nil, topY: CGFloat? = nil) {
        reposition(anchorX: anchorX, topY: topY)
        let final = panel.frame
        var start = final
        start.origin.y += 10
        panel.setFrame(start, display: false)
        panel.orderFrontRegardless()
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.42
            // easeOutQuint: arranca rápido y aterriza muy suave.
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().setFrameOrigin(final.origin)
            panel.animator().alphaValue = 1
        }
        visible = true
    }

    /// Se retira con fundido y una micro-subida (0,22 s, ease-in suave).
    func hide() {
        let up = panel.frame.origin.applying(CGAffineTransform(translationX: 0, y: 8))
        // Marca la orden de ocultar: si mientras corre la animación se
        // vuelve a mostrar (clic + hover), el cierre viejo NO debe
        // ordenar fuera el panel recién abierto (lo dejaría "visible"
        // pero invisible y el hover ya no lo reabría).
        hideToken += 1
        let token = hideToken
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
            panel.animator().setFrameOrigin(up)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.hideToken == token, !self.visible else { return }
            self.panel.orderOut(nil)
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
