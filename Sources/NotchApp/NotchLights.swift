#if os(macOS)
import AppKit
import NotchCore
import SwiftUI

/// Luces pegadas al notch físico (a izquierda y derecha), como Lumio.
/// Ventanas 200x18 a nivel screenSaver sobre la barra de menús;
/// clic abre el panel. Se reconstruyen al cambiar las pantallas.
/// Con música: carátula a la izquierda del notch y onda a la derecha
/// ("cover on the left, a wave on the right").
struct NotchLightsView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject private var music = NotchContext.shared.music
    var alignRight: Bool
    var onTap: () -> Void = {}

    private var dots: [AgentSession] {
        Array(store.sessions.filter { $0.status == .working || $0.status == .waiting }.prefix(8))
    }

    /// Firma para animar la aparición de carátula y onda.
    private var musicSig: String { "\(music.title)|\(music.playing)|\(music.artwork != nil)" }

    var body: some View {
        HStack(spacing: 4) {
            if alignRight { Spacer(minLength: 0) }
            if alignRight {
                dotsView
                coverView
            } else {
                waveView
                dotsView
            }
            if !alignRight { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .animation(.easeInOut(duration: 0.4), value: musicSig)
    }

    @ViewBuilder
    private var dotsView: some View {
        if dots.isEmpty {
            Circle().fill(Color.gray.opacity(0.25)).frame(width: 7, height: 7)
        } else {
            ForEach(dots, id: \.agent) { s in
                Circle()
                    .fill(Color(hex: s.agent.notchColorHex))
                    .frame(width: 9, height: 9)
                    .overlay {
                        if s.status == .waiting {
                            Circle().stroke(.yellow, lineWidth: 1.5)
                        }
                    }
            }
        }
    }

    /// Carátula en pequeño pegada al notch (lado izquierdo).
    @ViewBuilder
    private var coverView: some View {
        if let art = music.artwork, !music.title.isEmpty {
            Image(nsImage: art)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 15, height: 15)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
    }

    /// Onda con los 2 colores de la canción pegada al notch (lado derecho).
    @ViewBuilder
    private var waveView: some View {
        if !music.title.isEmpty, music.artwork != nil {
            if music.playing {
                SongEQ(
                    c1: music.tint ?? .white,
                    c2: music.tint2 ?? music.tint ?? .gray,
                    barWidth: 2.5,
                    maxHeight: 13
                )
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            } else {
                Image(systemName: "play.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .transition(.opacity)
            }
        }
    }
}

final class NotchLightsController {
    private var panels: [NSPanel] = []

    /// Reconstruye las luces para las pantallas actuales.
    func rebuild(notches: [ScreenNotch], store: SessionStore, onTap: @escaping () -> Void) {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        for entry in notches where entry.layout.hasNotch {
            let n = entry.layout.notchRect
            let h: CGFloat = 18
            let y = n.minY + (n.height - h) / 2
            let left = NSRect(x: n.minX - 200, y: y, width: 200, height: h)
            let right = NSRect(x: n.maxX, y: y, width: 200, height: h)
            fputs("NOTCH-LIGHTS notch=\(n) left=\(left) right=\(right) dots=\(store.sessions.filter { $0.status == .working || $0.status == .waiting }.map { $0.agent.rawValue }.joined(separator: ","))\n", stderr)
            panels.append(makePanel(frame: left, store: store, alignRight: true, onTap: onTap))
            panels.append(makePanel(frame: right, store: store, alignRight: false, onTap: onTap))
        }
        panels.forEach { $0.orderFrontRegardless() }
    }

    func hide() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
    }

    private func makePanel(frame: NSRect, store: SessionStore, alignRight: Bool, onTap: @escaping () -> Void) -> NSPanel {
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
        p.contentView = FirstMouseHostingView(rootView: NotchLightsView(store: store, alignRight: alignRight, onTap: onTap))
        return p
    }
}
#endif
