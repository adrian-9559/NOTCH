#if os(macOS)
import NotchCore
import SwiftUI

/// Vista raíz del notch. Datos desde SessionStore; acciones inyectadas
/// (Allow/Reply/Open las implementa ReplyService en su lote).
/// `extraTabs` permite añadir Shelf/Mini sin tocar este archivo.
/// Los ajustes (color, opacidad, orden/visibilidad de pestañas) viven en
/// NotchSettings y se aplican al instante: esta vista los observa.
struct NotchRootView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject private var settings = NotchSettings.shared
    /// Color de la canción que suena: ilumina el panel (lavado Lumio).
    @ObservedObject private var music = NotchContext.shared.music
    var extraTabs: [(title: String, view: AnyView)] = []
    /// Ancho del notch físico: dibuja la pestaña negra que lo continúa.
    /// nil = Mac sin notch (sin pestaña).
    var notchWidth: CGFloat? = nil
    var onAllow: (AgentSession) -> Void = { _ in }
    var onReply: (AgentSession, String) -> Void = { _, _ in }
    var onOpen: (AgentSession) -> Void = { _ in }
    /// Pestaña seleccionada por ID (sobrevive a reordenar/ocultar).
    @State private var selectedTitle = "shelf"
    /// Altura mostrada del área de contenido (se anima a mano: si se
    /// usara withAnimation, la ventana saltaría al final de golpe).
    @State private var shownHeight: CGFloat = 300
    /// Altura natural medida de la pestaña seleccionada (con tope).
    @State private var targetHeight: CGFloat = 300
    /// La primera medición se aplica sin animación (al arrancar).
    @State private var hasMeasured = false

    /// Contenido entre estos límites: nada queda cortado por abajo y lo
    /// sobrado (historial largo) sigue con scroll.
    private let minContentHeight: CGFloat = 84
    private let maxContentHeight: CGFloat = 360

    /// Pestañas visibles, en el orden configurado en Ajustes.
    private var visibleTabs: [(title: String, view: AnyView)] {
        let byTitle = Dictionary(
            uniqueKeysWithValues: extraTabs.map { ($0.title, $0.view) }
        )
        return settings.visibleOrder.compactMap { title in
            byTitle[title].map { (title: title, view: $0) }
        }
    }

    var body: some View {
        let tabs = visibleTabs
        VStack(spacing: 0) {
            if let nw = notchWidth {
                // Pestaña que continúa el notch físico: sin esquinas arriba
                // y solapada con el panel para que no haya costura.
                UnevenRoundedRectangle(
                    cornerRadii: .init(topLeading: 0, bottomLeading: 6, bottomTrailing: 6, topTrailing: 0),
                    style: .continuous
                )
                .fill(Color.black)
                .frame(width: min(nw, 200), height: 10)
                .padding(.bottom, -10)
            }
            VStack(spacing: 0) {
                if !store.waiting.isEmpty {
                    // Avisos con scroll: si hay muchos, todos se ven.
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(store.waiting, id: \.agent) { s in
                                WaitingCard(session: s, onAllow: onAllow, onReply: onReply, onOpen: onOpen)
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                    .padding(.top, 14)
                    .padding([.leading, .trailing], 14)
                }
                if !tabs.isEmpty {
                    // Como Lumio: fila de botones arriba, separador fino,
                    // contenido debajo.
                    let sel = tabs.firstIndex { $0.title == selectedTitle } ?? 0
                    VStack(alignment: .leading, spacing: 0) {
                        // Píldoras pequeñas arriba a la izquierda: el notch
                        // físico tapa el centro del panel, así que toda la
                        // fila (7 pestañas) cabe a su izquierda.
                        HStack(spacing: 3) {
                            ForEach(tabs.indices, id: \.self) { i in
                                let tabId = NotchTab(rawValue: tabs[i].title)
                                NavButton(
                                    title: tabId?.title ?? tabs[i].title,
                                    icon: tabId?.icon ?? "gearshape",
                                    selected: i == sel
                                ) {
                                    withAnimation(.snappy(duration: 0.22)) {
                                        selectedTitle = tabs[i].title
                                    }
                                }
                            }
                            Spacer(minLength: 0)
                            Text(store.active.isEmpty ? tr("nav.idle") : "\(store.active.count) \(tr("nav.active"))")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.white.opacity(0.8))
                            Button {
                                SettingsWindowController.shared.show()
                            } label: {
                                Image(systemName: "gearshape")
                                    .font(.system(size: 11, weight: .medium))
                                    .frame(width: 28, height: 19)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(Color.white.opacity(0.10))
                                    )
                                    .padding(4)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.white.opacity(0.72))
                            .help("Ajustes de NOTCH")
                        }
                        .padding(.top, 12)
                        .padding(.bottom, 9)
                        .padding(.horizontal, 12)

                        // Separador fino a todo el ancho, como Lumio.
                        Rectangle()
                            .fill(Color.white.opacity(0.16))
                            .frame(height: 1)

                        // Altura según el contenido de cada pestaña: lo
                        // que tiene poco (Música) encoge el panel y lo que
                        // se desborda (historial largo) sigue
                        // con scroll. La medición es natural (el ScrollView
                        // propone altura infinita al contenido), así que no
                        // hay bucle con la altura mostrada.
                        ScrollView {
                            tabs[sel].view
                                .id(selectedTitle)
                                .transition(.opacity.combined(with: .scale(scale: 0.985)))
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .background(
                                    GeometryReader { g in
                                        Color.clear.preference(
                                            key: ContentHeightKey.self,
                                            value: g.size.height
                                        )
                                    }
                                )
                        }
                        .frame(height: shownHeight)
                        .padding(.top, 12)
                        .padding(.bottom, 14)
                        .padding(.horizontal, 16)
                        .onPreferenceChange(ContentHeightKey.self) { h in
                            let clamped = min(max(h, minContentHeight), maxContentHeight)
                            guard abs(clamped - targetHeight) > 0.5 else { return }
                            targetHeight = clamped
                            if !hasMeasured {
                                hasMeasured = true
                                shownHeight = clamped // primer ajuste: sin animar
                            }
                        }
                        // Interpola shownHeight → targetHeight a 60 fps: la
                        // ventana sigue cada frame y el filo superior queda
                        // anclado bajo el notch (withAnimation haría saltar
                        // la ventana al valor final de golpe).
                        .task(id: targetHeight) {
                            let from = shownHeight
                            let to = targetHeight
                            guard abs(from - to) > 0.5 else { return }
                            let steps = 16
                            for i in 1...steps {
                                try? await Task.sleep(nanoseconds: 16_000_000)
                                guard !Task.isCancelled else { return }
                                let p = Double(i) / Double(steps)
                                let eased = 1 - (1 - p) * (1 - p) * (1 - p) // ease-out
                                shownHeight = from + (to - from) * CGFloat(eased)
                            }
                            shownHeight = to
                        }
                    }
                }
            }
            .frame(width: 680)
            .background(panelGlass)
        }
        // Como Lumio: vidrio oscuro siempre, de día y de noche.
        .environment(\.colorScheme, .dark)
    }

    /// Vidrio casi negro de Lumio con la opacidad elegida en Ajustes.
    /// Orgánico: luz superior suave (como el filo del notch) + filo fino.
    private var panelGlass: some View {
        let shape = UnevenRoundedRectangle(
            cornerRadii: .init(topLeading: 0, bottomLeading: 18, bottomTrailing: 18, topTrailing: 0),
            style: .continuous
        )
        return ZStack {
            shape.fill(.ultraThinMaterial)
            shape.fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.05),
                        Color.black.opacity(settings.panelOpacity),
                        Color.black.opacity(min(0.97, settings.panelOpacity + 0.06))
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            // Lavado con el color de la canción (como Lumio): el notch
            // se ilumina con la carátula mientras suena.
            if let tint = music.tint {
                shape.fill(
                    LinearGradient(
                        colors: [
                            tint.opacity(0.34),
                            tint.opacity(0.13),
                            tint.opacity(0.04)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .transition(.opacity)
            }
        }
        .overlay(shape.stroke(Color.white.opacity(0.09), lineWidth: 1))
        // Luz viva en el filo superior: toma el color de la canción si
        // hay, blanco cálido si no.
        .overlay(alignment: .top) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [(music.tint ?? .white).opacity(0.35), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(height: 1)
        }
        .animation(.easeInOut(duration: 1.1), value: music.tint)
        .shadow(radius: 24)
    }
}

private struct WaitingCard: View {
    var session: AgentSession
    var onAllow: (AgentSession) -> Void
    var onReply: (AgentSession, String) -> Void
    var onOpen: (AgentSession) -> Void
    @ObservedObject private var settings = NotchSettings.shared
    @State private var replyText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: session.agent.notchColorHex)).frame(width: 8, height: 8)
                Text("\(session.agent.displayName) \(tr("waiting.needs"))")
                    .font(.notchMono(12))
                    .foregroundStyle(.white)
                Spacer()
                Text(tr("waiting.tag"))
                    .font(.notchMono(10))
                    .foregroundStyle(settings.accent)
            }
            Text(session.detail ?? session.status.rawValue)
                .font(.notchMono(10))
                .foregroundStyle(Color.white.opacity(0.6))
                .lineLimit(2)
            HStack(spacing: 6) {
                Button(tr("waiting.allow")) { onAllow(session) }
                    .buttonStyle(.borderedProminent)
                    .tint(settings.accent)
                    .controlSize(.small)
                TextField(tr("waiting.replyPh"), text: $replyText, onCommit: {
                    onReply(session, replyText); replyText = ""
                })
                .textFieldStyle(.roundedBorder)
                .font(.notchMono(11))
                Button(tr("waiting.send")) { onReply(session, replyText); replyText = "" }
                    .controlSize(.small)
                    .disabled(replyText.isEmpty)
                Button(tr("waiting.open")) { onOpen(session) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(settings.accent.opacity(0.45), lineWidth: 1)
        )
        .onReceive(NotificationCenter.default.publisher(for: .notchPrefillReply)) { note in
            if let path = note.object as? String {
                replyText = path
            }
        }
    }
}

