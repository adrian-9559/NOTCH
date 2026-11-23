#if os(macOS)
import AppKit
import Combine
import NotchCore
import SwiftUI

/// Píldora negra centrada en el notch, como la de Lumio: carátula,
/// tiempo transcurrido y barra de progreso, con el borde iluminado con
/// el color de la canción. Sin música no hay nada (ni puntos).
/// Clic abre el panel. Se reconstruye al cambiar las pantallas.
struct NotchLightsView: View {
    @ObservedObject private var music = NotchContext.shared.music
    /// Para re-renderizar al cambiar Liquid Glass en Ajustes.
    @ObservedObject private var settings = NotchSettings.shared
    var onTap: () -> Void = {}

    /// Firma para animar la aparición y el progreso.
    private var musicSig: String { "\(music.title)|\(music.playing)|\(music.artwork != nil)|\(music.playerLive)" }

    private var fraction: Double {
        music.duration > 0 ? min(1, max(0, music.position / music.duration)) : 0
    }

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                // Carátula en el extremo izquierdo.
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
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                    }
                }
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                Spacer(minLength: 8)
                // Tiempo + progreso en el centro.
                VStack(alignment: .trailing, spacing: 3) {
                    Text(fmt(music.position))
                        .font(.notchMono(12))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.2)).frame(width: 70, height: 3)
                        Capsule()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: max(3, 70 * fraction), height: 3)
                    }
                    .animation(.linear(duration: 0.5), value: music.position)
                }
                Spacer(minLength: 8)
                // Símbolo de sonido en el extremo derecho.
                if music.playing {
                    SongEQ(
                        c1: music.tint ?? .white,
                        c2: music.tint2 ?? music.tint ?? .gray,
                        barWidth: 2.5,
                        maxHeight: 13
                    )
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 10)
            .frame(width: 300, height: 40)
            .background(pillGlass)
            .liquidGlass(settings.liquidGlass, radius: 16, topFlat: true)
            .opacity(music.playing ? 1 : 0.8)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .animation(.easeInOut(duration: 0.4), value: musicSig)
    }

    private var pillGlass: some View {
        // Arriba pegada al borde (como si saliera del notch), abajo redonda.
        let shape = UnevenRoundedRectangle(
            cornerRadii: .init(topLeading: 0, bottomLeading: 16, bottomTrailing: 16, topTrailing: 0),
            style: .continuous
        )
        let edge = music.tint ?? .white
        // Fondo completamente negro: el color solo vive en el aura y la
        // onda. Abajo, un filo sutil del color (arriba negro puro).
        let bottomFade = LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.45),
                .init(color: .black, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        return shape.fill(Color.black)
            .overlay(
                shape.stroke(edge.opacity(0.6), lineWidth: 1)
                    .mask(bottomFade)
            )
    }

    private func fmt(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

final class NotchLightsController {
    private var panels: [NSPanel] = []
    /// Tira de clima en el notch cerrado (cuando no hay píldora).
    private var weatherPanels: [NSPanel] = []
    private var cancellables = Set<AnyCancellable>()
    /// Último estado musical visto (para combinar con panel/toast).
    private var hasSong = false
    private var panelOpen = false
    private var toastShowing = false

    /// Reconstruye la píldora para las pantallas actuales. Solo se
    /// muestra con música (carátula disponible); sin música, nada.
    func rebuild(notches: [ScreenNotch], onTap: @escaping () -> Void) {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        weatherPanels.forEach { $0.orderOut(nil) }
        weatherPanels = []
        for entry in notches where entry.layout.hasNotch {
            let n = entry.layout.notchRect
            // Misma forma y sitio para píldora y tira (300×40 pegada
            // arriba). OJO: el corte físico del notch (x856–1064 aquí)
            // no tiene píxeles — por eso la temperatura va a la
            // DERECHA (fuera del recorte) y el centro queda libre.
            let w: CGFloat = 300, h: CGFloat = 40
            let frame = NSRect(x: n.midX - w / 2, y: n.maxY - h, width: w, height: h)
            weatherPanels.append(makeStripPanel(frame: frame))
            fputs("NOTCH-LIGHTS notch=\(n) pill=\(frame)\n", stderr)
            panels.append(makePanel(frame: frame, onTap: onTap))
        }
        cancellables.removeAll()
        // El parte puede llegar DESPUÉS (red): al entrar la temperatura,
        // reevaluar tira de clima vs píldora de música.
        WeatherStore.shared.$temp
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateVisibility() }
            .store(in: &cancellables)
        // Sin música no hay píldora: se ordena fuera.
        let m0 = NotchContext.shared.music
        m0.$title
            .combineLatest(m0.$artwork, m0.$playerLive, m0.$playing)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] title, art, live, playing in
                // Píldora SOLO con música sonando: en pausa o parada,
                // el notch lleva el clima (lo pidió el usuario).
                self?.hasSong = !title.isEmpty && art != nil && live && playing
                self?.updateVisibility()
            }
            .store(in: &cancellables)
        updateVisibility()
    }

    /// La píldora estorba con el panel abierto o con el aviso: fuera
    /// con fundido (nada de aparecer/desaparecer de golpe).
    func setPanelOpen(_ open: Bool) {
        panelOpen = open
        updateVisibility()
    }

    func setToastShowing(_ showing: Bool) {
        toastShowing = showing
        updateVisibility()
    }

    private func updateVisibility() {
        let pillOn = hasSong && !panelOpen && !toastShowing
        // Sin canción reproduciéndose: el notch lleva el clima
        // (icono a la izquierda, temperatura a la derecha).
        let stripOn = !pillOn && !panelOpen && !toastShowing
        // La tira primero y la píldora después: si se cruzan en un
        // fundido, la píldora queda encima.
        fade(weatherPanels, show: stripOn)
        fade(panels, show: pillOn)
    }

    private func fade(_ list: [NSPanel], show: Bool) {
        for p in list {
            if show {
                guard p.alphaValue < 0.99 else { continue }
                p.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.3
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
                    p.animator().alphaValue = 1
                }
            } else {
                guard p.alphaValue > 0.01 else {
                    p.orderOut(nil)
                    continue
                }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.2
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    p.animator().alphaValue = 0
                }, completionHandler: {
                    // Solo ordena fuera si sigue oculta (evita que un
                    // fundido de entrada reciente la apague otra vez).
                    if p.alphaValue < 0.01 { p.orderOut(nil) }
                })
            }
        }
    }

    func hide() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        weatherPanels.forEach { $0.orderOut(nil) }
        weatherPanels = []
    }

    /// Frames en pantalla de las píldoras visibles (vacío si oculta).
    /// Para que el hover las incluya: la píldora (300 px) es más ancha
    /// que el notch y los bordes quedarían fuera de la zona.
    var visiblePillFrames: [NSRect] {
        guard !panelOpen, !toastShowing else { return [] }
        // Con música, la píldora; sin ella, la tira ocupa el mismo
        // sitio: pasar el ratón por el clima también abre el panel.
        return (hasSong ? panels : weatherPanels).map { $0.frame }
    }

    private func makePanel(frame: NSRect, onTap: @escaping () -> Void) -> NSPanel {
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
        p.alphaValue = 0
        p.ignoresMouseEvents = false
        p.contentView = FirstMouseHostingView(rootView: NotchLightsView(onTap: onTap))
        return p
    }

    /// Ventana de clima: mismo rectángulo que el notch, solo lectura.
    private func makeStripPanel(frame: NSRect) -> NSPanel {
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
        p.alphaValue = 0
        // Solo lectura: no intercepta clics de la barra de menús.
        p.ignoresMouseEvents = true
        p.contentView = NSHostingView(rootView: NotchWeatherStripView())
        return p
    }
}

