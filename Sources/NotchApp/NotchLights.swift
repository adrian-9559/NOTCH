#if os(macOS)
import AppKit
import Combine
import NotchCore
import SwiftUI

/// Píldoras negras pegadas al notch físico (como Lumio): con música,
/// carátula a la izquierda y onda a la derecha ("cover on the left,
/// a wave on the right"). Sin música no hay nada (ni puntos).
/// Clic abre el panel. Se reconstruyen al cambiar las pantallas.
struct NotchLightsView: View {
    @ObservedObject private var music = NotchContext.shared.music
    var alignRight: Bool
    var onTap: () -> Void = {}

    /// Firma para animar la aparición de carátula y onda.
    private var musicSig: String { "\(music.title)|\(music.playing)|\(music.artwork != nil)|\(music.playerLive)" }

    /// Hay algo que mostrar: canción conocida y reproductor abierto.
    private var hasMusic: Bool { !music.title.isEmpty && music.artwork != nil && music.playerLive }

    var body: some View {
        HStack(spacing: 0) {
            if alignRight { Spacer(minLength: 0) }
            HStack(spacing: 8) {
                if alignRight {
                    coverView
                } else {
                    waveView
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(
                Capsule()
                    .fill(Color.black)
                    .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
                    .shadow(radius: 4)
            )
            if !alignRight { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .animation(.easeInOut(duration: 0.4), value: musicSig)
    }

    /// Carátula en pequeño pegada al notch (lado izquierdo).
    @ViewBuilder
    private var coverView: some View {
        if hasMusic, let art = music.artwork {
            Image(nsImage: art)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
    }

    /// Onda con los 2 colores de la canción pegada al notch (lado derecho).
    @ViewBuilder
    private var waveView: some View {
        if hasMusic {
            if music.playing {
                SongEQ(
                    c1: music.tint ?? .white,
                    c2: music.tint2 ?? music.tint ?? .gray,
                    barWidth: 3,
                    maxHeight: 15
                )
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            } else {
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .transition(.opacity)
            }
        }
    }
}

final class NotchLightsController {
    private var panels: [NSPanel] = []
    private var cancellables = Set<AnyCancellable>()

    /// Reconstruye las píldoras para las pantallas actuales. Solo se
    /// muestran con música (carátula disponible); sin música, nada.
    func rebuild(notches: [ScreenNotch], onTap: @escaping () -> Void) {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        for entry in notches where entry.layout.hasNotch {
            let n = entry.layout.notchRect
            // Píldora a juego con el notch (casi su altura): se lee como
            // una extensión suya a cada lado.
            let h: CGFloat = 30
            let y = n.minY + (n.height - h) / 2
            let left = NSRect(x: n.minX - 200, y: y, width: 200, height: h)
            let right = NSRect(x: n.maxX, y: y, width: 200, height: h)
            fputs("NOTCH-LIGHTS notch=\(n) left=\(left) right=\(right)\n", stderr)
            panels.append(makePanel(frame: left, alignRight: true, onTap: onTap))
            panels.append(makePanel(frame: right, alignRight: false, onTap: onTap))
        }
        cancellables.removeAll()
        // Sin música no hay píldora: se ordenan fuera.
        let m0 = NotchContext.shared.music
        m0.$title
            .combineLatest(m0.$artwork, m0.$playerLive)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] title, art, live in
                guard let self else { return }
                if !title.isEmpty, art != nil, live {
                    self.panels.forEach { $0.orderFrontRegardless() }
                } else {
                    self.panels.forEach { $0.orderOut(nil) }
                }
            }
            .store(in: &cancellables)
        // Estado inicial.
        let m = NotchContext.shared.music
        if !m.title.isEmpty, m.artwork != nil, m.playerLive {
            panels.forEach { $0.orderFrontRegardless() }
        }
    }

    func hide() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
    }

    private func makePanel(frame: NSRect, alignRight: Bool, onTap: @escaping () -> Void) -> NSPanel {
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
        p.ignoresMouseEvents = false
        p.contentView = FirstMouseHostingView(rootView: NotchLightsView(alignRight: alignRight, onTap: onTap))
        return p
    }
}
#endif