/// Botón de la navbar: píldora con degradado de acento al seleccionar,
/// borde sutil y brillo. Pequeño para caber a la izquierda del notch.
private struct NavButton: View {
    var title: String
    var icon: String
    var selected: Bool
    var action: () -> Void
    @ObservedObject private var settings = NotchSettings.shared

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 26, height: 20)
                .background(pillBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(selected ? 0.25 : 0.08), lineWidth: 1)
                )
                .shadow(
                    color: selected ? settings.accent.opacity(0.5) : .clear,
                    radius: 6, y: 2
                )
                .scaleEffect(selected ? 1.0 : 0.96)
                // Área de clic mayor que la píldora visual.
                .padding(2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.white : Color.white.opacity(0.72))
        .help(title)
        .controlSize(.mini)
        .animation(.snappy(duration: 0.22), value: selected)
    }

    @ViewBuilder
    private var pillBg: some View {
        if selected {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [settings.accent, settings.accent.opacity(0.75)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.09))
        }
    }
}

/// Altura natural del contenido de la pestaña seleccionada (la mide
/// GeometryReader dentro del ScrollView; reduce a la más alta si hay
/// dos vistas midiendo a la vez durante el crossfade).
private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Compatibilidad: ahora manda `NotchTab.icon` (IDs estables).
func iconName(for title: String) -> String {
    NotchTab(rawValue: title)?.icon ?? "gearshape"
}

extension Color {
    /// Magenta de Lumio (#A550A7); el valor por defecto de Ajustes.
    static let lumioMagenta = Color(hex: NotchSettings.defaultAccent)

    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt64(h, radix: 16) ?? 0
        self.init(
            .sRGB,
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255,
            opacity: 1
        )
    }
}
#endif
