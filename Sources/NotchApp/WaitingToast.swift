#if os(macOS)
import AppKit
import NotchCore
import SwiftUI

// MARK: - Aviso "te necesita" (pregunta de un agente).
//
// Como el aviso de agente pero CLICABLE: sale del notch con el color
// del agente y la pregunta; al tocarla abre el panel en la tarjeta de
// espera (Permitir / escribir / Abrir). Excluyente con los otros avisos.

/// Píldora de pregunta: como la de música, pero se puede pulsar.
struct WaitingToastView: View {
    @ObservedObject var state: WaitingToastState
    var onTap: () -> Void = {}

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                if state.visible {
                    Button(action: onTap) {
                        pill
                    }
                    .buttonStyle(.plain)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .animation(.snappy(duration: 0.35), value: state.visible)
    }

    private var pill: some View {
        // El negro puro (OpenCode) no se ve: círculo claro con ? oscuro.
        let dark = isDarkHex(state.colorHex)
        return HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(dark ? Color.white.opacity(0.9) : (state.colorHex.map { Color(hex: $0) } ?? Color.gray))
                    .frame(width: 30, height: 30)
                Image(systemName: "questionmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(dark ? Color.black : Color.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(state.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(state.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .lineLimit(2)
            }
            Spacer(minLength: 2)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.5))
        }
        .padding(.horizontal, 12)
        .frame(width: 340, height: 64)
        .background(toastGlass)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var toastGlass: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return ZStack {
            shape.fill(.ultraThinMaterial)
            shape.fill(Color.black.opacity(0.55))
            // Lavado con el color del agente que pregunta.
            if let hex = state.colorHex {
                shape.fill(
                    LinearGradient(
                        colors: [Color(hex: hex).opacity(0.32), Color(hex: hex).opacity(0.08)],
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
/// que un aviso nuevo reinicie el temporizador).
final class WaitingToastState: ObservableObject {
    @Published var visible = false
    @Published var title = ""
    @Published var subtitle = ""
    @Published var colorHex: String?
    private var hideWork: DispatchWorkItem?
    private var gen = 0

    /// Muestra el aviso (reinicia si ya había uno).
    func announce(title: String, subtitle: String, colorHex: String?) {
        gen += 1
        let g = gen
        hideWork?.cancel()
        self.title = title
        self.subtitle = subtitle
        self.colorHex = colorHex
        visible = true
        let secs = NotchSettings.shared.waitToastSeconds
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.gen == g else { return }
            withAnimation(.snappy(duration: 0.35)) { self.visible = false }
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + secs, execute: w)
    }

    func hideNow() {
        gen += 1
        hideWork?.cancel()
        visible = false
    }
}

/// Una ventana de aviso por pantalla con notch que SÍ acepta clics
/// (al revés que las otras dos): pulsar abre el panel para responder.
/// Misma posición y cola que el resto: sale de uno en uno.
final class WaitingToastController {
    let state = WaitingToastState()
    private var panels: [NSPanel] = []
    /// Para no pisar el panel principal cuando está abierto.
    var isPanelVisible: (() -> Bool)?
    /// Al pulsar la píldora: la quita y abre el panel (lo pone NotchUI).
    var onTap: (() -> Void)?
    /// La espera entra en la misma cola que canción y fin de agente.
    var isBlocked: (() -> Bool)?

    func rebuild(notches: [ScreenNotch]) {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        for entry in notches where entry.layout.hasNotch {
            let n = entry.layout.notchRect
            let w: CGFloat = 340, h: CGFloat = 64
            let frame = NSRect(x: n.midX - w / 2, y: n.minY - h - 10, width: w, height: h)
            fputs("NOTCH-WAITTOAST frame=\(frame)\n", stderr)
            panels.append(makePanel(frame: frame))
        }
        panels.forEach { $0.orderFrontRegardless() }
    }

    func show(session: AgentSession) {
        guard NotchSettings.shared.waitToastEnabled else { return }
        guard isPanelVisible?() != true else { return }
        var detail = (session.detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty { detail = tr("waiting.tag") }
        state.announce(
            title: tr("toast.needsYou", session.agent.displayName),
            subtitle: detail,
            colorHex: session.agent.notchColorHex
        )
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
        // Al revés que los otros avisos: acepta el clic para responder.
        p.ignoresMouseEvents = false
        p.contentView = FirstMouseHostingView(rootView: WaitingToastView(state: state) { [weak self] in
            self?.onTap?()
        })
        return p
    }
}
#endif