/// Clima en el notch cerrado: píldora compacta de40 pt como la de
/// siempre — el icono del parte a la izquierda y la temperatura a la
/// derecha, FUERA del corte físico del notch (x856–1064 no tiene
/// píxeles: el centro no sirve). Sin etiqueta de unidad: el número
/// ya sale en la unidad elegida en Ajustes. Sin datos: invisible.
struct NotchWeatherStripView: View {
    @ObservedObject private var w = WeatherStore.shared
    /// Para re-renderizar al cambiar ºC/ºF en Ajustes (fmtTemp lee
    /// NotchSettings.shared).
    @ObservedObject private var settings = NotchSettings.shared

    var body: some View {
        HStack(spacing: 8) {
            // Icono del parte en el hueco de la carátula (24×24).
            Group {
                if let c = w.code {
                    WeatherGlyph(code: c, size: 16)
                } else {
                    Image(systemName: "cloud")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.7))
                }
            }
            .frame(width: 24, height: 24)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            Spacer(minLength: 8)
            // Temperatura al extremo derecho: esa banda (x1064–1100)
            // queda fuera del recorte y se ve en la pantalla real.
            if let t = w.temp {
                Text(fmtTemp(t))
                    .font(.notchMono(13))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 300, height: 40)
        .background(stripGlass)
        .liquidGlass(NotchSettings.shared.liquidGlass, radius: 16, topFlat: true)
        // Sin datos aún: invisible (el fundido del panel ya lo oculta).
        .opacity(w.temp == nil ? 0 : 1)
        .animation(.easeInOut(duration: 0.35), value: w.temp == nil)
    }

    /// Mismo material que la píldora: negro puro, pegada arriba,
    /// abajo redonda, con un filo azul del color del parte.
    private var stripGlass: some View {
        let shape = UnevenRoundedRectangle(
            cornerRadii: .init(topLeading: 0, bottomLeading: 16, bottomTrailing: 16, topTrailing: 0),
            style: .continuous
        )
        let bottomFade = LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.45),
                .init(color: .black, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        return shape.fill(Color.black)
            .overlay(
                shape.stroke(Color(hex: "4C8FD8").opacity(0.6), lineWidth: 1)
                    .mask(bottomFade)
            )
    }
}
#endif
