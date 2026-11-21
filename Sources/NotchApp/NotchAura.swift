#if os(macOS)
import AppKit
import SwiftUI

/// Aura del notch con el notch cerrado, como Lumio: cuando suena una
/// canción, un halo del color de su carátula envuelve el notch aunque el
/// panel esté cerrado (al pausar o cerrar el reproductor, se apaga).
/// Las ventanas son click-through: no roban clics de la barra de menús.
struct NotchAuraView: View {
    @ObservedObject private var music = NotchContext.shared.music

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if music.playing, let tint = music.tint {
                    // Halo elíptico centrado en el notch: se disipa a
                    // transparente en los bordes (sin rectángulos duros).
                    RadialGradient(
                        colors: [tint.opacity(0.65), tint.opacity(0.28), .clear],
                        center: .top,
                        startRadius: 5,
                        endRadius: 66
                    )
                    .scaleEffect(x: 2.5, y: 1, anchor: .top)
                    .blur(radius: 4)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .animation(.easeInOut(duration: 1.1), value: music.tint)
    }
}

/// Una ventana de aura por pantalla con notch, detrás de las luces.
final class NotchAuraController {
    private var panels: [NSPanel] = []

    /// Reconstruye el aura para las pantallas actuales.
    func rebuild(notches: [ScreenNotch]) {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        for entry in notches where entry.layout.hasNotch {
            let n = entry.layout.notchRect
            // Más ancha que el notch y 30 pt por debajo: el halo se
            // derrama a los lados y sobre la barra de menús.
            let frame = NSRect(
                x: n.minX - 130,
                y: n.minY - 30,
                width: n.width + 260,
                height: n.height + 30
            )
            fputs("NOTCH-AURA frame=\(frame) tint=\(String(describing: NotchContext.shared.music.tint))\n", stderr)
            panels.append(makePanel(frame: frame))
        }
        // Detrás de las luces y del panel: se ordenan primero.
        panels.forEach { $0.orderFrontRegardless() }
    }

    private func makePanel(frame: NSRect) -> NSPanel {
        let p = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.hidesOnDeactivate = false
        // Click-through: el halo es solo luz, no intercepta la barra.
        p.ignoresMouseEvents = true
        p.contentView = NSHostingView(rootView: NotchAuraView())
        return p
    }
}
#endif
