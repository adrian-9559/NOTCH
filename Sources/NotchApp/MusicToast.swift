#if os(macOS)
import AppKit
import SwiftUI

extension Notification.Name {
    /// Nueva canción detectada (título/artista/fuente distintos).
    static let notchTrackChanged = Notification.Name("notchTrackChanged")
}

/// Aviso estilo Lumio: al cambiar la canción sale del notch una píldora
/// pequeña con la carátula, el título y el símbolo de reproducción.
/// Se oculta sola a los pocos segundos. Solo luz, sin clics.
/// Ecualizador vivo: cada barra oscila de forma continua con su propio
/// periodo y fase (ease-in-out + repeatForever), como una salida suave
/// de modal en vez de saltos discretos por timer.
struct ToastEQ: View {
    @State private var on = false
    private let maxH: [CGFloat] = [9, 15, 11, 16]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 3, height: on ? maxH[i] : 4)
                    .animation(
                        .easeInOut(duration: 0.55 + Double(i) * 0.16)
                            .delay(Double(i) * 0.09)
                            .repeatForever(autoreverses: true),
                        value: on
                    )
            }
        }
        .frame(height: 16, alignment: .bottom)
        .onAppear { on = true }
    }
}

struct MusicToastView: View {
    @ObservedObject var state: MusicToastState
    @ObservedObject private var music = NotchContext.shared.music

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                if state.visible, !music.title.isEmpty {
                    pill
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .animation(.snappy(duration: 0.35), value: state.visible)
    }

    private var pill: some View {
        HStack(spacing: 10) {
            // Carátula en pequeño (o nota si aún no llegó).
            Group {
                if let art = music.artwork {
                    Image(nsImage: art)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        LinearGradient(
                            colors: [(music.tint ?? .gray).opacity(0.7), Color.black.opacity(0.8)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                        Image(systemName: "music.note")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(music.title.uppercased())
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(music.artist.isEmpty ? music.source : music.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            // Símbolo de reproducción: ecualizador vivo si suena.
            if music.playing {
                ToastEQ()
            } else {
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .padding(.horizontal, 12)
        .frame(width: 340, height: 64)
        .background(toastGlass)
    }

    private var toastGlass: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return ZStack {
            shape.fill(.ultraThinMaterial)
            shape.fill(Color.black.opacity(0.55))
            // Lavado sutil con el color de la canción.
            if let tint = music.tint {
                shape.fill(
                    LinearGradient(
                        colors: [tint.opacity(0.3), tint.opacity(0.08)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            }
        }
        .overlay(shape.stroke(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(radius: 16)
    }
}

/// Estado del aviso: visible + ocultado automático (con generación para
/// que un cambio de canción reinicie el temporizador).
final class MusicToastState: ObservableObject {
    @Published var visible = false
    private var hideWork: DispatchWorkItem?
    private var gen = 0

    /// Muestra el aviso 4.5 s (reinicia si ya estaba).
    func announce() {
        gen += 1
        let g = gen
        hideWork?.cancel()
        visible = true
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.gen == g else { return }
            withAnimation(.snappy(duration: 0.35)) { self.visible = false }
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: w)
    }

    func hideNow() {
        gen += 1
        hideWork?.cancel()
        visible = false
    }
}

/// Una ventana de aviso por pantalla con notch, siempre click-through.
final class MusicToastController {
    let state = MusicToastState()
    private var panels: [NSPanel] = []
    /// Para no pisar el panel principal cuando está abierto.
    var isPanelVisible: (() -> Bool)?

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(trackChanged),
            name: .notchTrackChanged, object: nil
        )
    }

    func rebuild(notches: [ScreenNotch]) {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        for entry in notches where entry.layout.hasNotch {
            let n = entry.layout.notchRect
            let w: CGFloat = 340, h: CGFloat = 64
            let frame = NSRect(x: n.midX - w / 2, y: n.minY - h - 10, width: w, height: h)
            fputs("NOTCH-TOAST frame=\(frame)\n", stderr)
            panels.append(makePanel(frame: frame))
        }
        panels.forEach { $0.orderFrontRegardless() }
    }

    @objc private func trackChanged() {
        guard isPanelVisible?() != true else { return }
        state.announce()
    }

    func hide() { state.hideNow() }

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
        // Solo luz: nunca intercepta clics (ni siquiera visible).
        p.ignoresMouseEvents = true
        p.contentView = NSHostingView(rootView: MusicToastView(state: state))
        return p
    }
}
#endif
